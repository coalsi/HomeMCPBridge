import Foundation
import HomeKit
import UIKit

#if targetEnvironment(macCatalyst)
import AppKit
#endif

/// HomeMCPBridge - Native macOS Menu Bar App for HomeKit MCP Server
///
/// Features:
/// - Menu bar icon with status (on Mac Catalyst)
/// - Status window showing activity log
/// - Native HomeKit access
/// - MCP protocol over stdio (for Claude Code integration)

// MARK: - Activity Log (Thread-safe)

class ActivityLog {
    static let shared = ActivityLog()

    private var entries: [String] = []
    private let lock = NSLock()
    private var updateCallback: (([String]) -> Void)?

    func log(_ message: String) {
        lock.lock()
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)"
        entries.append(entry)

        // Keep last 100 entries
        if entries.count > 100 {
            entries.removeFirst()
        }

        let currentEntries = entries
        lock.unlock()

        // Log to stderr for debugging
        FileHandle.standardError.write("\(entry)\n".data(using: .utf8)!)

        // Update UI on main thread
        DispatchQueue.main.async {
            self.updateCallback?(currentEntries)
            NotificationCenter.default.post(name: .logUpdated, object: nil)
        }
    }

    func getEntries() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func onUpdate(_ callback: @escaping ([String]) -> Void) {
        updateCallback = callback
    }
}

func log(_ message: String) {
    ActivityLog.shared.log(message)
}

extension Notification.Name {
    static let homeKitUpdated = Notification.Name("homeKitUpdated")
    static let logUpdated = Notification.Name("logUpdated")
}

// MARK: - Plugin System Models

enum DeviceSource: String, Codable, CaseIterable {
    case homeKit = "HomeKit"
    case govee = "Govee"
    case aqara = "Aqara"
}

struct UnifiedDevice {
    let id: String
    let name: String
    let room: String?
    let type: String
    let source: DeviceSource
    let isReachable: Bool
    let manufacturer: String?
    let model: String?
}

struct ControlResult {
    let success: Bool
    let action: String
    let newState: [String: Any]?
    let error: String?
}

struct PluginConfigField {
    let key: String
    let label: String
    let placeholder: String
    let isSecure: Bool
    let helpText: String?
}

enum PluginError: Error, LocalizedError {
    case notConfigured
    case authenticationFailed(String)
    case deviceNotFound(String)
    case rateLimitExceeded
    case networkError(Error)
    case unsupportedAction(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Plugin not configured"
        case .authenticationFailed(let msg): return "Auth failed: \(msg)"
        case .deviceNotFound(let id): return "Device not found: \(id)"
        case .rateLimitExceeded: return "Rate limit exceeded"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .unsupportedAction(let a): return "Unsupported action: \(a)"
        }
    }
}

// MARK: - Plugin Protocol

protocol DevicePlugin: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var isEnabled: Bool { get set }
    var isConfigured: Bool { get }
    var configurationFields: [PluginConfigField] { get }

    func initialize() async throws
    func shutdown() async
    func listDevices() async throws -> [UnifiedDevice]
    func getDeviceState(deviceId: String) async throws -> [String: Any]
    func controlDevice(deviceId: String, action: String, value: Any?) async throws -> ControlResult
    func configure(with credentials: [String: String]) async throws
    func clearCredentials()
}

// MARK: - Credential Manager (Keychain)

class CredentialManager {
    static let shared = CredentialManager()
    private let service = "com.coalsi.HomeMCPBridge"

