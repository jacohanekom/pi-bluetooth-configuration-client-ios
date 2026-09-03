import CoreBluetooth
import Foundation

/// Which step of the setup wizard is showing. Only relevant while
/// status.finished is false -- once it's true, ContentView shows the
/// final connected-details view instead, regardless of this value.
enum WizardStep: Equatable {
    case scanning
    case pickNetwork
    case enterPassword(ssid: String)
    // WiFi joined but the wizard hasn't been finished yet -- eth0's
    // gateway IP/DHCP range can still be customized here before
    // finishSetup() sends "finish" and the Pi reboots.
    case localNetworkConfig
}

/// Central-role BLE client for aipicam's WiFi-provisioning GATT service.
///
/// Identical to pi-bluetooth-configuration-client-mac's copy of this file
/// -- CoreBluetooth's central-role API (CBCentralManager/CBPeripheral) is
/// the same on iOS and macOS, so none of this needed platform-specific
/// changes to port.
///
/// No pairing/bonding: the peripheral's characteristics are plain
/// read/write, not encrypted, so connecting is all that's needed -- see
/// pi-bluetooth-configuration-alpine's README ("Security model") for why
/// pairing was deliberately removed and what that trades away (WiFi
/// credentials cross BLE in the clear).
///
/// This is a one-shot provisioning flow, not a managed session: the Pi
/// reboots a few seconds after "finish" or after "reset" (see that
/// repo's README, "One-shot provisioning and reboot behavior"), so this
/// client doesn't try to keep managing anything once either happens --
/// it just shows the result and treats the BLE disconnect that follows
/// as expected, not an error.
@MainActor
final class BLEManager: NSObject, ObservableObject {
    struct DiscoveredDevice: Identifiable {
        let id: UUID
        let name: String
        let rssi: Int
        let peripheral: CBPeripheral
    }

    static let maxReconnectAttempts = 3
    static let reconnectDelay: TimeInterval = 1

