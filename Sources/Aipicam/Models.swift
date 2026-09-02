import CoreBluetooth
import Foundation

/// UUIDs and layout match pi-bluetooth-configuration-alpine's GATT service
/// exactly -- see that repo's README for the protocol these characteristics
/// implement. Identical to pi-bluetooth-configuration-client-mac's copy of
/// this file -- CoreBluetooth's central-role API is the same on iOS and
/// macOS, so this whole file ports over unchanged.
enum GATT {
    static let serviceUUID     = CBUUID(string: "7b1e0000-6a45-4d1f-9b0a-3c2f8e4d5a10")
    static let ssidUUID        = CBUUID(string: "7b1e0001-6a45-4d1f-9b0a-3c2f8e4d5a10")
    static let passwordUUID    = CBUUID(string: "7b1e0002-6a45-4d1f-9b0a-3c2f8e4d5a10")
    static let commandUUID     = CBUUID(string: "7b1e0003-6a45-4d1f-9b0a-3c2f8e4d5a10")
    static let statusUUID      = CBUUID(string: "7b1e0004-6a45-4d1f-9b0a-3c2f8e4d5a10")
    static let scanResultsUUID = CBUUID(string: "7b1e0005-6a45-4d1f-9b0a-3c2f8e4d5a10")
    static let ethernetIPUUID  = CBUUID(string: "7b1e0006-6a45-4d1f-9b0a-3c2f8e4d5a10")
    static let leasesUUID      = CBUUID(string: "7b1e0007-6a45-4d1f-9b0a-3c2f8e4d5a10")
    static let relaysUUID      = CBUUID(string: "7b1e0008-6a45-4d1f-9b0a-3c2f8e4d5a10")
    static let victronUUID     = CBUUID(string: "7b1e0009-6a45-4d1f-9b0a-3c2f8e4d5a10")

    static let allCharacteristicUUIDs = [
        ssidUUID, passwordUUID, commandUUID, statusUUID, scanResultsUUID, ethernetIPUUID, leasesUUID, relaysUUID,
        victronUUID
    ]
}

struct WifiStatus: Decodable, Equatable {
    var state: String
    var ssid: String
    var ip: String
    var error: String
    // Whether the daemon's one-shot setup wizard has already completed
    // (its "finish" command ran) -- a Pi that just joined WiFi but
    // hasn't been finished yet also reports state == "connected", so
    // this (not just state) is what decides wizard vs. final details.
    //
    // Decoded leniently (defaulting to false): a Pi still running a
    // daemon build from before this field existed would otherwise fail
    // this whole decode and silently stall the wizard (no "finished"
    // key -> decode throws -> the app never processes the status update
    // at all, e.g. never triggers the first automatic network scan).
    var finished: Bool

    static let idle = WifiStatus(state: "idle", ssid: "", ip: "", error: "", finished: false)

    init(state: String, ssid: String, ip: String, error: String, finished: Bool) {
        self.state = state
        self.ssid = ssid
        self.ip = ip
        self.error = error
        self.finished = finished
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        ssid = try c.decode(String.self, forKey: .ssid)
        ip = try c.decode(String.self, forKey: .ip)
        error = try c.decode(String.self, forKey: .error)
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case state, ssid, ip, error, finished
    }
}

struct WifiScanResult: Decodable, Equatable, Identifiable {
    var ssid: String
    var rssi: Int
    var security: String

    var id: String { ssid }
}

/// EthernetIP's wire format is plain CSV, "<ip>,<rangeStart>,<rangeEnd>"
/// -- matches eth_control.hpp/main.cpp on the daemon side, which has no
/// JSON parser for the write side.
struct EthernetConfig: Equatable {
    var ip: String
    var rangeStart: Int
    var rangeEnd: Int

    static let unknown = EthernetConfig(ip: "", rangeStart: 2, rangeEnd: 200)

    var wireValue: String { "\(ip),\(rangeStart),\(rangeEnd)" }

    init(ip: String, rangeStart: Int, rangeEnd: Int) {
        self.ip = ip
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }

    init?(wireValue: String) {
        let parts = wireValue.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3, let start = Int(parts[1]), let end = Int(parts[2]) else { return nil }
        ip = String(parts[0])
        rangeStart = start
        rangeEnd = end
    }
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