    func store(key: String, value: String, plugin: String) {
        let account = "\(plugin).\(key)"
        guard let data = value.data(using: .utf8) else { return }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: account as CFString
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func retrieve(key: String, plugin: String) -> String? {
        let account = "\(plugin).\(key)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: account as CFString,
            kSecReturnData: true
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String, plugin: String) {
        let account = "\(plugin).\(key)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: account as CFString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Plugin Manager

class PluginManager {
    static let shared = PluginManager()

    private var plugins: [String: any DevicePlugin] = [:]
    private let defaults = UserDefaults.standard

    func register(_ plugin: any DevicePlugin) {
        plugins[plugin.identifier] = plugin
        // Load enabled state (HomeKit defaults to enabled)
        let enabledKey = "plugin.\(plugin.identifier).enabled"
        if plugin.identifier == "homekit" {
            plugin.isEnabled = true
        } else if defaults.object(forKey: enabledKey) != nil {
            plugin.isEnabled = defaults.bool(forKey: enabledKey)
        }
        log("Registered plugin: \(plugin.displayName)")
    }

    func allPlugins() -> [any DevicePlugin] {
        // Sort with HomeKit first, then alphabetically
        Array(plugins.values).sorted { p1, p2 in
            if p1.identifier == "homekit" { return true }
            if p2.identifier == "homekit" { return false }
            return p1.displayName < p2.displayName
        }
    }

    func activePlugins() -> [any DevicePlugin] {
        plugins.values.filter { $0.isEnabled && $0.isConfigured }
    }

    func plugin(withId id: String) -> (any DevicePlugin)? {
        plugins[id]
    }

    func setEnabled(_ enabled: Bool, for pluginId: String) {
        guard let plugin = plugins[pluginId] else { return }
        plugin.isEnabled = enabled
        defaults.set(enabled, forKey: "plugin.\(pluginId).enabled")

        if enabled && plugin.isConfigured {
            Task {
                do {
                    try await plugin.initialize()
                    log("\(plugin.displayName) enabled and initialized")
                } catch {
                    log("Failed to initialize \(plugin.displayName): \(error)")
                }
            }
        } else if !enabled {
            Task {
                await plugin.shutdown()
                log("\(plugin.displayName) disabled")
            }
        }
    }

    func listAllDevices() async -> [UnifiedDevice] {
        var allDevices: [UnifiedDevice] = []
        for plugin in activePlugins() {
            do {
                let devices = try await plugin.listDevices()
                allDevices.append(contentsOf: devices)
            } catch {
                log("Error listing devices from \(plugin.displayName): \(error)")
            }
        }
        return allDevices
    }

    func findDevice(name: String) async -> (UnifiedDevice, any DevicePlugin)? {
        let searchName = name.lowercased()
        for plugin in activePlugins() {
            if let devices = try? await plugin.listDevices(),
               let device = devices.first(where: { $0.name.lowercased() == searchName }) {
                return (device, plugin)
            }
        }
        return nil
    }

    func getDeviceState(name: String) async throws -> [String: Any] {
        guard let (device, plugin) = await findDevice(name: name) else {
            throw PluginError.deviceNotFound(name)
        }
        return try await plugin.getDeviceState(deviceId: device.id)
    }

    func controlDevice(name: String, action: String, value: Any?) async throws -> ControlResult {
        guard let (device, plugin) = await findDevice(name: name) else {
            throw PluginError.deviceNotFound(name)
        }
        return try await plugin.controlDevice(deviceId: device.id, action: action, value: value)
    }
}

// MARK: - HomeKit Manager

class HomeKitManager: NSObject, HMHomeManagerDelegate {
    static let shared = HomeKitManager()

    private var homeManager: HMHomeManager!
    private var isReady = false
    private var readyCallbacks: [() -> Void] = []

    var deviceCount: Int {
        homeManager?.homes.reduce(0) { $0 + $1.accessories.count } ?? 0
    }

    var homeCount: Int {
        homeManager?.homes.count ?? 0
    }

    override init() {
        super.init()
        homeManager = HMHomeManager()
        homeManager.delegate = self
    }

    func waitUntilReady(completion: @escaping () -> Void) {
        if isReady {
            completion()
        } else {
            readyCallbacks.append(completion)
        }
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        isReady = true
        log("HomeKit ready - Found \(manager.homes.count) home(s), \(deviceCount) device(s)")

        for callback in readyCallbacks {
            callback()
        }
        readyCallbacks.removeAll()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .homeKitUpdated, object: nil)
        }
    }

    // MARK: - Tool Implementations

    func listHomes() -> [[String: Any]] {
        return homeManager.homes.map { home in
            [
                "id": home.uniqueIdentifier.uuidString,
                "name": home.name,
                "isPrimary": home.isPrimary,
                "roomCount": home.rooms.count,
                "accessoryCount": home.accessories.count
            ]
        }
    }

    func listRooms() -> [[String: Any]] {
        var rooms: [[String: Any]] = []
        for home in homeManager.homes {
            for room in home.rooms {
                rooms.append([
                    "id": room.uniqueIdentifier.uuidString,
                    "name": room.name,
                    "homeName": home.name,
                    "accessoryCount": room.accessories.count
                ])
            }
        }
        return rooms
    }

    func listDevices() -> [[String: Any]] {
        var devices: [[String: Any]] = []
        for home in homeManager.homes {
            for accessory in home.accessories {
                devices.append(accessoryToDict(accessory, homeName: home.name))
            }
        }
        return devices
    }

    func getDeviceState(name: String, completion: @escaping ([String: Any]) -> Void) {
        guard let (accessory, _) = findAccessory(name: name) else {
            completion(["error": "Device not found: \(name)", "success": false])
            return
        }

        var state: [String: Any] = [
            "name": accessory.name,
            "reachable": accessory.isReachable,
            "room": accessory.room?.name ?? "Unknown"
        ]

        let controllableService = accessory.services.first { service in
            [HMServiceTypeLightbulb, HMServiceTypeSwitch, HMServiceTypeOutlet,
             HMServiceTypeFan, HMServiceTypeGarageDoorOpener, HMServiceTypeLockMechanism]
                .contains(service.serviceType)
        }

        guard let service = controllableService else {
            state["error"] = "No controllable service"
            completion(state)
            return
        }

        state["type"] = serviceTypeName(service.serviceType)

        let group = DispatchGroup()
        var chars: [String: Any] = [:]

        for char in service.characteristics where char.properties.contains(HMCharacteristicPropertyReadable) {
            group.enter()
            char.readValue { _ in
                if let value = char.value {
                    chars[self.characteristicName(char.characteristicType)] = value
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if let on = chars["PowerState"] as? Bool {
                state["isOn"] = on
            }
            if let brightness = chars["Brightness"] as? Int {
                state["brightness"] = brightness
            }
            if let hue = chars["Hue"] as? Double {
                state["hue"] = hue
            }
            if let sat = chars["Saturation"] as? Double {
                state["saturation"] = sat
            }
            if let lockState = chars["LockCurrentState"] as? Int {
                state["isLocked"] = lockState == 1
            }
            if let doorState = chars["CurrentDoorState"] as? Int {
                state["doorState"] = ["open", "closed", "opening", "closing", "stopped"][doorState]
            }

            state["success"] = true
            completion(state)
        }
    }

    func controlDevice(name: String, action: String, value: Any?, completion: @escaping ([String: Any]) -> Void) {
        log("Control: \(name) -> \(action)")

        guard let (accessory, _) = findAccessory(name: name) else {
            completion(["error": "Device not found: \(name)", "success": false])
            return
        }

        guard accessory.isReachable else {
            completion(["error": "Device not reachable", "success": false])
            return
        }

        let controllableService = accessory.services.first { service in
            [HMServiceTypeLightbulb, HMServiceTypeSwitch, HMServiceTypeOutlet,
             HMServiceTypeFan, HMServiceTypeGarageDoorOpener, HMServiceTypeLockMechanism]
                .contains(service.serviceType)
        }

        guard let service = controllableService else {
            completion(["error": "No controllable service", "success": false])
            return
        }

        switch action.lowercased() {
        case "on", "turn_on":
            setPower(service, value: true, completion: completion)
        case "off", "turn_off":
            setPower(service, value: false, completion: completion)
        case "toggle":
            togglePower(service, completion: completion)
        case "brightness", "set_brightness":
            if let b = value as? Int ?? Int(value as? String ?? "") {
                setBrightness(service, value: b, completion: completion)
            } else {
                completion(["error": "Invalid brightness", "success": false])
            }
        case "color", "set_color":
            if let dict = value as? [String: Any],
               let hue = dict["hue"] as? Double,
               let sat = dict["saturation"] as? Double {
                setColor(service, hue: hue, saturation: sat, completion: completion)
            } else {
                completion(["error": "Invalid color (need hue, saturation)", "success": false])
            }
        case "lock":
            setLock(service, locked: true, completion: completion)
        case "unlock":
            setLock(service, locked: false, completion: completion)
        case "open":
            setDoor(service, open: true, completion: completion)
        case "close":
            setDoor(service, open: false, completion: completion)
        default:
            completion(["error": "Unknown action: \(action)", "success": false])
        }
    }

    // MARK: - Private Helpers

    private func findAccessory(name: String) -> (HMAccessory, HMHome)? {
        let searchName = name.lowercased()
        for home in homeManager.homes {
            if let acc = home.accessories.first(where: { $0.name.lowercased() == searchName }) {
                return (acc, home)
            }
        }
        return nil
    }

    private func accessoryToDict(_ accessory: HMAccessory, homeName: String) -> [String: Any] {
        var type = "unknown"
        for service in accessory.services {
            switch service.serviceType {
            case HMServiceTypeLightbulb: type = "light"
            case HMServiceTypeSwitch: type = "switch"
            case HMServiceTypeOutlet: type = "outlet"
            case HMServiceTypeFan: type = "fan"
            case HMServiceTypeGarageDoorOpener: type = "garage_door"
            case HMServiceTypeLockMechanism: type = "lock"
            case HMServiceTypeThermostat: type = "thermostat"
            case HMServiceTypeTemperatureSensor: type = "sensor"
            default: break
            }
            if type != "unknown" { break }
        }

        return [
            "id": accessory.uniqueIdentifier.uuidString,
            "name": accessory.name,
            "room": accessory.room?.name ?? "Default Room",
            "home": homeName,
            "type": type,
            "reachable": accessory.isReachable,
            "manufacturer": accessory.manufacturer ?? "Unknown",
            "model": accessory.model ?? "Unknown"
        ]
    }

    private func serviceTypeName(_ type: String) -> String {
        switch type {
        case HMServiceTypeLightbulb: return "light"
        case HMServiceTypeSwitch: return "switch"
        case HMServiceTypeOutlet: return "outlet"
        case HMServiceTypeFan: return "fan"
        case HMServiceTypeGarageDoorOpener: return "garage_door"
        case HMServiceTypeLockMechanism: return "lock"
        default: return "unknown"
        }
    }

    private func characteristicName(_ type: String) -> String {
        switch type {
        case HMCharacteristicTypePowerState: return "PowerState"
        case HMCharacteristicTypeBrightness: return "Brightness"
        case HMCharacteristicTypeHue: return "Hue"
        case HMCharacteristicTypeSaturation: return "Saturation"
        case HMCharacteristicTypeColorTemperature: return "ColorTemperature"
        case HMCharacteristicTypeCurrentDoorState: return "CurrentDoorState"
        case HMCharacteristicTypeTargetDoorState: return "TargetDoorState"
        case "00000019-0000-1000-8000-0026BB765291": return "LockCurrentState"
        case "00000020-0000-1000-8000-0026BB765291": return "LockTargetState"
        default: return type
        }
    }

    private func setPower(_ service: HMService, value: Bool, completion: @escaping ([String: Any]) -> Void) {
        guard let char = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState }) else {
            completion(["error": "No power characteristic", "success": false])
            return
        }
        char.writeValue(value) { error in
            if let error = error {
                completion(["error": error.localizedDescription, "success": false])
            } else {
                completion(["success": true, "action": value ? "on" : "off"])
            }
        }
    }

    private func togglePower(_ service: HMService, completion: @escaping ([String: Any]) -> Void) {
        guard let char = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState }) else {
            completion(["error": "No power characteristic", "success": false])
            return
        }
        char.readValue { _ in
            let current = char.value as? Bool ?? false
            char.writeValue(!current) { error in
                if let error = error {
                    completion(["error": error.localizedDescription, "success": false])
                } else {
                    completion(["success": true, "action": "toggle", "newState": !current])
                }
            }
        }
    }

    private func setBrightness(_ service: HMService, value: Int, completion: @escaping ([String: Any]) -> Void) {
        guard let char = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeBrightness }) else {
            completion(["error": "No brightness characteristic", "success": false])
            return
        }
        let clamped = min(100, max(0, value))
        char.writeValue(clamped) { error in
            if let error = error {
                completion(["error": error.localizedDescription, "success": false])
            } else {
                completion(["success": true, "brightness": clamped])
            }
        }
    }

    private func setColor(_ service: HMService, hue: Double, saturation: Double, completion: @escaping ([String: Any]) -> Void) {
        let group = DispatchGroup()
        var errors: [String] = []

        if let hueChar = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeHue }) {
            group.enter()
            hueChar.writeValue(hue) { error in
                if let error = error { errors.append(error.localizedDescription) }
                group.leave()
            }
        }

        if let satChar = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeSaturation }) {
            group.enter()
            satChar.writeValue(saturation) { error in
                if let error = error { errors.append(error.localizedDescription) }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if errors.isEmpty {
                completion(["success": true, "hue": hue, "saturation": saturation])
            } else {
                completion(["error": errors.joined(separator: ", "), "success": false])
            }
        }
    }

    private func setLock(_ service: HMService, locked: Bool, completion: @escaping ([String: Any]) -> Void) {
        guard let char = service.characteristics.first(where: { $0.characteristicType == "00000020-0000-1000-8000-0026BB765291" }) else {
            completion(["error": "No lock characteristic", "success": false])
            return
        }
        char.writeValue(locked ? 1 : 0) { error in
            if let error = error {
                completion(["error": error.localizedDescription, "success": false])
            } else {
                completion(["success": true, "action": locked ? "locked" : "unlocked"])
            }
        }
    }

    private func setDoor(_ service: HMService, open: Bool, completion: @escaping ([String: Any]) -> Void) {
        guard let char = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetDoorState }) else {
            completion(["error": "No door characteristic", "success": false])
            return
        }
        char.writeValue(open ? 0 : 1) { error in
            if let error = error {
                completion(["error": error.localizedDescription, "success": false])
            } else {
                completion(["success": true, "action": open ? "opened" : "closed"])
            }
        }
    }
}