    @Published private(set) var isBluetoothReady = false
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false
    @Published private(set) var connectedName: String?
    @Published private(set) var status: WifiStatus = .idle
    @Published private(set) var scanResults: [WifiScanResult] = []
    @Published private(set) var wizardStep: WizardStep = .scanning
    @Published private(set) var ethernetConfig: EthernetConfig = .unknown
    @Published private(set) var dhcpLeases: [DhcpLease] = []
    @Published private(set) var relays: [RelayState] = []
    /// Ports with a write in flight -- pi-bluetooth-configuration only
    /// re-polls and republishes relay state on its own 5s cadence (see the
    /// daemon's README, "Relay control"), so without this the switch would
    /// sit unconfirmed (or visibly bounce back and forth) for up to that
    /// long after a tap. The UI shows a spinner in place of the switch
    /// while a port is pending.
    @Published private(set) var pendingRelayPorts: Set<Int> = []
    @Published private(set) var victronStatus: VictronStatus = .disconnected
    @Published var lastError: String?
    @Published var lastInfo: String?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]

    // What each pending relay port was actually asked to become --
    // compared against every relays notification so a retry can tell
    // "this confirms my request" from "some unrelated/stale update
    // arrived", the same way pi-bluetooth-configuration's own do_relay
    // retries until pi-relay-control-alpine confirms with OK rather than
    // accepting the first attempt regardless of outcome. Needed because a
    // write can silently never reach the daemon at all (a BLE hiccup, a
    // mid-command disconnect) -- with nothing watching for that, the
    // switch would just sit pending forever with no way to notice.
    private var pendingRelayDesired: [Int: Bool] = [:]
    private var relayRetryWorkItems: [Int: DispatchWorkItem] = [:]
    private static let relayRetryInterval: TimeInterval = 1.5
    private static let relayMaxAttempts = 5

    private var userInitiatedDisconnect = false
    // Set once we know the daemon is about to reboot (a successful
    // "finish", or a reset we just sent) -- the BLE disconnect that
    // follows is expected, not a failure to retry against.
    private var expectRebootDisconnect = false
    private var reconnectAttempts = 0
    // Kicks off exactly one automatic scan per connection, the moment we
    // learn the Pi isn't already configured -- avoids re-scanning every
    // time a Status notification happens to repeat the same "not
    // connected yet" state.
    private var hasAutoScanned = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        discoveredDevices.removeAll()
        central.scanForPeripherals(withServices: [GATT.serviceUUID],
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(to device: DiscoveredDevice) {
        stopScan()
        lastError = nil
        lastInfo = nil
        isConnecting = true
        userInitiatedDisconnect = false
        expectRebootDisconnect = false
        reconnectAttempts = 0
        hasAutoScanned = false
        wizardStep = .scanning
        peripheral = device.peripheral
        peripheral?.delegate = self
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        userInitiatedDisconnect = true
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        resetConnectionState()
    }

    /// Rescans -- used both for the automatic first scan and a manual
    /// "Rescan" action from the network-picker step.
    func rescan() {
        lastError = nil
        wizardStep = .scanning
        write("scan", to: GATT.commandUUID)
    }

    /// User tapped a network in the picker (or chose to enter one
    /// manually, with an empty ssid) -- advance to the password step.
    func selectNetwork(ssid: String) {
        lastError = nil
        wizardStep = .enterPassword(ssid: ssid)
    }

    func backToNetworkList() {
        lastError = nil
        wizardStep = .pickNetwork
    }

    func connectToNetwork(ssid: String, password: String) {
        write(ssid, to: GATT.ssidUUID)
        write(password, to: GATT.passwordUUID)
        write("connect", to: GATT.commandUUID)
    }

    // Labeled "Reset" in the UI; the wire command is still "forget" --
    // that's the daemon's protocol (see pi-bluetooth-configuration-alpine's
    // README), this is just how the app presents it.
    func resetNetwork() {
        expectRebootDisconnect = true
        lastInfo = "Resetting -- the Pi will reboot shortly."
        write("forget", to: GATT.commandUUID)
    }

    /// Local network (Ethernet gateway) configuration -- only takes
    /// effect on the daemon while the wizard hasn't been finished yet.
    /// Doesn't reboot the Pi by itself (Ethernet doesn't share the
    /// antenna with Bluetooth), so this doesn't touch
    /// expectRebootDisconnect.
    func setLocalNetworkConfig(ip: String, rangeStart: Int, rangeEnd: Int) {
        write(EthernetConfig(ip: ip, rangeStart: rangeStart, rangeEnd: rangeEnd).wireValue, to: GATT.ethernetIPUUID)
        write("set_ethernet", to: GATT.commandUUID)
    }

    /// Toggles a relay pi-bluetooth-configuration forwards to
    /// pi-relay-control-alpine on the Pi's behalf -- see that repo's
    /// README, "Relay control". Unlike the wizard commands, this isn't
    /// gated by wizard step or `finished`; it's available any time a
    /// relay shows up in `relays` at all.
    func setRelay(port: Int, on: Bool) {
        if let idx = relays.firstIndex(where: { $0.port == port }) {
            relays[idx].state = on ? "on" : "off"
        }
        pendingRelayPorts.insert(port)
        pendingRelayDesired[port] = on
        relayRetryWorkItems.removeValue(forKey: port)?.cancel() // superseded by this new request
        sendRelayCommand(port: port, on: on, attempt: 1)
    }

    /// Sends one relay write, then schedules a follow-up after
    /// relayRetryInterval that either retries or gives up, depending on
    /// whether a relays notification has confirmed it by then -- see
    /// pendingRelayDesired's comment for why "confirmed" means "matches
    /// what was actually requested", not just "any update arrived".
    private func sendRelayCommand(port: Int, on: Bool, attempt: Int) {
        write("relay \(port) \(on ? "on" : "off")", to: GATT.commandUUID)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.relayRetryWorkItems.removeValue(forKey: port)
            // Either a relays notification already confirmed this port
            // (clearing pendingRelayDesired[port]) or a newer setRelay
            // call superseded this one with a different target value --
            // either way, this stale retry has nothing left to do.
            guard self.pendingRelayDesired[port] == on else { return }

            guard self.isConnected, attempt < Self.relayMaxAttempts else {
                self.pendingRelayPorts.remove(port)
                self.pendingRelayDesired.removeValue(forKey: port)
                self.lastError = self.isConnected
                    ? "Relay command wasn't confirmed after \(Self.relayMaxAttempts) attempts -- check the Pi's connection to pi-relay-control-alpine."
                    : "Lost connection before the relay command was confirmed."
                // A fresh read reflects reality instead of this attempt's
                // optimistic guess, which never got confirmed either way.
                if let characteristic = self.characteristics[GATT.relaysUUID] {
                    self.peripheral?.readValue(for: characteristic)
                }
                return
            }
            self.sendRelayCommand(port: port, on: on, attempt: attempt + 1)
        }
        relayRetryWorkItems[port] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.relayRetryInterval, execute: workItem)
    }

    /// Concludes the setup wizard -- the daemon creates its marker file
    /// and reboots a few seconds later. Only meaningful once WiFi is
    /// actually connected; the UI only offers this button at that point.
    func finishSetup() {
        expectRebootDisconnect = true
        lastInfo = "Finishing setup -- the Pi will reboot shortly."
        write("finish", to: GATT.commandUUID)
    }

    private func write(_ string: String, to uuid: CBUUID) {
        guard let peripheral, let characteristic = characteristics[uuid] else {
            lastError = "Not connected"
            return
        }
        peripheral.writeValue(Data(string.utf8), for: characteristic, type: .withResponse)
    }

    private func resetConnectionState() {
        isConnected = false
        isConnecting = false
        connectedName = nil
        characteristics.removeAll()
        status = .idle
        scanResults = []
        wizardStep = .scanning
        ethernetConfig = .unknown
        dhcpLeases = []
        relays = []
        pendingRelayPorts.removeAll()
        pendingRelayDesired.removeAll()
        relayRetryWorkItems.values.forEach { $0.cancel() }
        relayRetryWorkItems.removeAll()
        victronStatus = .disconnected
    }
}

