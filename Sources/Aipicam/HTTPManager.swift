import Foundation

/// Which step of the setup wizard is showing. Only relevant while
/// status.wifi.finished is false -- once it's true, ContentView shows the
/// final connected-details view instead, regardless of this value.
enum WizardStep: Equatable {
    case scanning
    case pickNetwork
    case enterPassword(ssid: String)
    // WiFi joined but the wizard hasn't been finished yet -- eth0's
    // gateway IP/DHCP range can still be customized here before
    // finishSetup() sends "finish" and the Pi reboots. Only reachable
    // when the fallback AP was NOT involved in getting here -- see
    // connectToNetwork's own comment.
    case localNetworkConfig
}

/// HTTP client for pi-bluetooth-configuration-alpine's JSON API -- see
/// that repo's README ("HTTP API") for the routes this calls and the
/// combined GET /status shape this polls.
///
/// Identical to pi-bluetooth-configuration-client-mac's copy of this file
/// -- plain URLSession, nothing platform-specific.
///
/// Unlike the BLE-era design this replaces, there's no server push: this
/// polls GET /status on a fixed interval instead of subscribing to
/// notifications. There's also no device discovery (no BLE scan, no
/// mDNS/Bonjour on the daemon side yet) -- the user reaches the Pi by
/// address, either the well-known fallback-AP default (prefilled) or the
/// Pi's real address once it's joined a network, same as any other
/// device with a local web UI.
///
/// This is a one-shot provisioning flow, not a managed session: the Pi
/// reboots a few seconds after "finish" or "forget" (see that repo's
/// README, "One-shot provisioning and reboot behavior"), and a
/// successful "connect" started from the fallback AP reboots immediately
/// too -- in every one of those cases this client's own connection to
/// the Pi is expected to drop, not a failure to retry against. Because
/// the radio can't run AP and station mode at once, a connect that
/// started from the fallback AP also means the *address* that was
/// working stops being valid at all (the AP disappears) -- there is no
/// way for this client to discover the Pi's new address automatically,
/// so it surfaces that plainly and sends the user back to address entry
/// instead of pretending to recover.
@MainActor
final class HTTPManager: ObservableObject {
    // Matches pi-bluetooth-configuration-alpine's own config.ini defaults
    // ([ap] ip = 192.168.5.1, [http] port = 8080) -- the address a fresh
    // or unconfigured Pi's fallback AP is reachable at out of the box.
    static let defaultAddress = "192.168.5.1:8080"

    private static let addressDefaultsKey = "pi-bluetooth-configuration.serverAddress"
    private static let pollInterval: TimeInterval = 3
    private static let requestTimeout: TimeInterval = 5
    // How many consecutive failed polls before giving up on the current
    // connection -- comfortably more than one transient hiccup (a single
    // slow relay/Victron query on the daemon's side, a momentary WiFi
    // blip), short enough not to leave the user staring at a frozen
    // screen for long after a real disconnect.
    private static let failureThreshold = 3
    private static let relayMaxAttempts = 3
    private static let relayRetryInterval: TimeInterval = 1.5

    @Published var serverAddress: String
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false
    @Published private(set) var status: StatusResponse = .empty
    @Published private(set) var wizardStep: WizardStep = .scanning
    // Ports with a POST /relay in flight -- unlike the old BLE-era retry
    // loop (which had to guess whether a write ever reached the daemon at
    // all), an HTTP response is a definitive answer, so this is purely
    // cosmetic: a spinner in place of the switch for however long the
    // daemon's own retry-until-confirmed logic against
    // pi-relay-control-alpine takes (up to ~10s -- see that daemon's
    // do_relay).
    @Published private(set) var pendingRelayPorts: Set<Int> = []
    @Published var lastError: String?
    @Published var lastInfo: String?

    private let session: URLSession
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var hasAutoScanned = false

    // Set right before an action that's expected to disconnect this
    // client from the Pi (connect/forget/finish) -- lets the polling
    // failure handler show an informational message explaining *why*
    // instead of a bare "lost connection" error. addressAfterDisconnect,
    // when set alongside it, prefills the address field with where the
    // Pi should be reachable next (the fallback-AP default, for forget or
    // a connect that started from AP mode) rather than leaving the
    // now-invalid old address sitting there.
    private var expectDisconnect = false
    private var expectDisconnectMessage = ""
    private var addressAfterDisconnect: String?