// MARK: - HomeKit Plugin

class HomeKitPlugin: DevicePlugin {
    let identifier = "homekit"
    let displayName = "Apple HomeKit"
    var isEnabled = true
    var isConfigured: Bool { true }
    var configurationFields: [PluginConfigField] { [] }

    private let manager = HomeKitManager.shared

    func initialize() async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            manager.waitUntilReady { cont.resume() }
        }
        log("HomeKit plugin initialized with \(manager.deviceCount) devices")
    }

    func shutdown() async {}
    func configure(with credentials: [String: String]) async throws {}
    func clearCredentials() {}

    func listDevices() async throws -> [UnifiedDevice] {
        manager.listDevices().map { dict in
            UnifiedDevice(
                id: dict["id"] as? String ?? "",
                name: dict["name"] as? String ?? "",
                room: dict["room"] as? String,
                type: dict["type"] as? String ?? "unknown",
                source: .homeKit,
                isReachable: dict["reachable"] as? Bool ?? false,
                manufacturer: dict["manufacturer"] as? String,
                model: dict["model"] as? String
            )
        }
    }

    func getDeviceState(deviceId: String) async throws -> [String: Any] {
        let devices = try await listDevices()
        guard let device = devices.first(where: { $0.id == deviceId }) else {
            throw PluginError.deviceNotFound(deviceId)
        }
        return await withCheckedContinuation { cont in
            manager.getDeviceState(name: device.name) { state in
                cont.resume(returning: state)
            }
        }
    }

    func controlDevice(deviceId: String, action: String, value: Any?) async throws -> ControlResult {
        let devices = try await listDevices()
        guard let device = devices.first(where: { $0.id == deviceId }) else {
            throw PluginError.deviceNotFound(deviceId)
        }
        let result = await withCheckedContinuation { cont in
            manager.controlDevice(name: device.name, action: action, value: value) { res in
                cont.resume(returning: res)
            }
        }
        return ControlResult(
            success: result["success"] as? Bool ?? false,
            action: action,
            newState: result,
            error: result["error"] as? String
        )
    }
}

// MARK: - Govee Plugin

class GoveePlugin: DevicePlugin {
    let identifier = "govee"
    let displayName = "Govee"
    var isEnabled = false

    private var cachedDevices: [GoveeDevice] = []
    private var lastFetch: Date?
    private let baseURL = "https://openapi.api.govee.com/router/api/v1"

    var apiKey: String? {
        CredentialManager.shared.retrieve(key: "apiKey", plugin: identifier)
    }

    var isConfigured: Bool { apiKey != nil && !apiKey!.isEmpty }

    var configurationFields: [PluginConfigField] {
        [PluginConfigField(
            key: "apiKey",
            label: "API Key",
            placeholder: "Enter your Govee API key",
            isSecure: true,
            helpText: "Get from Govee app: Settings > About Us > Apply for API Key"
        )]
    }

    func initialize() async throws {
        guard isConfigured else { throw PluginError.notConfigured }
        _ = try await fetchDevices()
        log("Govee plugin initialized with \(cachedDevices.count) devices")
    }

    func shutdown() async { cachedDevices = [] }

    func configure(with credentials: [String: String]) async throws {
        guard let key = credentials["apiKey"], !key.isEmpty else {
            throw PluginError.notConfigured
        }
        CredentialManager.shared.store(key: "apiKey", value: key, plugin: identifier)
        _ = try await fetchDevices() // Validate key
    }

    func clearCredentials() {
        CredentialManager.shared.delete(key: "apiKey", plugin: identifier)
        cachedDevices = []
    }

    func listDevices() async throws -> [UnifiedDevice] {
        let devices = try await fetchDevices()
        return devices.map { $0.toUnified() }
    }

    func getDeviceState(deviceId: String) async throws -> [String: Any] {
        guard let device = cachedDevices.first(where: { $0.device == deviceId }) else {
            throw PluginError.deviceNotFound(deviceId)
        }
        return try await fetchState(device: device)
    }

    func controlDevice(deviceId: String, action: String, value: Any?) async throws -> ControlResult {
        guard let device = cachedDevices.first(where: { $0.device == deviceId }) else {
            throw PluginError.deviceNotFound(deviceId)
        }
        try await sendCommand(device: device, action: action, value: value)
        return ControlResult(success: true, action: action, newState: nil, error: nil)
    }

    // MARK: - Govee API Methods

    private func fetchDevices() async throws -> [GoveeDevice] {
        if let lastFetch = lastFetch, Date().timeIntervalSince(lastFetch) < 300, !cachedDevices.isEmpty {
            return cachedDevices
        }

        guard let apiKey = apiKey else { throw PluginError.notConfigured }

        var request = URLRequest(url: URL(string: "\(baseURL)/user/devices")!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Govee-API-Key")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PluginError.networkError(NSError(domain: "Govee", code: -1))
        }

        switch http.statusCode {
        case 200:
            let decoded = try JSONDecoder().decode(GoveeResponse.self, from: data)
            cachedDevices = decoded.data
            lastFetch = Date()
            return cachedDevices
        case 401: throw PluginError.authenticationFailed("Invalid API key")
        case 429: throw PluginError.rateLimitExceeded
        default: throw PluginError.networkError(NSError(domain: "Govee", code: http.statusCode))
        }
    }

    private func fetchState(device: GoveeDevice) async throws -> [String: Any] {
        guard let apiKey = apiKey else { throw PluginError.notConfigured }

        var request = URLRequest(url: URL(string: "\(baseURL)/device/state")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Govee-API-Key")

        let body: [String: Any] = [
            "requestId": UUID().uuidString,
            "payload": ["sku": device.sku, "device": device.device]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["name": device.deviceName, "source": "govee"]
        }
        var state = json["payload"] as? [String: Any] ?? [:]
        state["name"] = device.deviceName
        state["source"] = "govee"
        return state
    }

    private func sendCommand(device: GoveeDevice, action: String, value: Any?) async throws {
        guard let apiKey = apiKey else { throw PluginError.notConfigured }

        let capability: [String: Any]
        switch action.lowercased() {
        case "on", "turn_on":
            capability = ["type": "devices.capabilities.on_off", "instance": "powerSwitch", "value": 1]
        case "off", "turn_off":
            capability = ["type": "devices.capabilities.on_off", "instance": "powerSwitch", "value": 0]
        case "brightness", "set_brightness":
            guard let b = value as? Int ?? Int(value as? String ?? "") else {
                throw PluginError.unsupportedAction("brightness requires integer value")
            }
            capability = ["type": "devices.capabilities.range", "instance": "brightness", "value": b]
        case "color", "set_color":
            guard let c = value as? [String: Any],
                  let r = c["r"] as? Int ?? c["red"] as? Int,
                  let g = c["g"] as? Int ?? c["green"] as? Int,
                  let b = c["b"] as? Int ?? c["blue"] as? Int else {
                throw PluginError.unsupportedAction("color requires r, g, b values")
            }
            let rgb = (r << 16) | (g << 8) | b
            capability = ["type": "devices.capabilities.color_setting", "instance": "colorRgb", "value": rgb]
        default:
            throw PluginError.unsupportedAction(action)
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/device/control")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Govee-API-Key")

        let body: [String: Any] = [
            "requestId": UUID().uuidString,
            "payload": ["sku": device.sku, "device": device.device, "capability": capability]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PluginError.networkError(NSError(domain: "Govee", code: -1, userInfo: [NSLocalizedDescriptionKey: "Control command failed"]))
        }
        log("Govee: \(device.deviceName) -> \(action)")
    }
}

// Govee Models
struct GoveeResponse: Codable {
    let data: [GoveeDevice]
}

struct GoveeDevice: Codable {
    let sku: String
    let device: String
    let deviceName: String

    func toUnified() -> UnifiedDevice {
        let type: String
        if sku.hasPrefix("H6") || sku.lowercased().contains("light") {
            type = "light"
        } else if sku.lowercased().contains("plug") {
            type = "outlet"
        } else if sku.lowercased().contains("purifier") {
            type = "air_purifier"
        } else if sku.lowercased().contains("humidifier") {
            type = "humidifier"
        } else {
            type = "unknown"
        }
        return UnifiedDevice(
            id: device,
            name: deviceName,
            room: nil,
            type: type,
            source: .govee,
            isReachable: true,
            manufacturer: "Govee",
            model: sku
        )
    }
}

// MARK: - Aqara Plugin

class AqaraPlugin: DevicePlugin {
    let identifier = "aqara"
    let displayName = "Aqara"
    var isEnabled = false

    private let credentials = CredentialManager.shared
    private var cachedDevices: [AqaraDevice] = []

    // Region endpoints
    private var baseURL: String {
        let region = credentials.retrieve(key: "region", plugin: identifier) ?? "us"
        switch region.lowercased() {
        case "cn": return "https://open-cn.aqara.com"
        case "eu": return "https://open-eur.aqara.com"
        default: return "https://open-usa.aqara.com"
        }
    }

    var accessToken: String? { credentials.retrieve(key: "accessToken", plugin: identifier) }
    var refreshToken: String? { credentials.retrieve(key: "refreshToken", plugin: identifier) }
    var clientId: String? { credentials.retrieve(key: "clientId", plugin: identifier) }
    var clientSecret: String? { credentials.retrieve(key: "clientSecret", plugin: identifier) }

