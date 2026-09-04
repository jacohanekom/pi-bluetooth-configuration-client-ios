import Foundation

/// Field names and shapes match pi-bluetooth-configuration-alpine's HTTP
/// API exactly -- see that repo's README ("HTTP API") for the routes
/// these decode responses from.

struct WifiStatus: Decodable, Equatable {
    var state: String
    var ssid: String
    var ip: String
    var error: String
    // Whether the daemon's one-shot setup wizard has already completed --
    // a Pi that just joined WiFi but hasn't finished yet also reports
    // state == "connected", so this (not just state) is what decides
    // wizard vs. final details.
    var finished: Bool

    static let idle = WifiStatus(state: "idle", ssid: "", ip: "", error: "", finished: false)
}

struct WifiScanResult: Decodable, Equatable, Identifiable {
    var ssid: String
    var rssi: Int
    var security: String

    var id: String { ssid }
}

/// eth0's gateway config -- plain JSON on the wire now (unlike the old
/// BLE-era CSV format, which existed only because that daemon had no
/// JSON parser for the write side; the HTTP daemon parses JSON request
/// bodies anyway, so this uses the same shape both ways).
struct EthernetConfig: Codable, Equatable {
    var ip: String
    var rangeStart: Int
    var rangeEnd: Int

    static let unknown = EthernetConfig(ip: "", rangeStart: 2, rangeEnd: 200)
}

struct DhcpLease: Decodable, Equatable, Identifiable {
    var ip: String
    var mac: String
    var hostname: String

    var id: String { ip }
}

/// One relay pi-bluetooth-configuration forwards on/off/status to on
/// pi-relay-control-alpine's behalf -- see that repo's README, "Relay
/// control". `state` is "on", "off", or "unknown" (pi-relay-control-alpine
/// unreachable on that port).
struct RelayState: Decodable, Equatable, Identifiable {
    var port: Int
    var label: String
    var state: String

    var id: Int { port }
    var isOn: Bool { state == "on" }
}

/// Identifies the connected Victron device, if any -- pi-bluetooth-configuration's
/// README, "Victron solar/battery telemetry".
struct VictronDevice: Decodable, Equatable {
    var pid: String
    var name: String
    var serial: String
    var fw: String
}

/// Latest solar/battery reading pi-bluetooth-configuration forwards from
/// victron-ve-direct-alpine's status port -- see that repo's README,
/// "Victron solar/battery telemetry". Field names and units match
/// victron-ve-direct-alpine's own data_port JSON exactly.
///
/// Every field but `connected` is optional and decoded leniently
/// (auto-synthesized `Decodable` uses `decodeIfPresent` for Optional
/// properties): `connected: false` alone covers every failure case --
/// victron-ve-direct-alpine not installed, not reachable, or not yet
/// synced a frame -- so there's nothing else to decode in that case.
///
/// SOC/TTG (state of charge, time to go) exist on the wire for battery
/// monitors but are deliberately not modeled here -- this integration
/// targets MPPT solar chargers, which don't report them. LOAD (the
/// charger's load output switch state) is also deliberately not
/// modeled -- not every MPPT model has a load output terminal, and on
/// this integration's hardware it's always "ON", so there's nothing
/// informative to show.
struct VictronStatus: Decodable, Equatable {
    var connected: Bool
    var device: VictronDevice?
    var V: Double?
    var I: Double?
    var VPV: Double?
    var PPV: Double?
    var CS: Int?
    var CSName: String?
    var ERR: Int?
    var ERRName: String?
    var H20: Double?

    static let disconnected = VictronStatus(
        connected: false, device: nil, V: nil, I: nil, VPV: nil, PPV: nil, CS: nil, CSName: nil,
        ERR: nil, ERRName: nil, H20: nil
    )

    private enum CodingKeys: String, CodingKey {
        case connected, device, V, I, VPV, PPV, CS
        case CSName = "CS_name"
        case ERR
        case ERRName = "ERR_name"
        case H20
    }
}

/// The combined `GET /status` response -- see pi-bluetooth-configuration-alpine's
/// README, "HTTP API" / "Status JSON". Every field but `wifi` and
/// `apActive` is decoded leniently (defaulting to empty/disconnected)
/// so an older or minimally-configured daemon build still decodes
/// successfully instead of failing this whole poll over one missing
/// optional section.
struct StatusResponse: Decodable, Equatable {
    var wifi: WifiStatus
    var apActive: Bool
    var eth: EthernetConfig
    var leases: [DhcpLease]
    var relays: [RelayState]
    var victron: VictronStatus
    var scan: [WifiScanResult]

    static let empty = StatusResponse(
        wifi: .idle, apActive: false, eth: .unknown, leases: [], relays: [], victron: .disconnected, scan: []
    )

    init(wifi: WifiStatus, apActive: Bool, eth: EthernetConfig, leases: [DhcpLease], relays: [RelayState],
         victron: VictronStatus, scan: [WifiScanResult]) {
        self.wifi = wifi
        self.apActive = apActive
        self.eth = eth
        self.leases = leases
        self.relays = relays
        self.victron = victron
        self.scan = scan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wifi = try c.decode(WifiStatus.self, forKey: .wifi)
        apActive = try c.decodeIfPresent(Bool.self, forKey: .apActive) ?? false
        eth = try c.decodeIfPresent(EthernetConfig.self, forKey: .eth) ?? .unknown
        leases = try c.decodeIfPresent([DhcpLease].self, forKey: .leases) ?? []
        relays = try c.decodeIfPresent([RelayState].self, forKey: .relays) ?? []
        victron = try c.decodeIfPresent(VictronStatus.self, forKey: .victron) ?? .disconnected
        scan = try c.decodeIfPresent([WifiScanResult].self, forKey: .scan) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case wifi, apActive, eth, leases, relays, victron, scan
    }
}