    init() {
        serverAddress = UserDefaults.standard.string(forKey: Self.addressDefaultsKey) ?? Self.defaultAddress
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    private func baseURL() -> URL? {
        let trimmed = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        return URL(string: withScheme)
    }

    // MARK: - Connection lifecycle

    func connectToServer() {
        guard let base = baseURL() else {
            lastError = "Enter the Pi's address first."
            return
        }
        lastError = nil
        lastInfo = nil
        isConnecting = true
        hasAutoScanned = false
        consecutiveFailures = 0
        expectDisconnect = false
        wizardStep = .scanning

        Task {
            do {
                let decoded = try await self.fetchStatus(base: base)
                self.isConnecting = false
                self.isConnected = true
                UserDefaults.standard.set(self.serverAddress, forKey: Self.addressDefaultsKey)
                self.applyStatus(decoded)
                self.startPolling()
            } catch {
                self.isConnecting = false
                self.lastError = "Couldn't reach \(base.host ?? self.serverAddress) -- check that you're on the Pi's WiFi network (or the same local network) and that the address is correct."
            }
        }
    }

    func disconnect() {
        stopPolling()
        resetConnectionState()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.pollOnce()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        guard let base = baseURL() else { return }
        do {
            let decoded = try await fetchStatus(base: base)
            consecutiveFailures = 0
            applyStatus(decoded)
        } catch {
            consecutiveFailures += 1
            guard consecutiveFailures >= Self.failureThreshold else { return }
            stopPolling()
            if expectDisconnect {
                lastInfo = expectDisconnectMessage
            } else {
                lastError = "Lost connection to the Pi."
            }
            if let addressAfterDisconnect {
                serverAddress = addressAfterDisconnect
            }
            resetConnectionState()
        }
    }

    private func fetchStatus(base: URL) async throws -> StatusResponse {
        let (data, response) = try await session.data(from: base.appendingPathComponent("status"))
        try Self.checkOK(response)
        return try JSONDecoder().decode(StatusResponse.self, from: data)
    }

    private func applyStatus(_ decoded: StatusResponse) {
        status = decoded
        if decoded.wifi.finished {
            // Already fully provisioned -- nothing wizard-related to do,
            // ContentView shows the final details screen.
        } else if decoded.wifi.state == "connected" {
            // WiFi just joined but setup hasn't been finished yet -- only
            // reachable when this didn't start from the fallback AP (see
            // connectToNetwork) -- move to the local network configuration step.
            wizardStep = .localNetworkConfig
        } else if !hasAutoScanned && wizardStep == .scanning {
            hasAutoScanned = true
            rescan()
        }
    }

    private func resetConnectionState() {
        isConnected = false
        isConnecting = false
        status = .empty
        wizardStep = .scanning
        pendingRelayPorts.removeAll()
        hasAutoScanned = false
        consecutiveFailures = 0
        expectDisconnect = false
        addressAfterDisconnect = nil
    }

    // MARK: - Wizard actions

    /// Rescans -- used both for the automatic first scan and a manual
    /// "Rescan" action from the network-picker step.
    func rescan() {
        lastError = nil
        wizardStep = .scanning
        Task { await self.post(path: "scan") }
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

    /// Submits WiFi credentials. Behavior on the daemon side genuinely
    /// differs depending on whether the fallback AP is currently active
    /// (see pi-bluetooth-configuration-alpine's README, "One-shot
    /// provisioning and reboot behavior") -- this radio can't run AP and
    /// station mode at once, so if the AP is active, submitting real
    /// credentials tears it down as part of joining, which severs this
    /// client's own connection (reached via that same AP) partway
    /// through. There's no way to discover the Pi's new address
    /// automatically from here, so this warns plainly and, once the
    /// connection actually drops, sends the user back to address entry.
    func connectToNetwork(ssid: String, password: String) {
        lastError = nil
        let startedFromAP = status.apActive
        expectDisconnect = true
        if startedFromAP {
            expectDisconnectMessage = "Attempting to join \"\(ssid)\" -- the Pi's setup network will disappear shortly as part of that. Reconnect your phone to your regular WiFi, then reopen this app once the Pi has had a chance to come up on \"\(ssid)\" and enter its new address."
            addressAfterDisconnect = nil // no way to know the new address in advance
        } else {
            expectDisconnectMessage = "Attempting to join \"\(ssid)\". If your phone loses its connection to the Pi, reconnect to the same network as the Pi and re-enter its address to continue."
            addressAfterDisconnect = nil
        }
        Task { await self.post(path: "connect", body: ["ssid": ssid, "password": password]) }
    }

    // Labeled "Reset" in the UI; the wire route is still "/forget" --
    // that's the daemon's protocol (see pi-bluetooth-configuration-alpine's
    // README), this is just how the app presents it.
    func resetNetwork() {
        expectDisconnect = true
        expectDisconnectMessage = "Resetting -- the Pi will reboot and start its setup network again. Rejoin it, then re-enter its address (\(Self.defaultAddress) unless you customized it)."
        addressAfterDisconnect = Self.defaultAddress
        Task { await self.post(path: "forget") }
    }

    /// Local network (Ethernet gateway) configuration -- only takes
    /// effect on the daemon while the wizard hasn't been finished yet.
    /// Doesn't reboot the Pi by itself, so this doesn't touch
    /// expectDisconnect.
    func setLocalNetworkConfig(ip: String, rangeStart: Int, rangeEnd: Int) {
        Task {
            await self.post(path: "ethernet", body: ["ip": ip, "rangeStart": rangeStart, "rangeEnd": rangeEnd])
        }
    }

    /// Concludes the setup wizard -- the daemon creates its marker file
    /// and reboots a few seconds later. Only meaningful once WiFi is
    /// actually connected; the UI only offers this button at that point.
    /// This path is only reachable when the fallback AP was never
    /// involved (see connectToNetwork), so the address itself doesn't
    /// change here -- polling just needs to ride out the reboot gap.
    func finishSetup() {
        expectDisconnect = true
        expectDisconnectMessage = "Finishing setup -- the Pi will reboot shortly."
        addressAfterDisconnect = nil // same address is expected to come back
        Task { await self.post(path: "finish") }
    }

    /// Toggles a relay pi-bluetooth-configuration forwards to
    /// pi-relay-control-alpine on the Pi's behalf -- see that repo's
    /// README, "Relay control". Unlike the wizard actions above, this
    /// isn't gated by wizard step or `finished`; it's available any time
    /// a relay shows up in `relays` at all.
    func setRelay(port: Int, on: Bool) {
        if let idx = status.relays.firstIndex(where: { $0.port == port }) {
            status.relays[idx].state = on ? "on" : "off"
        }
        pendingRelayPorts.insert(port)
        Task { await self.sendRelayCommand(port: port, on: on, attempt: 1) }
    }

    private struct RelayResponse: Decodable {
        var ok: Bool
        var relays: [RelayState]
    }

    private func sendRelayCommand(port: Int, on: Bool, attempt: Int) async {
        guard let base = baseURL() else {
            pendingRelayPorts.remove(port)
            lastError = "Not connected"
            return
        }
        do {
            var request = URLRequest(url: base.appendingPathComponent("relay"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["port": port, "state": on ? "on" : "off"])
            let (data, response) = try await session.data(for: request)
            try Self.checkOK(response)
            let decoded = try JSONDecoder().decode(RelayResponse.self, from: data)
            status.relays = decoded.relays
            pendingRelayPorts.remove(port)
            if !decoded.ok {
                lastError = "Relay command wasn't confirmed -- check the Pi's connection to pi-relay-control-alpine."
            }
        } catch {
            guard attempt < Self.relayMaxAttempts else {
                pendingRelayPorts.remove(port)
                lastError = "Couldn't reach the Pi to change the relay -- check your connection and try again."
                // A fresh read reflects reality instead of this attempt's
                // optimistic guess, which never got confirmed either way.
                if let base = baseURL() {
                    if let decoded = try? await fetchStatus(base: base) {
                        applyStatus(decoded)
                    }
                }
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.relayRetryInterval * 1_000_000_000))
            await sendRelayCommand(port: port, on: on, attempt: attempt + 1)
        }
    }

    // MARK: - Plain fire-and-forget POSTs

    private struct OkResponse: Decodable { var ok: Bool }

    private func post(path: String, body: [String: Any]? = nil) async {
        guard let base = baseURL() else {
            lastError = "Not connected"
            return
        }
        do {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await session.data(for: request)
            try Self.checkOK(response)
            if let decoded = try? JSONDecoder().decode(OkResponse.self, from: data), !decoded.ok {
                lastError = "The Pi rejected that request."
                expectDisconnect = false
            }
        } catch {
            expectDisconnect = false
            lastError = "Couldn't reach the Pi -- check your connection and try again."
        }
    }

    private static func checkOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