    var isConfigured: Bool { accessToken != nil && !accessToken!.isEmpty }

    var configurationFields: [PluginConfigField] {
        [
            PluginConfigField(key: "clientId", label: "Client ID", placeholder: "Aqara developer app ID", isSecure: false, helpText: "From developer.aqara.com"),
            PluginConfigField(key: "clientSecret", label: "Client Secret", placeholder: "Aqara developer secret", isSecure: true, helpText: nil),
            PluginConfigField(key: "authCode", label: "Authorization Code", placeholder: "Paste OAuth code here", isSecure: false, helpText: "Get from OAuth flow - see instructions"),
            PluginConfigField(key: "region", label: "Region", placeholder: "us, eu, or cn", isSecure: false, helpText: "Your Aqara account region")
        ]
    }

    func initialize() async throws {
        guard isConfigured else { throw PluginError.notConfigured }
        try await refreshTokenIfNeeded()
        _ = try await fetchDevices()
        log("Aqara plugin initialized with \(cachedDevices.count) devices")
    }

    func shutdown() async { cachedDevices = [] }

    func configure(with creds: [String: String]) async throws {
        if let clientId = creds["clientId"], !clientId.isEmpty {
            credentials.store(key: "clientId", value: clientId, plugin: identifier)
        }
        if let clientSecret = creds["clientSecret"], !clientSecret.isEmpty {
            credentials.store(key: "clientSecret", value: clientSecret, plugin: identifier)
        }
        if let region = creds["region"], !region.isEmpty {
            credentials.store(key: "region", value: region, plugin: identifier)
        }

        // If auth code provided, exchange for tokens
        if let authCode = creds["authCode"], !authCode.isEmpty {
            try await exchangeAuthCode(authCode)
        }
    }

    func clearCredentials() {
        for key in ["accessToken", "refreshToken", "clientId", "clientSecret", "region", "tokenExpiry", "authCode"] {
            credentials.delete(key: key, plugin: identifier)
        }
        cachedDevices = []
    }

    // OAuth URL for user to authorize
    func getOAuthURL() -> URL? {
        guard let clientId = clientId else { return nil }
        var components = URLComponents(string: "\(baseURL)/v3.0/open/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: "homemcpbridge://oauth/aqara"),
            URLQueryItem(name: "state", value: UUID().uuidString)
        ]
        return components.url
    }

    private func exchangeAuthCode(_ code: String) async throws {
        guard let clientId = clientId, let clientSecret = clientSecret else {
            throw PluginError.notConfigured
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/v3.0/open/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=authorization_code&code=\(code)&client_id=\(clientId)&client_secret=\(clientSecret)&redirect_uri=homemcpbridge://oauth/aqara"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(AqaraTokenResponse.self, from: data)

        storeTokens(response)
        log("Aqara: Obtained access token")
    }

    private func storeTokens(_ response: AqaraTokenResponse) {
        credentials.store(key: "accessToken", value: response.access_token, plugin: identifier)
        credentials.store(key: "refreshToken", value: response.refresh_token, plugin: identifier)
        let expiry = Date().addingTimeInterval(TimeInterval(response.expires_in))
        credentials.store(key: "tokenExpiry", value: String(expiry.timeIntervalSince1970), plugin: identifier)
    }

    private func refreshTokenIfNeeded() async throws {
        if let expiryStr = credentials.retrieve(key: "tokenExpiry", plugin: identifier),
           let expiry = TimeInterval(expiryStr),
           Date().timeIntervalSince1970 < expiry - 3600 {
            return // Token still valid
        }

        guard let refreshToken = refreshToken, let clientId = clientId, let clientSecret = clientSecret else {
            throw PluginError.authenticationFailed("Missing refresh token or credentials")
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/v3.0/open/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(clientId)&client_secret=\(clientSecret)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(AqaraTokenResponse.self, from: data)
        storeTokens(response)
        log("Aqara: Refreshed access token")
    }

    func listDevices() async throws -> [UnifiedDevice] {
        let devices = try await fetchDevices()
        return devices.map { $0.toUnified() }
    }

    func getDeviceState(deviceId: String) async throws -> [String: Any] {
        guard let device = cachedDevices.first(where: { $0.did == deviceId }) else {
            throw PluginError.deviceNotFound(deviceId)
        }
        return ["deviceId": deviceId, "name": device.deviceName, "source": "aqara", "model": device.model]
    }

    func controlDevice(deviceId: String, action: String, value: Any?) async throws -> ControlResult {
        guard let _ = cachedDevices.first(where: { $0.did == deviceId }) else {
            throw PluginError.deviceNotFound(deviceId)
        }

        // Basic Aqara control - would need expansion for real implementation
        guard let accessToken = accessToken else { throw PluginError.notConfigured }

        var request = URLRequest(url: URL(string: "\(baseURL)/v3.0/open/api")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accessToken, forHTTPHeaderField: "Accesstoken")

        let resourceValue: Int
        switch action.lowercased() {
        case "on", "turn_on": resourceValue = 1
        case "off", "turn_off": resourceValue = 0
        default: throw PluginError.unsupportedAction(action)
        }

        let body: [String: Any] = [
            "intent": "write.resource.device",
            "data": [
                "did": deviceId,
                "resources": [["resourceId": "4.1.85", "value": resourceValue]]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PluginError.networkError(NSError(domain: "Aqara", code: -1))
        }

        log("Aqara: Controlled device \(deviceId) -> \(action)")
        return ControlResult(success: true, action: action, newState: nil, error: nil)
    }

    private func fetchDevices() async throws -> [AqaraDevice] {
        guard let accessToken = accessToken else { throw PluginError.notConfigured }

        var request = URLRequest(url: URL(string: "\(baseURL)/v3.0/open/api")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accessToken, forHTTPHeaderField: "Accesstoken")

        let body: [String: Any] = ["intent": "query.device.info", "data": [:]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else {
            return []
        }

        cachedDevices = result.compactMap { AqaraDevice(from: $0) }
        return cachedDevices
    }
}

// Aqara Models
struct AqaraTokenResponse: Codable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
}

struct AqaraDevice {
    let did: String
    let model: String
    let deviceName: String
    let roomName: String?

    init?(from dict: [String: Any]) {
        guard let did = dict["did"] as? String,
              let model = dict["model"] as? String else { return nil }
        self.did = did
        self.model = model
        self.deviceName = dict["deviceName"] as? String ?? "Aqara Device"
        self.roomName = dict["roomName"] as? String
    }

    func toUnified() -> UnifiedDevice {
        let type: String
        let modelLower = model.lowercased()
        if modelLower.contains("light") || modelLower.contains("bulb") {
            type = "light"
        } else if modelLower.contains("plug") || modelLower.contains("outlet") {
            type = "outlet"
        } else if modelLower.contains("switch") {
            type = "switch"
        } else if modelLower.contains("sensor") || modelLower.contains("motion") || modelLower.contains("door") {
            type = "sensor"
        } else if modelLower.contains("curtain") {
            type = "curtain"
        } else if modelLower.contains("hub") || modelLower.contains("gateway") {
            type = "hub"
        } else {
            type = "unknown"
        }

        return UnifiedDevice(
            id: did,
            name: deviceName,
            room: roomName,
            type: type,
            source: .aqara,
            isReachable: true,
            manufacturer: "Aqara",
            model: model
        )
    }
}

// MARK: - MCP Server

class MCPServer {
    private let homeKit = HomeKitManager.shared
    private var isRunning = false

    private let tools: [[String: Any]] = [
        [
            "name": "list_devices",
            "description": "List all devices from HomeKit and enabled plugins (Govee, Aqara) with their names, rooms, types, source, and reachability status.",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ],
        [
            "name": "list_rooms",
            "description": "List all rooms in all HomeKit homes.",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ],
        [
            "name": "get_device_state",
            "description": "Get the current state of a device (on/off, brightness, color, etc.). Works with HomeKit, Govee, and Aqara devices.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string", "description": "The name of the device"]],
                "required": ["name"]
            ]
        ],
        [
            "name": "control_device",
            "description": "Control a device. Works with HomeKit, Govee, and Aqara. Actions: on, off, toggle, brightness (0-100), color ({hue, saturation} for HomeKit, {r, g, b} for Govee), lock, unlock, open, close.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The name of the device"],
                    "action": ["type": "string", "description": "Action: on, off, toggle, brightness, color, lock, unlock, open, close"],
                    "value": ["description": "Value for the action"]
                ],
                "required": ["name", "action"]
            ]
        ],
        [
            "name": "list_homes",
            "description": "List all HomeKit homes configured on this Mac.",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ]
    ]

    func run() {
        isRunning = true
        log("MCP Server listening on stdin...")

        while isRunning {
            guard let line = readLine() else { break }
            guard let data = line.data(using: .utf8) else { continue }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    handleMessage(json)
                }
            } catch {
                log("JSON parse error: \(error.localizedDescription)")
            }
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        let id = message["id"] as? Int
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            log("MCP: Initialize request")
            respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "HomeMCPBridge", "version": "1.0.0"]
            ])

        case "notifications/initialized":
            log("MCP: Client initialized")

        case "tools/list":
            log("MCP: Tools list request")
            respond(id: id, result: ["tools": tools])

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            log("MCP: Tool call -> \(toolName)")
            handleToolCall(id: id, name: toolName, arguments: args)

        default:
            log("MCP: Unknown method -> \(method)")
            respondError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleToolCall(id: Int?, name: String, arguments: [String: Any]) {
        switch name {
        case "list_devices":
            // Use PluginManager to get devices from all active plugins
            let semaphore = DispatchSemaphore(value: 0)
            var deviceDicts: [[String: Any]] = []

            Task {
                let devices = await PluginManager.shared.listAllDevices()
                deviceDicts = devices.map { d -> [String: Any] in
                    [
                        "id": d.id,
                        "name": d.name,
                        "room": d.room ?? "Unknown",
                        "type": d.type,
                        "reachable": d.isReachable,
                        "source": d.source.rawValue,
                        "manufacturer": d.manufacturer ?? "Unknown",
                        "model": d.model ?? "Unknown"
                    ]
                }
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 30)
            log("  -> Found \(deviceDicts.count) devices from all plugins")
            respondToolResult(id: id, result: ["devices": deviceDicts, "count": deviceDicts.count])

        case "list_rooms":
            let rooms = homeKit.listRooms()
            log("  -> Found \(rooms.count) rooms")
            respondToolResult(id: id, result: ["rooms": rooms, "count": rooms.count])

        case "list_homes":
            let homes = homeKit.listHomes()
            log("  -> Found \(homes.count) homes")
            respondToolResult(id: id, result: ["homes": homes, "count": homes.count])

        case "get_device_state":
            guard let deviceName = arguments["name"] as? String else {
                respondToolResult(id: id, result: ["error": "Missing 'name' parameter"])
                return
            }

            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any] = [:]

            Task {
                do {
                    result = try await PluginManager.shared.getDeviceState(name: deviceName)
                    result["success"] = true
                } catch {
                    result = ["error": error.localizedDescription, "success": false]
                }
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 15)
            log("  -> State for '\(deviceName)'")
            respondToolResult(id: id, result: result)

        case "control_device":
            guard let deviceName = arguments["name"] as? String,
                  let action = arguments["action"] as? String else {
                respondToolResult(id: id, result: ["error": "Missing 'name' or 'action' parameter"])
                return
            }

            let value = arguments["value"]

            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any] = [:]

            Task {
                do {
                    let controlResult = try await PluginManager.shared.controlDevice(name: deviceName, action: action, value: value)
                    result = [
                        "success": controlResult.success,
                        "action": controlResult.action,
                        "newState": controlResult.newState ?? [:],
                        "error": controlResult.error as Any
                    ]
                } catch {
                    result = ["error": error.localizedDescription, "success": false]
                }
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 15)
            respondToolResult(id: id, result: result)

        default:
            respondToolResult(id: id, result: ["error": "Unknown tool: \(name)"])
        }
    }

    private func respond(id: Int?, result: [String: Any]) {
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id as Any, "result": result]
        sendResponse(response)
    }

    private func respondError(id: Int?, code: Int, message: String) {
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id as Any, "error": ["code": code, "message": message]]
        sendResponse(response)
    }

    private func respondToolResult(id: Int?, result: [String: Any]) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": ["content": [["type": "text", "text": jsonString(result)]]]
        ]
        sendResponse(response)
    }

    private func sendResponse(_ response: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: response),
           let string = String(data: data, encoding: .utf8) {
            print(string)
            fflush(stdout)
        }
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }
}