extension BLEManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isBluetoothReady = (central.state == .poweredOn)
        if central.state == .poweredOn {
            startScan()
        } else {
            discoveredDevices.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unknown device"
        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral)
        if let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[idx] = device
        } else {
            discoveredDevices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectAttempts = 0
        isConnecting = false
        isConnected = true
        connectedName = peripheral.name
        peripheral.discoverServices([GATT.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnecting = false
        lastError = error?.localizedDescription ?? "Failed to connect"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if userInitiatedDisconnect {
            userInitiatedDisconnect = false
            if let error { lastError = error.localizedDescription }
            resetConnectionState()
            return
        }

        if expectRebootDisconnect {
            expectRebootDisconnect = false
            lastInfo = "The Pi is rebooting to apply the change. Reconnect once it's back up."
            resetConnectionState()
            return
        }

        // Unexpected disconnect (e.g. the BCM43438's Hardware Failure
        // instability, or a transient RF issue) -- retry a few times
        // before treating it as an actual failure.
        if reconnectAttempts < Self.maxReconnectAttempts {
            reconnectAttempts += 1
            isConnecting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectDelay) { [weak self] in
                guard let self else { return }
                self.central.connect(peripheral, options: nil)
            }
            return
        }

        lastError = error?.localizedDescription ?? "Disconnected unexpectedly and could not reconnect"
        resetConnectionState()
    }
}

extension BLEManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == GATT.serviceUUID }) else {
            lastError = "aipicam WiFi-configuration service not found"
            return
        }
        peripheral.discoverCharacteristics(GATT.allCharacteristicUUIDs, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
            if characteristic.uuid == GATT.statusUUID
                || characteristic.uuid == GATT.scanResultsUUID
                || characteristic.uuid == GATT.ethernetIPUUID
                || characteristic.uuid == GATT.leasesUUID
                || characteristic.uuid == GATT.relaysUUID
                || characteristic.uuid == GATT.victronUUID {
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case GATT.statusUUID:
            do {
                let decoded = try JSONDecoder().decode(WifiStatus.self, from: data)
                status = decoded
                if decoded.finished {
                    // Already fully provisioned -- nothing wizard-related
                    // to do, ContentView shows the final details screen.
                } else if decoded.state == "connected" {
                    // WiFi just joined but "finish" hasn't been sent yet --
                    // move to the local network configuration step.
                    wizardStep = .localNetworkConfig
                } else if !hasAutoScanned {
                    hasAutoScanned = true
                    rescan()
                }
            } catch {
                // A silent failure here would otherwise leave the wizard
                // stuck (e.g. on the scanning spinner forever, since the
                // first automatic scan is triggered from this decode).
                lastError = "Couldn't read status from the Pi -- is its daemon up to date? (\(error.localizedDescription))"
            }
        case GATT.scanResultsUUID:
            if let decoded = try? JSONDecoder().decode([WifiScanResult].self, from: data) {
                scanResults = decoded.sorted { $0.rssi > $1.rssi }
                if wizardStep == .scanning {
                    wizardStep = .pickNetwork
                }
            } else {
                lastError = "Couldn't read scan results from the Pi -- is its daemon up to date?"
            }
        case GATT.ethernetIPUUID:
            if let value = String(data: data, encoding: .utf8), let decoded = EthernetConfig(wireValue: value) {
                ethernetConfig = decoded
            }
        case GATT.leasesUUID:
            if let decoded = try? JSONDecoder().decode([DhcpLease].self, from: data) {
                dhcpLeases = decoded
            }
        case GATT.relaysUUID:
            if let decoded = try? JSONDecoder().decode([RelayState].self, from: data) {
                relays = decoded
                // Only clear/stop retrying ports whose confirmed state
                // actually matches what was requested -- an update that
                // doesn't (e.g. it reflects a still-in-progress retry, or
                // arrived just before this attempt's write took effect)
                // leaves the retry loop running instead of declaring
                // victory on an update that isn't really the answer.
                for relay in decoded where pendingRelayDesired[relay.port] == relay.isOn {
                    pendingRelayPorts.remove(relay.port)
                    pendingRelayDesired.removeValue(forKey: relay.port)
                    relayRetryWorkItems.removeValue(forKey: relay.port)?.cancel()
                }
            }
        case GATT.victronUUID:
            if let decoded = try? JSONDecoder().decode(VictronStatus.self, from: data) {
                victronStatus = decoded
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastError = error.localizedDescription
        }
    }
}
