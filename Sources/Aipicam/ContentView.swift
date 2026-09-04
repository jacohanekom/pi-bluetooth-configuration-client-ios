import SwiftUI

/// Adapted from pi-bluetooth-configuration-client-mac's ContentView.swift --
/// same screens and HTTPManager calls, with iOS-specific adjustments:
///   - A NavigationStack + toolbar button instead of a free-floating
///     "Disconnect" header (there's no titlebar to put it in on iOS).
///   - No fixed window frame (macOS-only concept; iOS fills the screen).
///   - Autocorrection/autocapitalization disabled on the address/SSID/
///     password/IP fields -- iOS's default text input behavior actively
///     fights typing any of those (auto-capitalizing the first letter,
///     offering spelling "corrections" for a Wi-Fi name), which macOS's
///     plain NSTextField never did in the first place.
struct ContentView: View {
    @EnvironmentObject var http: HTTPManager
    @State private var manualSSID: String = ""
    @State private var password: String = ""
    @State private var localIPField: String = ""
    @State private var rangeStartField: String = ""
    @State private var rangeEndField: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if !http.isConnected {
                    addressEntrySection
                } else if http.status.wifi.finished {
                    connectedDetailsSection
                } else {
                    wizardSection
                }

                if let info = http.lastInfo {
                    Text(info)
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
                if let error = http.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .toolbar {
                if http.isConnected {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Disconnect") { http.disconnect() }
                    }
                }
            }
        }
    }

    // MARK: - Address entry (replaces the old BLE device list)

    private var addressEntrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to a Pi").font(.headline)
            Text("Join the Pi's own WiFi network first (its name is its serial number) if it's showing one, then enter its address below. A fresh or unconfigured Pi uses \(HTTPManager.defaultAddress) by default.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("192.168.5.1:8080", text: $http.serverAddress)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button {
                http.connectToServer()
            } label: {
                if http.isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(http.isConnecting || http.serverAddress.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Setup finished: post-init details screen
    //
    // Shown once the wizard is done (http.status.wifi.finished): WiFi/network
    // stats, relay controls, and Victron solar/battery telemetry, each
    // behind its own DisclosureGroup rather than stacked flat -- there's
    // a lot of information across the three, so each collapses until
    // tapped open. Connectivity starts expanded since it's the one most
    // people check first (the "did WiFi actually come up" question);
    // Relays/Solar-Battery start collapsed.

    private var connectedDetailsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connected to \(http.serverAddress)")
                    .font(.headline)

                connectivityDisclosure
                relaysDisclosure
                solarBatteryDisclosure

                Button("Reset") {
                    http.resetNetwork()
                }
                .buttonStyle(.bordered)
            }
            // ScrollView proposes its own width to this VStack, but doesn't
            // clip content that ends up wider than that (e.g. a long relay
            // label at a larger accessibility text size) -- pin the width
            // explicitly so a trailing-aligned control like a Toggle's
            // switch can't render past the screen's visible edge.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Connectivity (WiFi + Local Network)

    @State private var connectivityExpanded = true

    private var connectivityDisclosure: some View {
        DisclosureGroup(isExpanded: $connectivityExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("WiFi") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Network", value: http.status.wifi.ssid)
                        LabeledContent("IP address", value: http.status.wifi.ip)
                    }
                    .padding(.top, 4)
                }

                GroupBox("Local Network") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Gateway IP", value: http.status.eth.ip)
                        LabeledContent("DHCP range", value: "\(rangeAddress(http.status.eth.rangeStart)) – \(rangeAddress(http.status.eth.rangeEnd))")
                        if http.status.leases.isEmpty {
                            Text("No devices connected")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(http.status.leases) { lease in
                                LabeledContent(lease.hostname.isEmpty ? lease.mac : lease.hostname, value: lease.ip)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 4)
        } label: {
            Text("Connectivity").font(.headline)
        }
    }

    // MARK: - Relays (pi-relay-control-alpine, via pi-bluetooth-configuration)

    @State private var relaysExpanded = false

    private var relaysDisclosure: some View {
        DisclosureGroup(isExpanded: $relaysExpanded) {
            Group {
                if http.status.relays.isEmpty {
                    Text("No relays configured")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(http.status.relays) { relay in
                            let isPending = http.pendingRelayPorts.contains(relay.port)
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { relay.isOn },
                                    set: { http.setRelay(port: relay.port, on: $0) }
                                )) {
                                    Text(relay.label)
                                }
                                .toggleStyle(.switch)
                                .disabled(relay.state == "unknown" || isPending)

                                // A relay command's outcome comes back
                                // directly in the POST /relay response, but
                                // the daemon retries against
                                // pi-relay-control-alpine for up to ~10s
                                // before giving up -- this spinner covers
                                // that wait.
                                if isPending {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    // DisclosureGroup indents its content from the leading
                    // edge but doesn't shrink the width it proposes to that
                    // content to compensate -- without this, a full-width
                    // control like a Toggle's switch (which hugs the
                    // trailing edge) renders partly past the screen's
                    // visible bounds and looks "cut off".
                    .padding(.trailing, 20)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Relays").font(.headline)
        }
    }

    // MARK: - Solar/Battery Information (victron-ve-direct-alpine, via pi-bluetooth-configuration)

    @State private var solarBatteryExpanded = false

    private var solarBatteryDisclosure: some View {
        DisclosureGroup(isExpanded: $solarBatteryExpanded) {
            Group {
                if !http.status.victron.connected {
                    Text("No Victron device connected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if let device = http.status.victron.device {
                            LabeledContent("Device", value: device.name)
                            LabeledContent("Serial", value: device.serial)
                        }
                        if let v = http.status.victron.V {
                            LabeledContent("Battery Voltage", value: String(format: "%.2f V", v))
                        }
                        if let i = http.status.victron.I {
                            LabeledContent("Battery Current", value: formattedBatteryCurrent(i))
                        }
                        if let vpv = http.status.victron.VPV {
                            LabeledContent("Solar Voltage", value: String(format: "%.2f V", vpv))
                        }
                        if let ppv = http.status.victron.PPV {
                            LabeledContent("Solar Input", value: String(format: "%.0f W", ppv))
                        }
                        if let csName = http.status.victron.CSName {
                            LabeledContent("Charge State", value: csName)
                        }
                        if let errName = http.status.victron.ERRName {
                            LabeledContent("Error", value: errName)
                        }
                        if let h20 = http.status.victron.H20 {
                            LabeledContent("Yield Today", value: String(format: "%.2f kWh", h20))
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Solar/Battery Information").font(.headline)
        }
    }

    // Note: no state-of-charge / time-to-go here -- those only exist on
    // battery monitors (BMV-series), not the MPPT solar chargers this
    // integration targets. Also no load output switch state -- not
    // every MPPT has one, and it's always "ON" on this integration's
    // hardware, so there's nothing informative to show. Neither field
    // is reported by victron_control.hpp on the daemon side.

    // Victron's "I" is signed: positive while the battery is charging,
    // negative while it's discharging (a load drawing current), zero
    // when idle. The raw sign alone isn't obvious at a glance, so this
    // spells out which one it means alongside the magnitude.
    private func formattedBatteryCurrent(_ amps: Double) -> String {
        let magnitude = String(format: "%.2f A", abs(amps))
        if amps > 0.01 { return "\(magnitude) (charging)" }
        if amps < -0.01 { return "\(magnitude) (discharging)" }
        return "\(magnitude) (idle)"
    }

    private func rangeAddress(_ lastOctet: Int) -> String {
        let ip = http.status.eth.ip
        guard let dot = ip.lastIndex(of: ".") else { return "\(lastOctet)" }
        return "\(ip[ip.startIndex..<dot]).\(lastOctet)"
    }

    // MARK: - Wizard (WiFi not yet configured, or configured but not finished)

    private var wizardSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connected to \(http.serverAddress)")
                .font(.headline)

            switch http.wizardStep {
            case .scanning:
                scanningStep
            case .pickNetwork:
                pickNetworkStep
            case .enterPassword(let ssid):
                enterPasswordStep(ssid: ssid)
            case .localNetworkConfig:
                localNetworkConfigStep
            }
        }
    }

    private var scanningStep: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning for networks…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var pickNetworkStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Choose a Network").font(.headline)
                Spacer()
                Button {
                    http.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan")
            }

            if http.status.scan.isEmpty {
                Text("No networks found.")
                    .foregroundStyle(.secondary)
            }

            List(http.status.scan) { result in
                Button {
                    password = ""
                    http.selectNetwork(ssid: result.ssid)
                } label: {
                    HStack {
                        Text(result.ssid)
                        Spacer()
                        Text(result.security).foregroundStyle(.secondary)
                        Text("\(result.rssi) dBm").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .frame(minHeight: 180)

            Button("Enter Network Manually") {
                manualSSID = ""
                password = ""
                http.selectNetwork(ssid: "")
            }
        }
    }

    private func enterPasswordStep(ssid: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    http.backToNetworkList()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
                Text(ssid.isEmpty ? "Enter Network" : ssid)
                    .font(.headline)
            }

            if ssid.isEmpty {
                TextField("SSID", text: $manualSSID)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            SecureField("Password (leave blank for an open network)", text: $password)
                .textFieldStyle(.roundedBorder)

            if http.status.wifi.state == "connecting" || http.status.wifi.state == "failed" {
                statusBadge
            }

            Button("Connect") {
                http.connectToNetwork(ssid: ssid.isEmpty ? manualSSID : ssid, password: password)
            }
            .disabled((ssid.isEmpty ? manualSSID : ssid).isEmpty || http.status.wifi.state == "connecting")
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Local network configuration (last wizard step, after WiFi joins)

    private var localNetworkConfigStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Network Configuration").font(.headline)
            Text("eth0 already has a working gateway IP and DHCP server. Adjust it here if you'd like, or just continue.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Text("IP address").frame(width: 90, alignment: .leading)
                TextField("192.168.4.1", text: $localIPField)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 160)
            }
            HStack {
                Text("DHCP range").frame(width: 90, alignment: .leading)
                TextField("2", text: $rangeStartField)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 50)
                Text("–")
                TextField("200", text: $rangeEndField)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 50)
            }

            Button("Finish") {
                let start = Int(rangeStartField) ?? http.status.eth.rangeStart
                let end = Int(rangeEndField) ?? http.status.eth.rangeEnd
                http.setLocalNetworkConfig(ip: localIPField, rangeStart: start, rangeEnd: end)
                http.finishSetup()
            }
            .disabled(!isValidIPv4(localIPField) || Int(rangeStartField) == nil || Int(rangeEndField) == nil)
            .buttonStyle(.borderedProminent)
        }
        .onAppear {
            if localIPField.isEmpty { localIPField = http.status.eth.ip }
            if rangeStartField.isEmpty { rangeStartField = String(http.status.eth.rangeStart) }
            if rangeEndField.isEmpty { rangeEndField = String(http.status.eth.rangeEnd) }
        }
    }

    // Mirrors the daemon's own is_valid_ipv4 (eth_control.hpp): 4
    // dot-separated all-digit octets, each 0-255. Just a client-side
    // sanity gate on the Finish button -- the daemon is the actual
    // validation boundary.
    private func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let value = Int(part) else { return false }
            return value >= 0 && value <= 255
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
            Spacer()
        }
        .font(.subheadline)
    }

    private var statusColor: Color {
        switch http.status.wifi.state {
        case "connecting": return .yellow
        case "failed":     return .red
        default:           return .gray
        }
    }

    private var statusText: String {
        switch http.status.wifi.state {
        case "connecting":
            return "Connecting to \(http.status.wifi.ssid)…"
        case "failed":
            return "Failed: \(http.status.wifi.error)"
        default:
            return ""
        }
    }
}