// MARK: - Settings Manager

class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: "showMenuBarIcon") }
        set {
            defaults.set(newValue, forKey: "showMenuBarIcon")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    var showDockIcon: Bool {
        get { defaults.object(forKey: "showDockIcon") == nil ? true : defaults.bool(forKey: "showDockIcon") }
        set {
            defaults.set(newValue, forKey: "showDockIcon")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    init() {
        // Set defaults on first run
        if defaults.object(forKey: "showMenuBarIcon") == nil {
            defaults.set(true, forKey: "showMenuBarIcon")
        }
        if defaults.object(forKey: "showDockIcon") == nil {
            defaults.set(true, forKey: "showDockIcon")
        }
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("settingsChanged")
}

// MARK: - Status View Controller

class StatusViewController: UIViewController {
    private var textView: UITextView!
    private var statusLabel: UILabel!
    private var menuBarSwitch: UISwitch!
    private var dockSwitch: UISwitch!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()

        NotificationCenter.default.addObserver(self, selector: #selector(updateLog), name: .logUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateStatus), name: .homeKitUpdated, object: nil)

        updateLog()
        updateStatus()
    }

    private func setupUI() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        // Header
        let headerLabel = UILabel()
        headerLabel.text = "HomeMCPBridge"
        headerLabel.font = .boldSystemFont(ofSize: 24)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerLabel)

        // Subtitle
        let subtitleLabel = UILabel()
        subtitleLabel.text = "Native HomeKit MCP Server for Claude Code"
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subtitleLabel)

        // Status
        statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .systemGreen
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        // Separator
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator)

        // Settings section header
        let settingsHeader = UILabel()
        settingsHeader.text = "Settings"
        settingsHeader.font = .boldSystemFont(ofSize: 16)
        settingsHeader.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(settingsHeader)

        // Menu bar toggle
        let menuBarLabel = UILabel()
        menuBarLabel.text = "Show Menu Bar Icon"
        menuBarLabel.font = .systemFont(ofSize: 14)
        menuBarLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(menuBarLabel)

        menuBarSwitch = UISwitch()
        menuBarSwitch.isOn = SettingsManager.shared.showMenuBarIcon
        menuBarSwitch.addTarget(self, action: #selector(menuBarSwitchChanged), for: .valueChanged)
        menuBarSwitch.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(menuBarSwitch)

        // Dock toggle
        let dockLabel = UILabel()
        dockLabel.text = "Show Dock Icon"
        dockLabel.font = .systemFont(ofSize: 14)
        dockLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dockLabel)

        dockSwitch = UISwitch()
        dockSwitch.isOn = SettingsManager.shared.showDockIcon
        dockSwitch.addTarget(self, action: #selector(dockSwitchChanged), for: .valueChanged)
        dockSwitch.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dockSwitch)

        // Settings note
        let settingsNote = UILabel()
        settingsNote.text = "Note: At least one must be enabled."
        settingsNote.font = .systemFont(ofSize: 11)
        settingsNote.textColor = .secondaryLabel
        settingsNote.numberOfLines = 0
        settingsNote.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(settingsNote)

        // Login items button
        let loginButton = UIButton(type: .system)
        loginButton.setTitle("Add to Login Items...", for: .normal)
        loginButton.addTarget(self, action: #selector(openLoginItems), for: .touchUpInside)
        loginButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(loginButton)

        // Separator 2
        let separator2 = UIView()
        separator2.backgroundColor = .separator
        separator2.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator2)

        // MCP Config section header
        let configHeader = UILabel()
        configHeader.text = "MCP Configuration"
        configHeader.font = .boldSystemFont(ofSize: 16)
        configHeader.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(configHeader)

        // Config description
        let configDesc = UILabel()
        configDesc.text = "Add this to your project's .mcp.json:"
        configDesc.font = .systemFont(ofSize: 12)
        configDesc.textColor = .secondaryLabel
        configDesc.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(configDesc)

        // Config code
        let execPath = Bundle.main.executablePath ?? "/path/to/HomeMCPBridge.app/Contents/MacOS/HomeMCPBridge"
        let configCode = """
        {
          "mcpServers": {
            "homekit": {
              "command": "\(execPath)",
              "args": []
            }
          }
        }
        """

        let configTextView = UITextView()
        configTextView.text = configCode
        configTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        configTextView.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        configTextView.textColor = UIColor(red: 0.6, green: 0.9, blue: 0.6, alpha: 1.0)
        configTextView.isEditable = false
        configTextView.isScrollEnabled = false
        configTextView.layer.cornerRadius = 8
        configTextView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(configTextView)

        // Copy button
        let copyButton = UIButton(type: .system)
        copyButton.setTitle("Copy Configuration", for: .normal)
        copyButton.addTarget(self, action: #selector(copyConfig), for: .touchUpInside)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(copyButton)

        // Separator 3
        let separator3 = UIView()
        separator3.backgroundColor = .separator
        separator3.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator3)

        // Log section header
        let logHeader = UILabel()
        logHeader.text = "Activity Log"
        logHeader.font = .boldSystemFont(ofSize: 16)
        logHeader.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(logHeader)

        // Log text view
        textView = UITextView()
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        textView.textColor = .white
        textView.isEditable = false
        textView.layer.cornerRadius = 8
        textView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            headerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            headerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            subtitleLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            statusLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            separator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            separator.heightAnchor.constraint(equalToConstant: 1),

            settingsHeader.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            settingsHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            menuBarLabel.topAnchor.constraint(equalTo: settingsHeader.bottomAnchor, constant: 12),
            menuBarLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            menuBarSwitch.centerYAnchor.constraint(equalTo: menuBarLabel.centerYAnchor),
            menuBarSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            dockLabel.topAnchor.constraint(equalTo: menuBarLabel.bottomAnchor, constant: 12),
            dockLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            dockSwitch.centerYAnchor.constraint(equalTo: dockLabel.centerYAnchor),
            dockSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            settingsNote.topAnchor.constraint(equalTo: dockLabel.bottomAnchor, constant: 8),
            settingsNote.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            settingsNote.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            loginButton.topAnchor.constraint(equalTo: settingsNote.bottomAnchor, constant: 12),
            loginButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            separator2.topAnchor.constraint(equalTo: loginButton.bottomAnchor, constant: 16),
            separator2.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            separator2.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            separator2.heightAnchor.constraint(equalToConstant: 1),

            configHeader.topAnchor.constraint(equalTo: separator2.bottomAnchor, constant: 16),
            configHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            configDesc.topAnchor.constraint(equalTo: configHeader.bottomAnchor, constant: 4),
            configDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            configTextView.topAnchor.constraint(equalTo: configDesc.bottomAnchor, constant: 8),
            configTextView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            configTextView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            configTextView.heightAnchor.constraint(equalToConstant: 100),

            copyButton.topAnchor.constraint(equalTo: configTextView.bottomAnchor, constant: 8),
            copyButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            separator3.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 16),
            separator3.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            separator3.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            separator3.heightAnchor.constraint(equalToConstant: 1),

            logHeader.topAnchor.constraint(equalTo: separator3.bottomAnchor, constant: 16),
            logHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            textView.topAnchor.constraint(equalTo: logHeader.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            textView.heightAnchor.constraint(equalToConstant: 200),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    @objc private func menuBarSwitchChanged() {
        // Ensure at least one is enabled
        if !menuBarSwitch.isOn && !dockSwitch.isOn {
            menuBarSwitch.isOn = true
            return
        }
        SettingsManager.shared.showMenuBarIcon = menuBarSwitch.isOn
        #if targetEnvironment(macCatalyst)
        MenuBarManager.shared.updateVisibility()
        #endif
    }

    @objc private func dockSwitchChanged() {
        // Ensure at least one is enabled
        if !dockSwitch.isOn && !menuBarSwitch.isOn {
            dockSwitch.isOn = true
            return
        }
        SettingsManager.shared.showDockIcon = dockSwitch.isOn
        #if targetEnvironment(macCatalyst)
        MenuBarManager.shared.updateDockVisibility()
        #endif
    }

    @objc private func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            UIApplication.shared.open(url)
        }
    }

    @objc private func copyConfig() {
        let execPath = Bundle.main.executablePath ?? "/path/to/HomeMCPBridge.app/Contents/MacOS/HomeMCPBridge"
        let config = """
        {
          "mcpServers": {
            "homekit": {
              "command": "\(execPath)",
              "args": []
            }
          }
        }
        """
        UIPasteboard.general.string = config
        log("MCP configuration copied to clipboard")
    }

    @objc private func updateLog() {
        let entries = ActivityLog.shared.getEntries()
        textView.text = entries.joined(separator: "\n")

        // Auto-scroll to bottom
        if !entries.isEmpty {
            let range = NSRange(location: textView.text.count - 1, length: 1)
            textView.scrollRangeToVisible(range)
        }
    }

    @objc private func updateStatus() {
        let homeKit = HomeKitManager.shared
        statusLabel.text = "\(homeKit.deviceCount) device(s) in \(homeKit.homeCount) home(s)"
    }
}

// MARK: - Main Tab Controller

class MainTabController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let statusVC = StatusViewController()
        statusVC.tabBarItem = UITabBarItem(title: "Status", image: UIImage(systemName: "house"), tag: 0)

        let pluginsVC = PluginsViewController()
        pluginsVC.tabBarItem = UITabBarItem(title: "Plugins", image: UIImage(systemName: "puzzlepiece"), tag: 1)

        let devicesVC = DevicesViewController()
        devicesVC.tabBarItem = UITabBarItem(title: "Devices", image: UIImage(systemName: "lightbulb"), tag: 2)

        viewControllers = [
            UINavigationController(rootViewController: statusVC),
            UINavigationController(rootViewController: pluginsVC),
            UINavigationController(rootViewController: devicesVC)
        ]
    }
}

// MARK: - Plugins View Controller

class PluginsViewController: UITableViewController {
    private var plugins: [any DevicePlugin] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Plugins"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "PluginCell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadPlugins()
    }

    private func loadPlugins() {
        plugins = PluginManager.shared.allPlugins()
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        plugins.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "PluginCell", for: indexPath)
        let plugin = plugins[indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = plugin.displayName
        if plugin.identifier == "homekit" {
            config.secondaryText = "Built-in (Always enabled)"
            config.secondaryTextProperties.color = .systemBlue
        } else if plugin.isConfigured {
            config.secondaryText = plugin.isEnabled ? "Enabled" : "Disabled"
            config.secondaryTextProperties.color = plugin.isEnabled ? .systemGreen : .secondaryLabel
        } else {
            config.secondaryText = "Not configured"
            config.secondaryTextProperties.color = .systemOrange
        }
        cell.contentConfiguration = config

        // Add toggle switch for non-HomeKit plugins
        if plugin.identifier != "homekit" {
            let toggle = UISwitch()
            toggle.isOn = plugin.isEnabled
            toggle.tag = indexPath.row
            toggle.addTarget(self, action: #selector(togglePlugin(_:)), for: .valueChanged)
            toggle.isEnabled = plugin.isConfigured
            cell.accessoryView = toggle
        } else {
            cell.accessoryView = nil
            cell.accessoryType = .none
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let plugin = plugins[indexPath.row]

        guard !plugin.configurationFields.isEmpty else {
            // Show info for HomeKit
            if plugin.identifier == "homekit" {
                let alert = UIAlertController(
                    title: "Apple HomeKit",
                    message: "HomeKit is configured through the Apple Home app. Make sure your devices are set up in Home before using HomeMCPBridge.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            return
        }

        let configVC = PluginConfigViewController(plugin: plugin)
        navigationController?.pushViewController(configVC, animated: true)
    }

    @objc private func togglePlugin(_ sender: UISwitch) {
        let plugin = plugins[sender.tag]
        PluginManager.shared.setEnabled(sender.isOn, for: plugin.identifier)
        tableView.reloadRows(at: [IndexPath(row: sender.tag, section: 0)], with: .automatic)
    }
}

// MARK: - Plugin Config View Controller

class PluginConfigViewController: UITableViewController {
    private let plugin: any DevicePlugin
    private var values: [String: String] = [:]
    private var textFields: [String: UITextField] = [:]

    init(plugin: any DevicePlugin) {
        self.plugin = plugin
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = plugin.displayName

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Save", style: .done, target: self, action: #selector(save))

        // Load existing values from Keychain
        for field in plugin.configurationFields {
            if let storedValue = CredentialManager.shared.retrieve(key: field.key, plugin: plugin.identifier) {
                values[field.key] = storedValue
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? plugin.configurationFields.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Configuration" : "Actions"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        // Combine help texts
        let helpTexts = plugin.configurationFields.compactMap { $0.helpText }.joined(separator: "\n")
        return helpTexts.isEmpty ? nil : helpTexts
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            let field = plugin.configurationFields[indexPath.row]

            let label = UILabel()
            label.text = field.label
            label.font = .systemFont(ofSize: 14)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(label)

            let textField = UITextField()
            textField.placeholder = field.placeholder
            textField.text = values[field.key] ?? ""
            textField.isSecureTextEntry = field.isSecure
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.textAlignment = .right
            textField.font = .systemFont(ofSize: 14)
            textField.translatesAutoresizingMaskIntoConstraints = false
            textFields[field.key] = textField
            cell.contentView.addSubview(textField)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                label.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                label.widthAnchor.constraint(equalToConstant: 100),

                textField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                textField.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                textField.heightAnchor.constraint(equalToConstant: 44)
            ])

            cell.selectionStyle = .none
            return cell
        } else {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var config = cell.defaultContentConfiguration()
            config.text = "Clear Credentials"
            config.textProperties.color = .systemRed
            config.textProperties.alignment = .center
            cell.contentConfiguration = config
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            let alert = UIAlertController(
                title: "Clear Credentials?",
                message: "This will remove all stored credentials for \(plugin.displayName).",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
                self?.clearCredentials()
            })
            present(alert, animated: true)
        }
    }

    private func clearCredentials() {
        plugin.clearCredentials()
        values = [:]
        textFields.values.forEach { $0.text = "" }
        tableView.reloadData()
        log("Cleared credentials for \(plugin.displayName)")

        let alert = UIAlertController(title: "Cleared", message: "Credentials have been removed.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func save() {
        // Collect values from text fields
        for (key, textField) in textFields {
            values[key] = textField.text ?? ""
        }

        // Show loading indicator
        let loadingAlert = UIAlertController(title: nil, message: "Configuring...", preferredStyle: .alert)
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        loadingAlert.view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: loadingAlert.view.centerXAnchor),
            indicator.bottomAnchor.constraint(equalTo: loadingAlert.view.bottomAnchor, constant: -20)
        ])
        present(loadingAlert, animated: true)

        Task {
            do {
                try await plugin.configure(with: values)
                await MainActor.run {
                    loadingAlert.dismiss(animated: true) {
                        log("Configured \(self.plugin.displayName)")
                        self.navigationController?.popViewController(animated: true)
                    }
                }
            } catch {
                await MainActor.run {
                    loadingAlert.dismiss(animated: true) {
                        let errorAlert = UIAlertController(
                            title: "Configuration Error",
                            message: error.localizedDescription,
                            preferredStyle: .alert
                        )
                        errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                        self.present(errorAlert, animated: true)
                    }
                }
            }
        }
    }
}

// MARK: - Devices View Controller

class DevicesViewController: UITableViewController {
    private var devicesBySource: [DeviceSource: [UnifiedDevice]] = [:]
    private var sources: [DeviceSource] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Devices"

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DeviceCell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadDevices()
    }

    @objc private func refresh() {
        loadDevices()
    }

    private func loadDevices() {
        Task {
            let devices = await PluginManager.shared.listAllDevices()
            devicesBySource = Dictionary(grouping: devices, by: { $0.source })

            // Order: HomeKit first, then alphabetically
            sources = DeviceSource.allCases.filter { devicesBySource[$0] != nil }

            await MainActor.run {
                tableView.reloadData()
                refreshControl?.endRefreshing()
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sources.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let source = sources[section]
        let count = devicesBySource[source]?.count ?? 0
        return "\(source.rawValue) (\(count))"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        devicesBySource[sources[section]]?.count ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceCell", for: indexPath)
        let device = devicesBySource[sources[indexPath.section]]![indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = device.name
        config.secondaryText = [device.type, device.room].compactMap { $0 }.joined(separator: " - ")
        config.textProperties.color = device.isReachable ? .label : .tertiaryLabel
        config.secondaryTextProperties.color = device.isReachable ? .secondaryLabel : .tertiaryLabel

        let icon: String
        switch device.type {
        case "light": icon = "lightbulb.fill"
        case "switch": icon = "switch.2"
        case "outlet": icon = "poweroutlet.type.b.fill"
        case "fan": icon = "fan.fill"
        case "lock": icon = "lock.fill"
        case "garage_door": icon = "door.garage.closed"
        case "sensor": icon = "sensor.fill"
        case "thermostat": icon = "thermometer"
        case "hub": icon = "server.rack"
        case "curtain": icon = "blinds.vertical.closed"
        default: icon = "questionmark.circle"
        }
        config.image = UIImage(systemName: icon)
        config.imageProperties.tintColor = device.isReachable ? .systemBlue : .tertiaryLabel

        cell.contentConfiguration = config
        cell.selectionStyle = .none
        return cell
    }
}

// MARK: - AppKit Bridge (Mac Catalyst)

#if targetEnvironment(macCatalyst)
class AppKitBridge: NSObject {
    static let shared = AppKitBridge()
    private var observer: AnyObject?

    func setup() {
        // Use method swizzling to intercept applicationShouldTerminateAfterLastWindowClosed
        swizzleTerminationMethod()

        // Also observe window close to prevent termination
        observeWindowClose()
    }

    private func swizzleTerminationMethod() {
        // Get the NSApplication's delegate class
        guard let nsApp = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = nsApp.value(forKey: "sharedApplication") as? NSObject,
              let delegate = app.value(forKey: "delegate") else { return }

        let delegateClass: AnyClass = type(of: delegate as AnyObject)

        // Add our implementation of applicationShouldTerminateAfterLastWindowClosed
        let selector = NSSelectorFromString("applicationShouldTerminateAfterLastWindowClosed:")

        // Check if method already exists
        if class_getInstanceMethod(delegateClass, selector) == nil {
            // Add the method
            let imp = imp_implementationWithBlock({ (_: AnyObject, _: AnyObject) -> Bool in
                return false
            } as @convention(block) (AnyObject, AnyObject) -> Bool)

            let types = "c@:@" // returns BOOL, takes id self, SEL _cmd, id sender
            class_addMethod(delegateClass, selector, imp, types)
        } else {
            // Replace existing method
            let imp = imp_implementationWithBlock({ (_: AnyObject, _: AnyObject) -> Bool in
                return false
            } as @convention(block) (AnyObject, AnyObject) -> Bool)

            if let method = class_getInstanceMethod(delegateClass, selector) {
                method_setImplementation(method, imp)
            }
        }
    }

    private func observeWindowClose() {
        // Listen for NSWindow close notifications
        let notificationName = NSNotification.Name("NSWindowWillCloseNotification")
        observer = NotificationCenter.default.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { notification in
            // Prevent default close behavior by keeping app alive
            log("Window closing, app will continue running")
        }
    }

    func setDockIconVisible(_ visible: Bool) {
        guard let nsApp = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = nsApp.value(forKey: "sharedApplication") as? NSObject else { return }

        let policy = visible ? 0 : 1 // 0 = regular, 1 = accessory

        let selector = NSSelectorFromString("setActivationPolicy:")
        guard let method = class_getInstanceMethod(type(of: app), selector) else { return }

        typealias SetPolicyFunc = @convention(c) (AnyObject, Selector, Int) -> Void
        let imp = method_getImplementation(method)
        let setPolicy = unsafeBitCast(imp, to: SetPolicyFunc.self)
        setPolicy(app, selector, policy)
    }
}
#endif

// MARK: - Menu Bar Manager (Mac Catalyst)

#if targetEnvironment(macCatalyst)

class MenuBarManager: NSObject {
    static let shared = MenuBarManager()

    private var statusItem: AnyObject?
    private weak var windowScene: UIWindowScene?
    private var isWindowOpen = true
    private var menu: NSObject?

    func setup(windowScene: UIWindowScene) {
        self.windowScene = windowScene
        self.isWindowOpen = true

        // Prevent app from quitting when last window is closed
        preventTerminationOnWindowClose()

        if SettingsManager.shared.showMenuBarIcon {
            createStatusItem()
        }

        updateDockVisibility()
    }

    private func preventTerminationOnWindowClose() {
        // Set up AppKit bridge to prevent termination when window closes
        AppKitBridge.shared.setup()

        // Register for window close notification
        NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.windowScene = nil
            self?.isWindowOpen = false
        }
    }

    func updateVisibility() {
        if SettingsManager.shared.showMenuBarIcon {
            if statusItem == nil {
                createStatusItem()
            }
        } else {
            removeStatusItem()
        }
    }

    func updateDockVisibility() {
        AppKitBridge.shared.setDockIconVisible(SettingsManager.shared.showDockIcon)
    }

    func windowClosed() {
        isWindowOpen = false
    }

    func windowOpened() {
        isWindowOpen = true
    }

    private func createStatusItem() {
        guard let statusBarClass = NSClassFromString("NSStatusBar"),
              let statusBar = statusBarClass.value(forKey: "systemStatusBar") as? NSObject else { return }

        let length = CGFloat(-1) // NSVariableStatusItemLength
        guard let item = statusBar.perform(Selector(("statusItemWithLength:")), with: length)?.takeUnretainedValue() else { return }

        statusItem = item

        // Set button image (SF Symbol house)
        if let button = item.value(forKey: "button") as? NSObject {
            // Create NSImage from SF Symbol
            if let imageClass = NSClassFromString("NSImage") as? NSObject.Type {
                let symbolSelector = NSSelectorFromString("imageWithSystemSymbolName:accessibilityDescription:")
                if let image = (imageClass as AnyObject).perform(symbolSelector, with: "house.fill", with: "Home")?.takeUnretainedValue() as? NSObject {
                    // Set as template so it adapts to menu bar appearance
                    image.setValue(true, forKey: "template")
                    button.setValue(image, forKey: "image")
                }
            }
        }

        // Create menu using initWithTitle:action:keyEquivalent: which properly sets action
        guard let menuClass = NSClassFromString("NSMenu") as? NSObject.Type,
              let menuItemClass = NSClassFromString("NSMenuItem") else { return }

        let newMenu = menuClass.init()
        menu = newMenu
        newMenu.setValue(false, forKey: "autoenablesItems")
        newMenu.setValue(self, forKey: "delegate")

        // Create menu items using the proper initializer
        // Header item (disabled)
        if let headerItem = createMenuItem(title: "HomeMCPBridge", action: nil, keyEquivalent: "") {
            headerItem.setValue(false, forKey: "enabled")
            newMenu.perform(Selector(("addItem:")), with: headerItem)
        }

        // Separator
        if let sep = (menuItemClass as AnyObject).perform(NSSelectorFromString("separatorItem"))?.takeUnretainedValue() {
            newMenu.perform(Selector(("addItem:")), with: sep)
        }

        // Open item - tag 1
        if let openItem = createMenuItem(title: "Open", action: nil, keyEquivalent: "") {
            openItem.setValue(1, forKey: "tag")
            newMenu.perform(Selector(("addItem:")), with: openItem)
        }

        // Copy Config item - tag 2
        if let copyItem = createMenuItem(title: "Copy MCP Config", action: nil, keyEquivalent: "") {
            copyItem.setValue(2, forKey: "tag")
            newMenu.perform(Selector(("addItem:")), with: copyItem)
        }

        // Separator
        if let sep = (menuItemClass as AnyObject).perform(NSSelectorFromString("separatorItem"))?.takeUnretainedValue() {
            newMenu.perform(Selector(("addItem:")), with: sep)
        }

        // Quit item - tag 3
        if let quitItem = createMenuItem(title: "Quit", action: nil, keyEquivalent: "q") {
            quitItem.setValue(3, forKey: "tag")
            newMenu.perform(Selector(("addItem:")), with: quitItem)
        }

        item.setValue(newMenu, forKey: "menu")

        // Set up the menu actions with our runtime-created target
        setupMenuActions()
    }

    private func createMenuItem(title: String, action: Selector?, keyEquivalent: String) -> NSObject? {
        guard let itemClass = NSClassFromString("NSMenuItem") else { return nil }

        // Use alloc + initWithTitle:action:keyEquivalent:
        guard let allocated = (itemClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject else { return nil }

        let initSelector = NSSelectorFromString("initWithTitle:action:keyEquivalent:")

        // We need to use NSInvocation or a different approach since perform() doesn't handle multiple args well
        // Instead, use init and then set properties
        _ = allocated.perform(NSSelectorFromString("init"))
        allocated.setValue(title, forKey: "title")
        allocated.setValue(keyEquivalent, forKey: "keyEquivalent")
        allocated.setValue(true, forKey: "enabled")

        return allocated
    }

    private func removeStatusItem() {
        guard let item = statusItem,
              let statusBarClass = NSClassFromString("NSStatusBar"),
              let statusBar = statusBarClass.value(forKey: "systemStatusBar") as? NSObject else { return }

        statusBar.perform(Selector(("removeStatusItem:")), with: item)
        statusItem = nil
        menu = nil
    }

    // NSMenuDelegate method - called when user clicks a menu item
    // We handle actions here instead of via target/action
    @objc func menuWillOpen(_ menu: NSObject) {
        log("Menu will open")
    }

    // This is called via delegate when menu needs to highlight
    @objc func menu(_ menu: NSObject, willHighlightItem item: NSObject?) {
        // Optional: handle highlighting
    }

    // Handle menu item selection via notification or by implementing menuDidClose
    @objc func menuDidClose(_ menu: NSObject) {
        // Check which item was selected by looking at highlightedItem
        // This doesn't work well, so we'll use a different approach
    }

    // Public methods
    func doShowWindow() {
        log("Opening window...")

        // First check if we have an active window scene
        if let scene = windowScene {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil, errorHandler: nil)
            return
        }

        // Look for an existing session we can reactivate
        for session in UIApplication.shared.openSessions {
            if session.configuration.name == "Default" {
                UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil) { error in
                    log("Failed to reactivate session: \(error.localizedDescription)")
                }
                return
            }
        }

        // Create a new scene session
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil) { error in
            log("Failed to open window: \(error.localizedDescription)")
        }
    }

    func doCopyConfig() {
        let execPath = Bundle.main.executablePath ?? "/Applications/HomeMCPBridge.app/Contents/MacOS/HomeMCPBridge"
        let config = """
        {
          "mcpServers": {
            "homekit": {
              "command": "\(execPath)",
              "args": []
            }
          }
        }
        """
        UIPasteboard.general.string = config
        log("MCP configuration copied to clipboard")
    }

    func doQuit() {
        log("Quitting...")
        exit(0)
    }
}

// We need to add the action methods dynamically to a class that AppKit can call
// Create an AppKit-compatible target for menu actions
private var menuActionHandlerClass: AnyClass? = {
    let className = "MenuActionTarget"

    // Check if class already exists
    if let existingClass = NSClassFromString(className) {
        return existingClass
    }

    // Create a new Objective-C class at runtime
    guard let superclass = NSClassFromString("NSObject"),
          let newClass = objc_allocateClassPair(superclass, className, 0) else {
        return nil
    }

    // Add action methods
    let openBlock: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in
        MenuBarManager.shared.doShowWindow()
    }
    let openImp = imp_implementationWithBlock(openBlock)
    class_addMethod(newClass, NSSelectorFromString("openWindow:"), openImp, "v@:@")

    let copyBlock: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in
        MenuBarManager.shared.doCopyConfig()
    }
    let copyImp = imp_implementationWithBlock(copyBlock)
    class_addMethod(newClass, NSSelectorFromString("copyConfig:"), copyImp, "v@:@")

    let quitBlock: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in
        MenuBarManager.shared.doQuit()
    }
    let quitImp = imp_implementationWithBlock(quitBlock)
    class_addMethod(newClass, NSSelectorFromString("quitApp:"), quitImp, "v@:@")

    objc_registerClassPair(newClass)
    return newClass
}()

private var menuActionTarget: AnyObject? = {
    guard let handlerClass = menuActionHandlerClass as? NSObject.Type else { return nil }
    return handlerClass.init()
}()

// Extension to set up menu items with the runtime-created target
extension MenuBarManager {
    func setupMenuActions() {
        guard let menu = self.menu,
              let target = menuActionTarget else { return }

        // Get menu items array using itemArray property
        guard let items = menu.value(forKey: "itemArray") as? [NSObject] else { return }

        for item in items {
            let tag = (item.value(forKey: "tag") as? Int) ?? 0

            switch tag {
            case 1: // Open
                item.setValue(target, forKey: "target")
                setAction(on: item, selector: NSSelectorFromString("openWindow:"))
            case 2: // Copy Config
                item.setValue(target, forKey: "target")
                setAction(on: item, selector: NSSelectorFromString("copyConfig:"))
            case 3: // Quit
                item.setValue(target, forKey: "target")
                setAction(on: item, selector: NSSelectorFromString("quitApp:"))
            default:
                break
            }
        }
    }

    private func setAction(on item: NSObject, selector: Selector) {
        // Use objc_msgSend to set the action properly
        typealias SetActionFunc = @convention(c) (AnyObject, Selector, Selector) -> Void

        let setActionSel = NSSelectorFromString("setAction:")
        guard let method = class_getInstanceMethod(type(of: item), setActionSel) else { return }

        let imp = method_getImplementation(method)
        let setAction = unsafeBitCast(imp, to: SetActionFunc.self)
        setAction(item, setActionSel, selector)
    }
}
#endif

// MARK: - Scene Delegate (for Mac Catalyst)

#if targetEnvironment(macCatalyst)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Configure window with tab-based navigation
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = MainTabController()
        window?.makeKeyAndVisible()

        // Set window size constraints (slightly larger for tabs)
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 550, height: 750)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 900, height: 1100)

        // Set window title
        windowScene.title = "HomeMCPBridge"

        // Set up menu bar
        MenuBarManager.shared.setup(windowScene: windowScene)

        // Build menu bar
        UIMenuSystem.main.setNeedsRebuild()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Window was closed - update menu bar to show "Open" instead of "Show Window"
        MenuBarManager.shared.windowClosed()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        MenuBarManager.shared.windowOpened()
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard builder.system == .main else { return }

        // Add useful menu items to Edit menu
        let copyConfigAction = UIAction(title: "Copy MCP Configuration", image: UIImage(systemName: "doc.on.doc"), identifier: nil) { _ in
            MenuBarManager.shared.doCopyConfig()
        }

        let openLoginItemsAction = UIAction(title: "Add to Login Items...", image: UIImage(systemName: "gear"), identifier: nil) { _ in
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                UIApplication.shared.open(url)
            }
        }

        let configMenu = UIMenu(title: "", options: .displayInline, children: [copyConfigAction, openLoginItemsAction])
        builder.insertChild(configMenu, atStartOfMenu: .edit)
    }
}
#endif

// MARK: - App Delegate

class AppDelegate: UIResponder, UIApplicationDelegate {
    let homeKit = HomeKitManager.shared
    let server = MCPServer()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        log("HomeMCPBridge v2.0.0 starting...")

        // Register plugins
        log("Registering plugins...")
        let pluginManager = PluginManager.shared
        pluginManager.register(HomeKitPlugin())
        pluginManager.register(GoveePlugin())
        pluginManager.register(AqaraPlugin())

        // Initialize all enabled and configured plugins
        Task {
            for plugin in pluginManager.allPlugins() {
                if plugin.isEnabled && plugin.isConfigured {
                    do {
                        try await plugin.initialize()
                    } catch {
                        log("Failed to initialize \(plugin.displayName): \(error)")
                    }
                }
            }

            // Start MCP server on background thread after plugins are initialized
            DispatchQueue.global(qos: .userInitiated).async {
                self.server.run()
            }
        }

        return true
    }

    #if targetEnvironment(macCatalyst)
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Window was closed - don't quit, just update state
        MenuBarManager.shared.windowClosed()
    }
    #endif

    // This is called by the NSApplicationDelegate bridge to prevent quitting when window closes
    @objc func applicationShouldTerminateAfterLastWindowClosed(_ sender: Any) -> Bool {
        return false
    }
}

// MARK: - Main

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
