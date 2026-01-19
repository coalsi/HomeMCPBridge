import Foundation
import HomeKit
import UIKit
import Network

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
    static let mcpPostEventReceived = Notification.Name("mcpPostEventReceived")
    static let mcpPostSettingsUpdated = Notification.Name("mcpPostSettingsUpdated")
}

// MARK: - Plugin System Models

enum DeviceSource: String, Codable, CaseIterable {
    case homeKit = "HomeKit"
    case govee = "Govee"
    case scrypted = "Scrypted"
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

// MARK: - Device Link Manager

class DeviceLinkManager {
    static let shared = DeviceLinkManager()

    private let defaults = UserDefaults.standard
    private let linksKey = "deviceLinks"

    struct DeviceLink: Codable {
        let primaryDeviceId: String
        let primarySource: String
        let linkedDeviceId: String
        let linkedSource: String
    }

    private var links: [DeviceLink] = []

    init() {
        loadLinks()
    }

    private func loadLinks() {
        guard let data = defaults.data(forKey: linksKey),
              let decoded = try? JSONDecoder().decode([DeviceLink].self, from: data) else {
            links = []
            return
        }
        links = decoded
    }

    private func saveLinks() {
        if let data = try? JSONEncoder().encode(links) {
            defaults.set(data, forKey: linksKey)
        }
    }

    func linkDevices(primary: UnifiedDevice, linked: UnifiedDevice) {
        // Remove any existing links for either device
        links.removeAll { link in
            link.primaryDeviceId == primary.id || link.linkedDeviceId == primary.id ||
            link.primaryDeviceId == linked.id || link.linkedDeviceId == linked.id
        }

        let link = DeviceLink(
            primaryDeviceId: primary.id,
            primarySource: primary.source.rawValue,
            linkedDeviceId: linked.id,
            linkedSource: linked.source.rawValue
        )
        links.append(link)
        saveLinks()
        log("Linked device '\(primary.name)' (\(primary.source.rawValue)) with '\(linked.name)' (\(linked.source.rawValue))")
    }

    func unlinkDevice(deviceId: String) {
        links.removeAll { $0.primaryDeviceId == deviceId || $0.linkedDeviceId == deviceId }
        saveLinks()
        log("Unlinked device: \(deviceId)")
    }

    func getLinkedDevice(for deviceId: String) -> DeviceLink? {
        return links.first { $0.primaryDeviceId == deviceId || $0.linkedDeviceId == deviceId }
    }

    func isLinked(deviceId: String) -> Bool {
        return links.contains { $0.primaryDeviceId == deviceId || $0.linkedDeviceId == deviceId }
    }

    func getAllLinks() -> [DeviceLink] {
        return links
    }

    /// Filter devices to remove linked duplicates, keeping the most capable version
    func filterLinkedDevices(_ devices: [UnifiedDevice]) -> [UnifiedDevice] {
        var result: [UnifiedDevice] = []
        var processedIds: Set<String> = []

        for device in devices {
            if processedIds.contains(device.id) { continue }

            if let link = getLinkedDevice(for: device.id) {
                // Find both devices
                let primaryId = link.primaryDeviceId
                let linkedId = link.linkedDeviceId

                // Mark both as processed
                processedIds.insert(primaryId)
                processedIds.insert(linkedId)

                // Find both devices in the list
                let primary = devices.first { $0.id == primaryId }
                let linked = devices.first { $0.id == linkedId }

                // Prefer plugin devices over HomeKit (plugins usually have more features)
                if let p = primary, let l = linked {
                    // Prefer non-HomeKit source as it usually has more capabilities
                    if p.source != .homeKit {
                        result.append(p)
                    } else {
                        result.append(l)
                    }
                } else {
                    // One device not found, add whichever exists
                    if let p = primary { result.append(p) }
                    else if let l = linked { result.append(l) }
                }
            } else {
                processedIds.insert(device.id)
                result.append(device)
            }
        }

        return result
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
        let active = activePlugins()
        log("PluginManager: Listing devices from \(active.count) active plugins")
        for plugin in active {
            log("PluginManager: Fetching from \(plugin.displayName) (enabled=\(plugin.isEnabled), configured=\(plugin.isConfigured))")
            do {
                let devices = try await plugin.listDevices()
                log("PluginManager: \(plugin.displayName) returned \(devices.count) devices")
                allDevices.append(contentsOf: devices)
            } catch {
                log("PluginManager: Error listing devices from \(plugin.displayName): \(error)")
            }
        }
        log("PluginManager: Total devices: \(allDevices.count)")
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

    private var _homeManager: HMHomeManager!

    // Expose homeManager for CameraManager and MotionSensorManager
    var homeManager: HMHomeManager { return _homeManager }
    private var isReady = false
    private var readyCallbacks: [() -> Void] = []

    var deviceCount: Int {
        _homeManager?.homes.reduce(0) { $0 + $1.accessories.count } ?? 0
    }

    var homeCount: Int {
        _homeManager?.homes.count ?? 0
    }

    override init() {
        super.init()
        _homeManager = HMHomeManager()
        _homeManager.delegate = self
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

// MARK: - Scrypted Plugin

class ScryptedPlugin: DevicePlugin {
    let identifier = "scrypted"
    let displayName = "Scrypted NVR"
    var isEnabled = false

    private var cachedDevices: [ScryptedDevice] = []
    private var cachedCameras: [ScryptedCamera] = []
    private var lastFetch: Date?
    private var authToken: String?
    private var tokenExpiry: Date?

    var host: String? {
        CredentialManager.shared.retrieve(key: "host", plugin: identifier)
    }

    var username: String? {
        CredentialManager.shared.retrieve(key: "username", plugin: identifier)
    }

    var password: String? {
        CredentialManager.shared.retrieve(key: "password", plugin: identifier)
    }

    var isConfigured: Bool {
        guard let h = host, !h.isEmpty,
              let u = username, !u.isEmpty,
              let p = password, !p.isEmpty else { return false }
        return true
    }

    var configurationFields: [PluginConfigField] {
        [
            PluginConfigField(
                key: "host",
                label: "Scrypted Host",
                placeholder: "https://mac-mini.local:10443",
                isSecure: false,
                helpText: "Scrypted server URL (e.g., https://192.168.1.100:10443)"
            ),
            PluginConfigField(
                key: "username",
                label: "Username",
                placeholder: "admin",
                isSecure: false,
                helpText: "Scrypted admin username"
            ),
            PluginConfigField(
                key: "password",
                label: "Password",
                placeholder: "Enter password",
                isSecure: true,
                helpText: "Scrypted admin password"
            )
        ]
    }

    func initialize() async throws {
        guard isConfigured else { throw PluginError.notConfigured }
        try await authenticate()

        // Scrypted uses MQTT for camera discovery - configure MQTT in Settings
        let mqttCameras = ScryptedMQTTManager.shared.getDiscoveredCameras()
        log("Scrypted plugin initialized with \(mqttCameras.count) MQTT-discovered cameras")
    }

    func shutdown() async {
        cachedDevices = []
        cachedCameras = []
        authToken = nil
    }

    func configure(with credentials: [String: String]) async throws {
        guard let h = credentials["host"], !h.isEmpty,
              let u = credentials["username"], !u.isEmpty,
              let p = credentials["password"], !p.isEmpty else {
            throw PluginError.notConfigured
        }
        CredentialManager.shared.store(key: "host", value: h, plugin: identifier)
        CredentialManager.shared.store(key: "username", value: u, plugin: identifier)
        CredentialManager.shared.store(key: "password", value: p, plugin: identifier)
        try await authenticate()
        // MQTT mode - cameras discovered automatically via MQTT. Configure in Settings.
    }

    func clearCredentials() {
        CredentialManager.shared.delete(key: "host", plugin: identifier)
        CredentialManager.shared.delete(key: "username", plugin: identifier)
        CredentialManager.shared.delete(key: "password", plugin: identifier)
        cachedDevices = []
        cachedCameras = []
        authToken = nil
    }

    func listDevices() async throws -> [UnifiedDevice] {
        // Return MQTT-discovered cameras as devices
        let mqttCameras = ScryptedMQTTManager.shared.getDiscoveredCameras()
        return mqttCameras.map { camera in
            UnifiedDevice(
                id: camera.id,    // Use Scrypted device ID
                name: camera.name,  // Friendly name
                room: nil,
                type: "camera",
                source: .scrypted,
                isReachable: true,
                manufacturer: "Scrypted",
                model: "Camera"
            )
        }
    }

    func getDeviceState(deviceId: String) async throws -> [String: Any] {
        guard let device = cachedDevices.first(where: { $0.id == deviceId }) else {
            throw PluginError.deviceNotFound(deviceId)
        }
        return try await fetchDeviceState(deviceId: device.id)
    }

    func controlDevice(deviceId: String, action: String, value: Any?) async throws -> ControlResult {
        // Scrypted control is limited - mainly for cameras we support snapshot
        throw PluginError.unsupportedAction("Scrypted devices are read-only through this plugin")
    }

    // MARK: - Scrypted-Specific Methods

    func listCameras() async throws -> [ScryptedCamera] {
        // Return MQTT-discovered cameras
        return ScryptedMQTTManager.shared.getDiscoveredCameras().map { camera in
            ScryptedCamera(
                id: camera.id,    // Scrypted device ID
                name: camera.name,  // Friendly name
                room: nil,
                hasMotionSensor: true,  // Assume all Scrypted cameras have motion
                hasAudioDetection: camera.hasObjectDetection,
                isOnline: true
            )
        }
    }

    func captureSnapshot(cameraId: String) async throws -> Data {
        // Scrypted snapshots now use MQTT-discovered cameras and Scrypted REST API
        guard let host = host else { throw PluginError.notConfigured }

        // Find camera by ID or name from MQTT-discovered cameras
        let mqttCameras = ScryptedMQTTManager.shared.getDiscoveredCameras()
        let camera = mqttCameras.first {
            $0.id == cameraId || $0.name.lowercased() == cameraId.lowercased()
        }

        guard let foundCamera = camera else {
            throw PluginError.networkError(NSError(domain: "Scrypted", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Camera '\(cameraId)' not found. Ensure MQTT is connected and the camera is discovered."
            ]))
        }

        // Use Scrypted REST API for snapshot - use device ID
        let snapshotUrl = "\(host)/endpoint/@scrypted/core/public/\(foundCamera.id)/takePicture"
        return try await fetchSnapshot(from: snapshotUrl)
    }

    private func fetchSnapshot(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw PluginError.networkError(NSError(domain: "Scrypted", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // Add basic auth if available
        if let u = username, let p = password {
            let credentials = "\(u):\(p)".data(using: .utf8)!.base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        let session = createInsecureSession()
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PluginError.networkError(NSError(domain: "Scrypted", code: statusCode))
        }

        // Verify we got image data (at least 100 bytes, likely JPEG)
        guard data.count > 100 else {
            throw PluginError.networkError(NSError(domain: "Scrypted", code: -1, userInfo: [NSLocalizedDescriptionKey: "Response too small to be an image"]))
        }

        return data
    }

    func getMotionState(cameraId: String) async throws -> [String: Any] {
        return try await fetchDeviceState(deviceId: cameraId)
    }

    // MARK: - Private Methods

    private func authenticate() async throws {
        guard let host = host, let username = username, let password = password else {
            throw PluginError.notConfigured
        }

        // Scrypted uses /login endpoint with form data
        guard let url = URL(string: "\(host)/login") else {
            throw PluginError.networkError(NSError(domain: "Scrypted", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid host URL"]))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "username=\(username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username)&password=\(password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password)"
        request.httpBody = body.data(using: .utf8)

        // Create session that accepts self-signed certs (common for local Scrypted)
        let session = createInsecureSession()
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PluginError.networkError(NSError(domain: "Scrypted", code: -1))
        }

        if http.statusCode == 200 || http.statusCode == 302 {
            // Try to extract token from response or cookies
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = json["token"] as? String {
                authToken = token
                tokenExpiry = Date().addingTimeInterval(3600) // Assume 1 hour
                log("Scrypted: Authenticated successfully (token)")
                return
            }

            // Check for cookie-based auth
            if let cookies = http.value(forHTTPHeaderField: "Set-Cookie"),
               cookies.contains("session") {
                // Cookie auth - we'll use cookie jar
                authToken = "cookie"
                tokenExpiry = Date().addingTimeInterval(3600)
                log("Scrypted: Authenticated successfully (cookie)")
                return
            }

            // Assume success if we got 200/302
            authToken = "basic"
            tokenExpiry = Date().addingTimeInterval(3600)
            log("Scrypted: Authenticated successfully")
        } else if http.statusCode == 401 {
            throw PluginError.authenticationFailed("Invalid username or password")
        } else {
            throw PluginError.authenticationFailed("Login failed with status \(http.statusCode)")
        }
    }

    private func ensureAuthenticated() async throws {
        if authToken == nil || (tokenExpiry != nil && Date() > tokenExpiry!) {
            try await authenticate()
        }
    }

    private func fetchDeviceState(deviceId: String) async throws -> [String: Any] {
        try await ensureAuthenticated()
        guard let host = host else { throw PluginError.notConfigured }

        guard let url = URL(string: "\(host)/endpoint/@scrypted/core/public/\(deviceId)/state") else {
            throw PluginError.networkError(NSError(domain: "Scrypted", code: -1))
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let u = username, let p = password {
            let credentials = "\(u):\(p)".data(using: .utf8)!.base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        let session = createInsecureSession()
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Return cached info if available
            if let device = cachedDevices.first(where: { $0.id == deviceId }) {
                return device.info
            }
            return ["id": deviceId, "source": "scrypted"]
        }

        return json
    }

    private func createInsecureSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: InsecureURLSessionDelegate(), delegateQueue: nil)
    }
}

// Scrypted Models
struct ScryptedDevice {
    let id: String
    let name: String
    let room: String?
    let interfaces: [String]
    let info: [String: Any]

    func toUnified() -> UnifiedDevice {
        let type: String
        if interfaces.contains("Camera") || interfaces.contains("VideoCamera") {
            type = "camera"
        } else if interfaces.contains("Light") || interfaces.contains("OnOff") && name.lowercased().contains("light") {
            type = "light"
        } else if interfaces.contains("Lock") {
            type = "lock"
        } else if interfaces.contains("MotionSensor") {
            type = "motion_sensor"
        } else if interfaces.contains("Thermometer") || interfaces.contains("TemperatureSetting") {
            type = "thermostat"
        } else if interfaces.contains("Doorbell") {
            type = "doorbell"
        } else if interfaces.contains("OnOff") {
            type = "switch"
        } else {
            type = "unknown"
        }

        return UnifiedDevice(
            id: id,
            name: name,
            room: room,
            type: type,
            source: .scrypted,
            isReachable: true,
            manufacturer: "Scrypted",
            model: interfaces.first ?? "Device"
        )
    }
}

struct ScryptedCamera {
    let id: String
    let name: String
    let room: String?
    let hasMotionSensor: Bool
    let hasAudioDetection: Bool
    let isOnline: Bool
}

// URL Session delegate to allow self-signed certificates (common for local Scrypted)
class InsecureURLSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Lightweight MQTT Client (using Network framework)

/// Minimal MQTT 3.1.1 client for Scrypted integration
/// No external dependencies - uses Apple's Network framework
class MQTTClient {
    enum MQTTError: Error, LocalizedError {
        case connectionFailed(String)
        case notConnected
        case timeout
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let msg): return "MQTT connection failed: \(msg)"
            case .notConnected: return "MQTT not connected"
            case .timeout: return "MQTT connection timeout"
            case .protocolError(let msg): return "MQTT protocol error: \(msg)"
            }
        }
    }

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }

    // MQTT Packet Types
    private enum PacketType: UInt8 {
        case connect = 0x10
        case connack = 0x20
        case publish = 0x30
        case puback = 0x40
        case subscribe = 0x82
        case suback = 0x90
        case pingreq = 0xC0
        case pingresp = 0xD0
        case disconnect = 0xE0
    }

    private var connection: NWConnection?
    private var state: ConnectionState = .disconnected
    private let lock = NSLock()
    private var messageHandler: ((String, Data) -> Void)?
    private var stateHandler: ((ConnectionState) -> Void)?
    private var nextPacketId: UInt16 = 1
    private var pingTimer: Timer?
    private let queue = DispatchQueue(label: "mqtt.client", qos: .userInitiated)

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .connected
    }

    func connect(host: String, port: UInt16 = 1883, username: String? = nil, password: String? = nil,
                 clientId: String = "HomeMCPBridge-\(UUID().uuidString.prefix(8))",
                 onMessage: @escaping (String, Data) -> Void,
                 onStateChange: ((ConnectionState) -> Void)? = nil) {

        lock.lock()
        if state != .disconnected {
            lock.unlock()
            return
        }
        state = .connecting
        lock.unlock()

        messageHandler = onMessage
        stateHandler = onStateChange
        stateHandler?(.connecting)

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!

        connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)

        connection?.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                log("MQTT: TCP connected to \(host):\(port)")
                self.sendConnect(clientId: clientId, username: username, password: password)
                self.receiveLoop()
            case .failed(let error):
                log("MQTT: Connection failed - \(error.localizedDescription)")
                self.handleDisconnect()
            case .cancelled:
                log("MQTT: Connection cancelled")
                self.handleDisconnect()
            default:
                break
            }
        }

        connection?.start(queue: queue)

        // Timeout after 10 seconds
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if self.state == .connecting {
                self.lock.unlock()
                log("MQTT: Connection timeout")
                self.disconnect()
            } else {
                self.lock.unlock()
            }
        }
    }

    func disconnect() {
        lock.lock()
        guard state != .disconnected else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Send DISCONNECT packet
        let packet = Data([PacketType.disconnect.rawValue, 0x00])
        connection?.send(content: packet, completion: .contentProcessed { _ in })

        handleDisconnect()
    }

    func subscribe(to topics: [String]) {
        guard isConnected else { return }

        var packet = Data()

        // Fixed header - SUBSCRIBE (0x82)
        packet.append(PacketType.subscribe.rawValue)

        // Variable header + payload placeholder
        var variableHeader = Data()
        let packetId = getNextPacketId()
        variableHeader.append(UInt8(packetId >> 8))
        variableHeader.append(UInt8(packetId & 0xFF))

        // Payload - topics with QoS 0
        var payload = Data()
        for topic in topics {
            let topicData = topic.data(using: .utf8) ?? Data()
            payload.append(UInt8(topicData.count >> 8))
            payload.append(UInt8(topicData.count & 0xFF))
            payload.append(topicData)
            payload.append(0x00) // QoS 0
        }

        variableHeader.append(payload)

        // Remaining length
        packet.append(contentsOf: encodeRemainingLength(variableHeader.count))
        packet.append(variableHeader)

        connection?.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                log("MQTT: Subscribe send error - \(error.localizedDescription)")
            } else {
                log("MQTT: Subscribed to \(topics.count) topic(s)")
            }
        })
    }

    // MARK: - Private Methods

    private func sendConnect(clientId: String, username: String?, password: String?) {
        var packet = Data()

        // Fixed header
        packet.append(PacketType.connect.rawValue)

        // Variable header
        var variableHeader = Data()

        // Protocol name "MQTT"
        variableHeader.append(contentsOf: [0x00, 0x04])
        variableHeader.append("MQTT".data(using: .utf8)!)

        // Protocol level (4 = MQTT 3.1.1)
        variableHeader.append(0x04)

        // Connect flags
        var flags: UInt8 = 0x02 // Clean session
        if username != nil { flags |= 0x80 }
        if password != nil { flags |= 0x40 }
        variableHeader.append(flags)

        // Keep alive (60 seconds)
        variableHeader.append(contentsOf: [0x00, 0x3C])

        // Payload
        var payload = Data()

        // Client ID
        let clientIdData = clientId.data(using: .utf8) ?? Data()
        payload.append(UInt8(clientIdData.count >> 8))
        payload.append(UInt8(clientIdData.count & 0xFF))
        payload.append(clientIdData)

        // Username
        if let username = username {
            let userData = username.data(using: .utf8) ?? Data()
            payload.append(UInt8(userData.count >> 8))
            payload.append(UInt8(userData.count & 0xFF))
            payload.append(userData)
        }

        // Password
        if let password = password {
            let passData = password.data(using: .utf8) ?? Data()
            payload.append(UInt8(passData.count >> 8))
            payload.append(UInt8(passData.count & 0xFF))
            payload.append(passData)
        }

        variableHeader.append(payload)

        // Remaining length
        packet.append(contentsOf: encodeRemainingLength(variableHeader.count))
        packet.append(variableHeader)

        connection?.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                log("MQTT: Connect send error - \(error.localizedDescription)")
            }
        })
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                log("MQTT: Receive error - \(error.localizedDescription)")
                self.handleDisconnect()
                return
            }

            if let data = content, !data.isEmpty {
                self.processPacket(data)
            }

            if isComplete {
                self.handleDisconnect()
            } else if self.isConnected || self.state == .connecting {
                self.receiveLoop()
            }
        }
    }

    private func processPacket(_ data: Data) {
        guard data.count >= 2 else { return }

        let packetType = data[0] & 0xF0

        switch packetType {
        case PacketType.connack.rawValue:
            handleConnack(data)
        case PacketType.publish.rawValue:
            handlePublish(data)
        case PacketType.suback.rawValue:
            log("MQTT: SUBACK received")
        case PacketType.pingresp.rawValue:
            // Ping response received
            break
        default:
            break
        }
    }

    private func handleConnack(_ data: Data) {
        guard data.count >= 4 else { return }

        let returnCode = data[3]
        if returnCode == 0 {
            lock.lock()
            state = .connected
            lock.unlock()

            log("MQTT: Connected successfully")
            stateHandler?(.connected)

            // Start ping timer
            DispatchQueue.main.async { [weak self] in
                self?.pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    self?.sendPing()
                }
            }
        } else {
            let errorMsg: String
            switch returnCode {
            case 1: errorMsg = "Unacceptable protocol version"
            case 2: errorMsg = "Identifier rejected"
            case 3: errorMsg = "Server unavailable"
            case 4: errorMsg = "Bad username or password"
            case 5: errorMsg = "Not authorized"
            default: errorMsg = "Unknown error (\(returnCode))"
            }
            log("MQTT: Connection refused - \(errorMsg)")
            handleDisconnect()
        }
    }

    private func handlePublish(_ data: Data) {
        guard data.count >= 4 else { return }

        // Decode remaining length
        var index = 1
        var remainingLength = 0
        var multiplier = 1
        while index < data.count {
            let byte = Int(data[index])
            remainingLength += (byte & 127) * multiplier
            multiplier *= 128
            index += 1
            if byte & 128 == 0 { break }
        }

        guard index + 2 <= data.count else { return }

        // Topic length
        let topicLength = Int(data[index]) << 8 | Int(data[index + 1])
        index += 2

        guard index + topicLength <= data.count else { return }

        // Topic
        let topicData = data[index..<(index + topicLength)]
        guard let topic = String(data: topicData, encoding: .utf8) else { return }
        index += topicLength

        // QoS check (bits 1-2 of first byte)
        let qos = (data[0] & 0x06) >> 1
        if qos > 0 && index + 2 <= data.count {
            // Skip packet ID for QoS > 0
            index += 2
        }

        // Payload
        let payload = data[index...]

        messageHandler?(topic, Data(payload))
    }

    private func sendPing() {
        guard isConnected else { return }
        let packet = Data([PacketType.pingreq.rawValue, 0x00])
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func handleDisconnect() {
        pingTimer?.invalidate()
        pingTimer = nil

        connection?.cancel()
        connection = nil

        lock.lock()
        state = .disconnected
        lock.unlock()

        stateHandler?(.disconnected)
    }

    private func getNextPacketId() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextPacketId
        nextPacketId = nextPacketId == UInt16.max ? 1 : nextPacketId + 1
        return id
    }

    private func encodeRemainingLength(_ length: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = length
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 128 }
            bytes.append(byte)
        } while x > 0
        return bytes
    }
}

// MARK: - Scrypted MQTT Manager

/// Manages MQTT connection to Scrypted for real-time events and auto-discovery
class ScryptedMQTTManager {
    static let shared = ScryptedMQTTManager()

    private let mqttClient = MQTTClient()
    private let defaults = UserDefaults.standard
    private let lock = NSLock()

    // Settings keys
    private let hostKey = "scrypted.mqtt.host"
    private let portKey = "scrypted.mqtt.port"
    private let usernameKey = "scrypted.mqtt.username"
    private let passwordKey = "scrypted.mqtt.password"
    private let enabledKey = "scrypted.mqtt.enabled"

    // Discovered devices
    private var discoveredCameras: [String: ScryptedMQTTCamera] = [:]  // keyed by device ID
    private var discoveredSensors: [String: ScryptedMQTTSensor] = [:]
    private var deviceNameMap: [String: String] = [:]  // device ID -> friendly name

    struct ScryptedMQTTCamera {
        let id: String              // Scrypted device ID
        var name: String            // Friendly name (defaults to ID)
        var motionDetected: Bool = false
        var lastMotionTime: Date?
        var hasObjectDetection: Bool = false
        var lastDetections: [String] = []  // e.g., ["person", "car"]
    }

    struct ScryptedMQTTSensor {
        let name: String
        let type: String  // "motion", "doorbell", "contact"
        var state: Bool = false
        var lastEventTime: Date?
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    var host: String? {
        get { defaults.string(forKey: hostKey) }
        set { defaults.set(newValue, forKey: hostKey) }
    }

    var port: Int {
        get { defaults.integer(forKey: portKey).nonZeroOr(1883) }
        set { defaults.set(newValue, forKey: portKey) }
    }

    var username: String? {
        get { CredentialManager.shared.retrieve(key: "mqtt_username", plugin: "scrypted") }
        set {
            if let value = newValue {
                CredentialManager.shared.store(key: "mqtt_username", value: value, plugin: "scrypted")
            } else {
                CredentialManager.shared.delete(key: "mqtt_username", plugin: "scrypted")
            }
        }
    }

    var password: String? {
        get { CredentialManager.shared.retrieve(key: "mqtt_password", plugin: "scrypted") }
        set {
            if let value = newValue {
                CredentialManager.shared.store(key: "mqtt_password", value: value, plugin: "scrypted")
            } else {
                CredentialManager.shared.delete(key: "mqtt_password", plugin: "scrypted")
            }
        }
    }

    var isConfigured: Bool {
        guard let h = host, !h.isEmpty else { return false }
        return true
    }

    var isConnected: Bool {
        mqttClient.isConnected
    }

    func connect() {
        guard isEnabled, isConfigured, let host = host else {
            log("MQTT: Not configured or disabled")
            return
        }

        guard !isConnected else {
            log("MQTT: Already connected")
            return
        }

        log("MQTT: Connecting to \(host):\(port)...")

        mqttClient.connect(
            host: host,
            port: UInt16(port),
            username: username,
            password: password,
            onMessage: { [weak self] topic, payload in
                self?.handleMessage(topic: topic, payload: payload)
            },
            onStateChange: { [weak self] state in
                switch state {
                case .connected:
                    self?.onConnected()
                case .disconnected:
                    log("MQTT: Disconnected")
                case .connecting:
                    break
                }
            }
        )
    }

    func disconnect() {
        mqttClient.disconnect()
    }

    func getDiscoveredCameras() -> [ScryptedMQTTCamera] {
        lock.lock()
        defer { lock.unlock() }
        return Array(discoveredCameras.values)
    }

    func getDiscoveredSensors() -> [ScryptedMQTTSensor] {
        lock.lock()
        defer { lock.unlock() }
        return Array(discoveredSensors.values)
    }

    // MARK: - Private Methods

    private func onConnected() {
        log("MQTT: Connected, subscribing to Scrypted topics...")

        // Subscribe to ALL Scrypted device topics with wildcard
        // Topic format: scrypted/<device-id>/<property>
        // Using # wildcard to catch all properties and discover cameras automatically
        mqttClient.subscribe(to: [
            "scrypted/#",                      // All Scrypted topics (for discovery)
            "homeassistant/+/+/config"         // Home Assistant auto-discovery (if enabled)
        ])
    }

    private func handleMessage(topic: String, payload: Data) {
        let parts = topic.split(separator: "/")
        guard parts.count >= 2, parts[0] == "scrypted" else {
            // Handle Home Assistant discovery format
            if parts.count >= 4 && parts[0] == "homeassistant" {
                handleHomeAssistantDiscovery(topic: topic, payload: payload)
            }
            return
        }

        let deviceId = String(parts[1])
        let property = parts.count >= 3 ? String(parts[2]) : ""

        // Auto-discover any device that publishes to scrypted/<id>/...
        // If it has motionDetected, it's likely a camera
        autoDiscoverDevice(deviceId: deviceId, property: property, payload: payload)

        switch property {
        case "motionDetected":
            handleMotionDetected(device: deviceId, payload: payload)
        case "ObjectDetector":
            handleObjectDetection(device: deviceId, payload: payload)
        case "binaryState":
            handleBinaryState(device: deviceId, payload: payload)
        case "online":
            handleOnlineState(device: deviceId, payload: payload)
        case "name":
            handleDeviceName(device: deviceId, payload: payload)
        case "interfaces":
            handleDeviceInterfaces(device: deviceId, payload: payload)
        default:
            break
        }
    }

    private func autoDiscoverDevice(deviceId: String, property: String, payload: Data) {
        // Camera-related properties that indicate this is a camera
        let cameraProperties = ["motionDetected", "ObjectDetector", "recording", "recordingActive",
                                "picture", "pictureUrl", "videoStreamUrl", "interfaces"]

        // If device ID looks like a number (Scrypted uses numeric IDs) and we see camera-like properties
        if let _ = Int(deviceId), cameraProperties.contains(property) {
            lock.lock()
            if discoveredCameras[deviceId] == nil {
                let friendlyName = deviceNameMap[deviceId] ?? deviceId
                discoveredCameras[deviceId] = ScryptedMQTTCamera(id: deviceId, name: friendlyName)
                log("MQTT: Auto-discovered camera \(deviceId) via \(property)")
            }
            lock.unlock()
        }
    }

    private func handleDeviceName(device: String, payload: Data) {
        guard let name = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }

        lock.lock()
        deviceNameMap[device] = name
        // Update camera name if already discovered
        if discoveredCameras[device] != nil {
            discoveredCameras[device]?.name = name
            log("MQTT: Updated camera \(device) name to '\(name)'")
        }
        lock.unlock()
    }

    private func handleDeviceInterfaces(device: String, payload: Data) {
        // Interfaces can be JSON array like ["Camera", "MotionSensor", "VideoCamera"]
        // or comma-separated string
        let payloadStr = String(data: payload, encoding: .utf8) ?? ""

        var interfaces: [String] = []
        if let json = try? JSONSerialization.jsonObject(with: payload) as? [String] {
            interfaces = json
        } else {
            interfaces = payloadStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        // If it's a camera, auto-discover it
        let isCamera = interfaces.contains { $0.lowercased().contains("camera") || $0.lowercased().contains("video") }
        if isCamera {
            lock.lock()
            if discoveredCameras[device] == nil {
                let friendlyName = deviceNameMap[device] ?? device
                discoveredCameras[device] = ScryptedMQTTCamera(id: device, name: friendlyName)
                log("MQTT: Discovered camera \(device) (\(friendlyName)) via interfaces")
            }
            lock.unlock()
        }
    }

    private func handleMotionDetected(device: String, payload: Data) {
        let payloadStr = String(data: payload, encoding: .utf8) ?? ""
        let detected = payloadStr == "true" || payloadStr == "1" || payloadStr == "ON"

        lock.lock()
        if discoveredCameras[device] == nil {
            let friendlyName = deviceNameMap[device] ?? device
            discoveredCameras[device] = ScryptedMQTTCamera(id: device, name: friendlyName)
        }
        discoveredCameras[device]?.motionDetected = detected
        if detected {
            discoveredCameras[device]?.lastMotionTime = Date()
        }
        let cameraName = discoveredCameras[device]?.name ?? device
        lock.unlock()

        log("MQTT: \(cameraName) motion \(detected ? "DETECTED" : "cleared")")

        // Post to event system
        postMotionEvent(device: device, detected: detected, type: "motion")
    }

    private func handleObjectDetection(device: String, payload: Data) {
        // Payload format: {"detections":[{"className":"person","score":0.85,...}]}
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let detections = json["detections"] as? [[String: Any]] else {
            return
        }

        let classNames = detections.compactMap { $0["className"] as? String }
        guard !classNames.isEmpty else { return }

        lock.lock()
        if discoveredCameras[device] == nil {
            let friendlyName = deviceNameMap[device] ?? device
            discoveredCameras[device] = ScryptedMQTTCamera(id: device, name: friendlyName)
        }
        discoveredCameras[device]?.hasObjectDetection = true
        discoveredCameras[device]?.lastDetections = classNames
        discoveredCameras[device]?.lastMotionTime = Date()
        let cameraName = discoveredCameras[device]?.name ?? device
        lock.unlock()

        log("MQTT: \(cameraName) detected: \(classNames.joined(separator: ", "))")

        // Post event with detection details
        for className in classNames {
            postMotionEvent(device: device, detected: true, type: "object_\(className)")
        }
    }

    private func handleBinaryState(device: String, payload: Data) {
        let payloadStr = String(data: payload, encoding: .utf8) ?? ""
        let state = payloadStr == "true" || payloadStr == "1" || payloadStr == "ON"

        lock.lock()
        // Could be a contact sensor or doorbell
        if discoveredSensors[device] == nil {
            discoveredSensors[device] = ScryptedMQTTSensor(name: device, type: "contact")
        }
        discoveredSensors[device]?.state = state
        discoveredSensors[device]?.lastEventTime = Date()
        lock.unlock()

        log("MQTT: \(device) binary state: \(state)")

        postMotionEvent(device: device, detected: state, type: "contact")
    }

    private func handleOnlineState(device: String, payload: Data) {
        // Just log for now - could track device availability
        let payloadStr = String(data: payload, encoding: .utf8) ?? ""
        let online = payloadStr == "true" || payloadStr == "1"
        log("MQTT: \(device) online: \(online)")
    }

    private func handleHomeAssistantDiscovery(topic: String, payload: Data) {
        // Home Assistant MQTT discovery format
        // homeassistant/<component>/<node_id>/config
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let name = json["name"] as? String else {
            return
        }

        log("MQTT: HA Discovery - \(name)")

        // Auto-register discovered devices
        lock.lock()
        if topic.contains("/camera/") || topic.contains("/image/") {
            if discoveredCameras[name] == nil {
                discoveredCameras[name] = ScryptedMQTTCamera(id: name, name: name)
            }
        } else if topic.contains("/binary_sensor/") {
            if discoveredSensors[name] == nil {
                let type = topic.contains("motion") ? "motion" : "contact"
                discoveredSensors[name] = ScryptedMQTTSensor(name: name, type: type)
            }
        }
        lock.unlock()
    }

    private func postMotionEvent(device: String, detected: Bool, type: String) {
        // Create event and add to MotionSensorManager buffer
        let event = MotionSensorManager.MotionEvent(
            id: UUID().uuidString,
            sensorName: device,
            sensorId: "scrypted-\(device.lowercased().replacingOccurrences(of: " ", with: "-"))",
            room: "Scrypted",
            home: "Scrypted",
            eventType: type,
            detected: detected,
            timestamp: Date()
        )

        MotionSensorManager.shared.addExternalEvent(event)

        // Also post to MCPPost if enabled
        MCPPostManager.shared.postMotionEvent(
            sensorName: device,
            sensorId: event.sensorId,
            room: "Scrypted",
            home: "Scrypted",
            eventType: type,
            detected: detected
        )
    }
}

// Helper extension
private extension Int {
    func nonZeroOr(_ defaultValue: Int) -> Int {
        self != 0 ? self : defaultValue
    }
}

// MARK: - Camera Manager

class CameraManager: NSObject, HMCameraSnapshotControlDelegate, @unchecked Sendable {
    static let shared = CameraManager()

    private var pendingSnapshots: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var snapshotAccessories: [ObjectIdentifier: HMAccessory] = [:]
    private let lock = NSLock()

    func listCameras() -> [[String: Any]] {
        var cameras: [[String: Any]] = []
        for home in HomeKitManager.shared.homeManager.homes {
            for accessory in home.accessories {
                for profile in accessory.profiles {
                    if let cameraProfile = profile as? HMCameraProfile {
                        cameras.append([
                            "id": accessory.uniqueIdentifier.uuidString,
                            "name": accessory.name,
                            "room": accessory.room?.name ?? "Unknown",
                            "home": home.name,
                            "reachable": accessory.isReachable,
                            "hasSnapshot": cameraProfile.snapshotControl != nil
                        ])
                        break
                    }
                }
            }
        }
        return cameras
    }

    func captureSnapshot(cameraName: String) async throws -> Data {
        guard let accessory = findCamera(name: cameraName) else {
            throw CameraError.cameraNotFound(cameraName)
        }
        guard accessory.isReachable else {
            throw CameraError.cameraNotReachable
        }
        guard let cameraProfile = accessory.profiles.compactMap({ $0 as? HMCameraProfile }).first,
              let snapshotControl = cameraProfile.snapshotControl else {
            throw CameraError.snapshotNotSupported
        }

        snapshotControl.delegate = self
        let requestId = accessory.uniqueIdentifier

        // Store association between control and accessory
        lock.lock()
        snapshotAccessories[ObjectIdentifier(snapshotControl)] = accessory
        lock.unlock()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingSnapshots[requestId] = continuation
            lock.unlock()

            snapshotControl.takeSnapshot()

            // Timeout after 30 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                if let cont = self.pendingSnapshots.removeValue(forKey: requestId) {
                    self.lock.unlock()
                    cont.resume(throwing: CameraError.timeout)
                } else {
                    self.lock.unlock()
                }
            }
        }
    }

    func cameraSnapshotControl(_ control: HMCameraSnapshotControl,
                               didTake snapshot: HMCameraSnapshot?,
                               error: Error?) {
        lock.lock()
        guard let accessory = snapshotAccessories.removeValue(forKey: ObjectIdentifier(control)) else {
            lock.unlock()
            return
        }
        let requestId = accessory.uniqueIdentifier
        guard let continuation = pendingSnapshots.removeValue(forKey: requestId) else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let error = error {
            continuation.resume(throwing: error)
        } else if let snapshot = snapshot {
            // HMCameraSnapshot provides image via aspectRatio, we need to get actual data
            // The snapshot is actually stored as a file URL we need to read
            if let source = snapshot.value(forKey: "source") as? HMCameraSource,
               let streamURL = source.value(forKey: "streamURL") as? URL,
               let imageData = try? Data(contentsOf: streamURL) {
                continuation.resume(returning: imageData)
            } else {
                // Fallback: snapshot doesn't provide direct data access in HomeKit
                // We return an error since HomeKit camera snapshots require the Home app
                continuation.resume(throwing: CameraError.snapshotNotSupported)
            }
        } else {
            continuation.resume(throwing: CameraError.noImageData)
        }
    }

    private func findCamera(name: String) -> HMAccessory? {
        let searchName = name.lowercased()
        for home in HomeKitManager.shared.homeManager.homes {
            for accessory in home.accessories {
                if accessory.name.lowercased() == searchName,
                   accessory.profiles.contains(where: { $0 is HMCameraProfile }) {
                    return accessory
                }
            }
        }
        return nil
    }
}

enum CameraError: Error, LocalizedError {
    case cameraNotFound(String)
    case cameraNotReachable
    case snapshotNotSupported
    case noImageData
    case timeout

    var errorDescription: String? {
        switch self {
        case .cameraNotFound(let name): return "Camera not found: \(name)"
        case .cameraNotReachable: return "Camera is not reachable"
        case .snapshotNotSupported: return "Camera does not support snapshots"
        case .noImageData: return "No image data received"
        case .timeout: return "Snapshot request timed out"
        }
    }
}

// MARK: - Motion Sensor Manager

class MotionSensorManager: NSObject, HMAccessoryDelegate {
    static let shared = MotionSensorManager()

    private var eventBuffer: [MotionEvent] = []
    private let maxEvents = 100
    private let lock = NSLock()

    struct MotionEvent {
        let id: String
        let sensorName: String
        let sensorId: String
        let room: String
        let home: String
        let eventType: String  // "motion", "occupancy", "doorbell"
        let detected: Bool
        let timestamp: Date
    }

    func listMotionSensors() -> [[String: Any]] {
        var sensors: [[String: Any]] = []
        for home in HomeKitManager.shared.homeManager.homes {
            for accessory in home.accessories {
                for service in accessory.services {
                    let type: String?
                    switch service.serviceType {
                    case HMServiceTypeMotionSensor: type = "motion"
                    case HMServiceTypeOccupancySensor: type = "occupancy"
                    case HMServiceTypeDoorbell: type = "doorbell"
                    default: type = nil
                    }
                    if let type = type {
                        sensors.append([
                            "id": accessory.uniqueIdentifier.uuidString,
                            "name": accessory.name,
                            "room": accessory.room?.name ?? "Unknown",
                            "home": home.name,
                            "type": type,
                            "reachable": accessory.isReachable
                        ])
                    }
                }
            }
        }
        return sensors
    }

    func getMotionState(sensorName: String) async throws -> [String: Any] {
        guard let (accessory, home) = findMotionSensor(name: sensorName) else {
            throw MotionError.sensorNotFound(sensorName)
        }

        var state: [String: Any] = [
            "name": accessory.name,
            "reachable": accessory.isReachable,
            "room": accessory.room?.name ?? "Unknown",
            "home": home.name
        ]

        let motionService = accessory.services.first {
            $0.serviceType == HMServiceTypeMotionSensor ||
            $0.serviceType == HMServiceTypeOccupancySensor
        }

        guard let service = motionService else {
            state["error"] = "No motion service found"
            return state
        }

        return try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()
            var detectedValue: Bool?

            for char in service.characteristics {
                if char.characteristicType == HMCharacteristicTypeMotionDetected ||
                   char.characteristicType == HMCharacteristicTypeOccupancyDetected {
                    guard char.properties.contains(HMCharacteristicPropertyReadable) else { continue }
                    group.enter()
                    char.readValue { _ in
                        if let value = char.value as? Bool {
                            detectedValue = value
                        } else if let value = char.value as? Int {
                            detectedValue = value > 0
                        }
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                state["motionDetected"] = detectedValue ?? false
                state["success"] = true
                continuation.resume(returning: state)
            }
        }
    }

    func subscribeToEvents() {
        for home in HomeKitManager.shared.homeManager.homes {
            for accessory in home.accessories {
                accessory.delegate = self
                for service in accessory.services {
                    if service.serviceType == HMServiceTypeMotionSensor ||
                       service.serviceType == HMServiceTypeOccupancySensor ||
                       service.serviceType == HMServiceTypeDoorbell {
                        for char in service.characteristics {
                            if char.characteristicType == HMCharacteristicTypeMotionDetected ||
                               char.characteristicType == HMCharacteristicTypeOccupancyDetected {
                                if char.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                                    char.enableNotification(true) { error in
                                        if error == nil {
                                            log("Subscribed to \(accessory.name) events")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func getPendingEvents(since: Date? = nil, limit: Int = 50) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }

        var events = eventBuffer
        if let since = since {
            events = events.filter { $0.timestamp > since }
        }

        return Array(events.suffix(limit)).map { event in
            [
                "id": event.id,
                "sensorName": event.sensorName,
                "sensorId": event.sensorId,
                "room": event.room,
                "home": event.home,
                "eventType": event.eventType,
                "detected": event.detected,
                "timestamp": ISO8601DateFormatter().string(from: event.timestamp)
            ]
        }
    }

    func clearEvents() {
        lock.lock()
        eventBuffer.removeAll()
        lock.unlock()
    }

    /// Add an event from external sources (like MQTT)
    func addExternalEvent(_ event: MotionEvent) {
        lock.lock()
        eventBuffer.append(event)
        if eventBuffer.count > maxEvents { eventBuffer.removeFirst() }
        lock.unlock()
    }

    // HMAccessoryDelegate
    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        guard characteristic.characteristicType == HMCharacteristicTypeMotionDetected ||
              characteristic.characteristicType == HMCharacteristicTypeOccupancyDetected else { return }

        let detected: Bool
        if let value = characteristic.value as? Bool { detected = value }
        else if let value = characteristic.value as? Int { detected = value > 0 }
        else { return }

        let eventType: String
        switch service.serviceType {
        case HMServiceTypeMotionSensor: eventType = "motion"
        case HMServiceTypeOccupancySensor: eventType = "occupancy"
        case HMServiceTypeDoorbell: eventType = "doorbell"
        default: eventType = "unknown"
        }

        let home = HomeKitManager.shared.homeManager.homes.first { $0.accessories.contains(accessory) }

        let event = MotionEvent(
            id: UUID().uuidString,
            sensorName: accessory.name,
            sensorId: accessory.uniqueIdentifier.uuidString,
            room: accessory.room?.name ?? "Unknown",
            home: home?.name ?? "Unknown",
            eventType: eventType,
            detected: detected,
            timestamp: Date()
        )

        lock.lock()
        eventBuffer.append(event)
        if eventBuffer.count > maxEvents { eventBuffer.removeFirst() }
        lock.unlock()

        log("Motion: \(accessory.name) -> \(detected ? "DETECTED" : "cleared")")

        // Post to MCPPost endpoint
        MCPPostManager.shared.postMotionEvent(
            sensorName: accessory.name,
            sensorId: accessory.uniqueIdentifier.uuidString,
            room: accessory.room?.name ?? "Unknown",
            home: home?.name ?? "Unknown",
            eventType: eventType,
            detected: detected
        )
    }

    private func findMotionSensor(name: String) -> (HMAccessory, HMHome)? {
        let searchName = name.lowercased()
        for home in HomeKitManager.shared.homeManager.homes {
            for accessory in home.accessories where accessory.name.lowercased() == searchName {
                if accessory.services.contains(where: {
                    $0.serviceType == HMServiceTypeMotionSensor ||
                    $0.serviceType == HMServiceTypeOccupancySensor
                }) {
                    return (accessory, home)
                }
            }
        }
        return nil
    }
}

enum MotionError: Error, LocalizedError {
    case sensorNotFound(String)
    var errorDescription: String? {
        switch self { case .sensorNotFound(let name): return "Sensor not found: \(name)" }
    }
}

// MARK: - MCP Post Manager (Event Broadcasting)

class MCPPostManager {
    static let shared = MCPPostManager()

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var recentEvents: [PostedEvent] = []
    private let maxRecentEvents = 50

    // Settings keys
    private let endpointURLKey = "mcpPost.endpointURL"
    private let isEnabledKey = "mcpPost.isEnabled"

    struct PostedEvent {
        let id: String
        let eventType: String  // "motion", "occupancy", "doorbell", "contact"
        let sensorName: String
        let sensorId: String
        let room: String
        let home: String
        let detected: Bool
        let value: String?  // For contact sensors: "open" or "closed"
        let timestamp: Date
        let postSuccess: Bool
        let errorMessage: String?
    }

    var endpointURL: String? {
        get { defaults.string(forKey: endpointURLKey) }
        set {
            defaults.set(newValue, forKey: endpointURLKey)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .mcpPostSettingsUpdated, object: nil)
            }
        }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: isEnabledKey) }
        set {
            defaults.set(newValue, forKey: isEnabledKey)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .mcpPostSettingsUpdated, object: nil)
            }
        }
    }

    var isConfigured: Bool {
        guard let url = endpointURL, !url.isEmpty else { return false }
        return URL(string: url) != nil
    }

    func getRecentEvents() -> [PostedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recentEvents
    }

    func clearRecentEvents() {
        lock.lock()
        recentEvents.removeAll()
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mcpPostEventReceived, object: nil)
        }
    }

    /// Post a motion/occupancy/doorbell event
    func postMotionEvent(
        sensorName: String,
        sensorId: String,
        room: String,
        home: String,
        eventType: String,
        detected: Bool
    ) {
        let payload: [String: Any] = [
            "event_id": UUID().uuidString,
            "event_type": eventType,
            "source": "HomeKit",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sensor": [
                "name": sensorName,
                "id": sensorId,
                "room": room,
                "home": home
            ],
            "data": [
                "detected": detected
            ]
        ]

        postEvent(
            eventType: eventType,
            sensorName: sensorName,
            sensorId: sensorId,
            room: room,
            home: home,
            detected: detected,
            value: nil,
            payload: payload
        )
    }

    /// Post a contact sensor event (door/window open/close)
    func postContactEvent(
        sensorName: String,
        sensorId: String,
        room: String,
        home: String,
        isOpen: Bool
    ) {
        let payload: [String: Any] = [
            "event_id": UUID().uuidString,
            "event_type": "contact",
            "source": "HomeKit",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sensor": [
                "name": sensorName,
                "id": sensorId,
                "room": room,
                "home": home
            ],
            "data": [
                "state": isOpen ? "open" : "closed",
                "isOpen": isOpen
            ]
        ]

        postEvent(
            eventType: "contact",
            sensorName: sensorName,
            sensorId: sensorId,
            room: room,
            home: home,
            detected: isOpen,
            value: isOpen ? "open" : "closed",
            payload: payload
        )
    }

    private func postEvent(
        eventType: String,
        sensorName: String,
        sensorId: String,
        room: String,
        home: String,
        detected: Bool,
        value: String?,
        payload: [String: Any]
    ) {
        guard isEnabled, isConfigured, let urlString = endpointURL, let url = URL(string: urlString) else {
            return
        }

        let eventId = UUID().uuidString

        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("HomeMCPBridge/1.0", forHTTPHeaderField: "User-Agent")

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                self.recordEvent(
                    id: eventId,
                    eventType: eventType,
                    sensorName: sensorName,
                    sensorId: sensorId,
                    room: room,
                    home: home,
                    detected: detected,
                    value: value,
                    success: false,
                    error: "Failed to encode payload: \(error.localizedDescription)"
                )
                return
            }

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse
                let success = httpResponse?.statusCode ?? 0 >= 200 && httpResponse?.statusCode ?? 0 < 300

                self.recordEvent(
                    id: eventId,
                    eventType: eventType,
                    sensorName: sensorName,
                    sensorId: sensorId,
                    room: room,
                    home: home,
                    detected: detected,
                    value: value,
                    success: success,
                    error: success ? nil : "HTTP \(httpResponse?.statusCode ?? 0)"
                )

                if success {
                    log("MCPPost: Sent \(eventType) event for \(sensorName)")
                } else {
                    log("MCPPost: Failed to send event - HTTP \(httpResponse?.statusCode ?? 0)")
                }
            } catch {
                self.recordEvent(
                    id: eventId,
                    eventType: eventType,
                    sensorName: sensorName,
                    sensorId: sensorId,
                    room: room,
                    home: home,
                    detected: detected,
                    value: value,
                    success: false,
                    error: error.localizedDescription
                )
                log("MCPPost: Failed to send event - \(error.localizedDescription)")
            }
        }
    }

    private func recordEvent(
        id: String,
        eventType: String,
        sensorName: String,
        sensorId: String,
        room: String,
        home: String,
        detected: Bool,
        value: String?,
        success: Bool,
        error: String?
    ) {
        let event = PostedEvent(
            id: id,
            eventType: eventType,
            sensorName: sensorName,
            sensorId: sensorId,
            room: room,
            home: home,
            detected: detected,
            value: value,
            timestamp: Date(),
            postSuccess: success,
            errorMessage: error
        )

        lock.lock()
        recentEvents.insert(event, at: 0)
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeLast()
        }
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mcpPostEventReceived, object: nil)
        }
    }

    /// List all event-producing devices (sensors only, not bulbs/switches)
    func listEventProducingDevices() -> [[String: Any]] {
        var devices: [[String: Any]] = []

        for home in HomeKitManager.shared.homeManager.homes {
            for accessory in home.accessories {
                for service in accessory.services {
                    var deviceType: String?
                    var eventDescription: String?

                    switch service.serviceType {
                    case HMServiceTypeMotionSensor:
                        deviceType = "motion"
                        eventDescription = "Detects motion"
                    case HMServiceTypeOccupancySensor:
                        deviceType = "occupancy"
                        eventDescription = "Detects occupancy"
                    case HMServiceTypeDoorbell:
                        deviceType = "doorbell"
                        eventDescription = "Doorbell ring"
                    case HMServiceTypeContactSensor:
                        deviceType = "contact"
                        eventDescription = "Door/window open/close"
                    default:
                        break
                    }

                    if let type = deviceType {
                        devices.append([
                            "id": accessory.uniqueIdentifier.uuidString,
                            "name": accessory.name,
                            "room": accessory.room?.name ?? "Unknown",
                            "home": home.name,
                            "type": type,
                            "eventDescription": eventDescription ?? "",
                            "reachable": accessory.isReachable
                        ])
                    }
                }
            }
        }

        return devices
    }
}

// MARK: - Contact Sensor Manager (Door/Window sensors)

class ContactSensorManager: NSObject, HMAccessoryDelegate {
    static let shared = ContactSensorManager()

    func subscribeToEvents() {
        for home in HomeKitManager.shared.homeManager.homes {
            for accessory in home.accessories {
                for service in accessory.services {
                    if service.serviceType == HMServiceTypeContactSensor {
                        accessory.delegate = self
                        for char in service.characteristics {
                            if char.characteristicType == HMCharacteristicTypeContactState {
                                if char.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                                    char.enableNotification(true) { error in
                                        if error == nil {
                                            log("Subscribed to \(accessory.name) contact events")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func listContactSensors() -> [[String: Any]] {
        var sensors: [[String: Any]] = []
        for home in HomeKitManager.shared.homeManager.homes {
            for accessory in home.accessories {
                for service in accessory.services where service.serviceType == HMServiceTypeContactSensor {
                    sensors.append([
                        "id": accessory.uniqueIdentifier.uuidString,
                        "name": accessory.name,
                        "room": accessory.room?.name ?? "Unknown",
                        "home": home.name,
                        "type": "contact",
                        "reachable": accessory.isReachable
                    ])
                }
            }
        }
        return sensors
    }

    func getContactState(sensorName: String) async throws -> [String: Any] {
        guard let (accessory, home) = findContactSensor(name: sensorName) else {
            throw MotionError.sensorNotFound(sensorName)
        }

        var state: [String: Any] = [
            "name": accessory.name,
            "reachable": accessory.isReachable,
            "room": accessory.room?.name ?? "Unknown",
            "home": home.name
        ]

        let contactService = accessory.services.first { $0.serviceType == HMServiceTypeContactSensor }

        guard let service = contactService else {
            state["error"] = "No contact service found"
            return state
        }

        return try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()
            var contactState: Int?

            for char in service.characteristics {
                if char.characteristicType == HMCharacteristicTypeContactState {
                    guard char.properties.contains(HMCharacteristicPropertyReadable) else { continue }
                    group.enter()
                    char.readValue { _ in
                        if let value = char.value as? Int {
                            contactState = value
                        }
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                // ContactState: 0 = detected (closed), 1 = not detected (open)
                let isOpen = contactState == 1
                state["isOpen"] = isOpen
                state["state"] = isOpen ? "open" : "closed"
                state["success"] = true
                continuation.resume(returning: state)
            }
        }
    }

    // HMAccessoryDelegate
    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        guard characteristic.characteristicType == HMCharacteristicTypeContactState,
              service.serviceType == HMServiceTypeContactSensor else { return }

        guard let contactValue = characteristic.value as? Int else { return }

        // ContactState: 0 = detected (closed), 1 = not detected (open)
        let isOpen = contactValue == 1
        let home = HomeKitManager.shared.homeManager.homes.first { $0.accessories.contains(accessory) }

        log("Contact: \(accessory.name) -> \(isOpen ? "OPEN" : "closed")")

        // Post to MCPPost endpoint
        MCPPostManager.shared.postContactEvent(
            sensorName: accessory.name,
            sensorId: accessory.uniqueIdentifier.uuidString,
            room: accessory.room?.name ?? "Unknown",
            home: home?.name ?? "Unknown",
            isOpen: isOpen
        )
    }

    private func findContactSensor(name: String) -> (HMAccessory, HMHome)? {
        let searchName = name.lowercased()
        for home in HomeKitManager.shared.homeManager.homes {
            for accessory in home.accessories where accessory.name.lowercased() == searchName {
                if accessory.services.contains(where: { $0.serviceType == HMServiceTypeContactSensor }) {
                    return (accessory, home)
                }
            }
        }
        return nil
    }
}

// MARK: - MCP Server

class MCPServer {
    private let homeKit = HomeKitManager.shared
    private var isRunning = false

    private let tools: [[String: Any]] = [
        [
            "name": "list_devices",
            "description": "List all devices from HomeKit and enabled plugins (Govee) with their names, rooms, types, source, and reachability status.",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ],
        [
            "name": "list_rooms",
            "description": "List all rooms in all HomeKit homes.",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ],
        [
            "name": "get_device_state",
            "description": "Get the current state of a device (on/off, brightness, color, etc.). Works with HomeKit and Govee devices.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string", "description": "The name of the device"]],
                "required": ["name"]
            ]
        ],
        [
            "name": "control_device",
            "description": "Control a device. Works with HomeKit and Govee. Actions: on, off, toggle, brightness (0-100), color ({hue, saturation} for HomeKit, {r, g, b} for Govee), lock, unlock, open, close.",
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
        ],
        // Camera tools
        [
            "name": "list_cameras",
            "description": "List all HomeKit cameras.",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ],
        [
            "name": "capture_snapshot",
            "description": "Capture a snapshot from a HomeKit camera. Returns base64-encoded JPEG image.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string", "description": "The name of the camera"]],
                "required": ["name"]
            ]
        ],
        // Motion sensor tools
        [
            "name": "list_motion_sensors",
            "description": "List all motion sensors, occupancy sensors, and doorbells in HomeKit.",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ],
        [
            "name": "get_motion_state",
            "description": "Get the current motion detection state of a sensor.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string", "description": "The name of the motion sensor"]],
                "required": ["name"]
            ]
        ],
        [
            "name": "subscribe_events",
            "description": "Enable motion event buffering. Events will be stored and can be retrieved with get_pending_events.",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ],
        [
            "name": "get_pending_events",
            "description": "Get buffered motion/doorbell events. Use this to poll for new motion events.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "since": ["type": "string", "description": "ISO8601 timestamp to filter events after this time"],
                    "limit": ["type": "integer", "description": "Maximum number of events to return (default 50)"],
                    "clear": ["type": "boolean", "description": "Clear events after retrieving (default false)"]
                ],
                "required": []
            ]
        ],
        // Scrypted NVR tools
        [
            "name": "scrypted_list_cameras",
            "description": "List all cameras from Scrypted NVR with their capabilities (motion detection, audio, etc.).",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ],
        [
            "name": "scrypted_capture_snapshot",
            "description": "Capture a snapshot from a Scrypted camera. Returns base64-encoded JPEG image.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "camera_id": ["type": "string", "description": "The Scrypted device ID of the camera"],
                    "camera_name": ["type": "string", "description": "The name of the camera (alternative to camera_id)"]
                ],
                "required": []
            ]
        ],
        [
            "name": "scrypted_get_camera_state",
            "description": "Get the current state of a Scrypted camera including motion detection status.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "camera_id": ["type": "string", "description": "The Scrypted device ID of the camera"],
                    "camera_name": ["type": "string", "description": "The name of the camera (alternative to camera_id)"]
                ],
                "required": []
            ]
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

        // Camera tools
        case "list_cameras":
            let cameras = CameraManager.shared.listCameras()
            log("  -> Found \(cameras.count) cameras")
            respondToolResult(id: id, result: ["cameras": cameras, "count": cameras.count])

        case "capture_snapshot":
            guard let cameraName = arguments["name"] as? String else {
                respondToolResult(id: id, result: ["error": "Missing 'name' parameter", "success": false])
                return
            }

            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any] = [:]

            Task {
                do {
                    let imageData = try await CameraManager.shared.captureSnapshot(cameraName: cameraName)
                    let base64 = imageData.base64EncodedString()
                    result = [
                        "success": true,
                        "camera": cameraName,
                        "image": base64,
                        "mimeType": "image/jpeg",
                        "size": imageData.count
                    ]
                } catch {
                    result = ["error": error.localizedDescription, "success": false]
                }
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 35)
            log("  -> Snapshot for '\(cameraName)'")
            respondToolResult(id: id, result: result)

        // Motion sensor tools
        case "list_motion_sensors":
            let sensors = MotionSensorManager.shared.listMotionSensors()
            log("  -> Found \(sensors.count) motion sensors")
            respondToolResult(id: id, result: ["sensors": sensors, "count": sensors.count])

        case "get_motion_state":
            guard let sensorName = arguments["name"] as? String else {
                respondToolResult(id: id, result: ["error": "Missing 'name' parameter", "success": false])
                return
            }

            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any] = [:]

            Task {
                do {
                    result = try await MotionSensorManager.shared.getMotionState(sensorName: sensorName)
                } catch {
                    result = ["error": error.localizedDescription, "success": false]
                }
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 15)
            log("  -> Motion state for '\(sensorName)'")
            respondToolResult(id: id, result: result)

        case "subscribe_events":
            MotionSensorManager.shared.subscribeToEvents()
            ContactSensorManager.shared.subscribeToEvents()
            log("  -> Subscribed to motion and contact events")
            respondToolResult(id: id, result: [
                "success": true,
                "message": "Subscribed to motion and contact events. Use get_pending_events to poll for new events."
            ])

        case "get_pending_events":
            var since: Date? = nil
            if let sinceString = arguments["since"] as? String {
                since = ISO8601DateFormatter().date(from: sinceString)
            }
            let limit = arguments["limit"] as? Int ?? 50
            let shouldClear = arguments["clear"] as? Bool ?? false

            let events = MotionSensorManager.shared.getPendingEvents(since: since, limit: limit)
            if shouldClear {
                MotionSensorManager.shared.clearEvents()
            }

            log("  -> Retrieved \(events.count) pending events")
            respondToolResult(id: id, result: [
                "events": events,
                "count": events.count,
                "cleared": shouldClear
            ])

        // Scrypted NVR tools
        case "scrypted_list_cameras":
            guard let scryptedPlugin = PluginManager.shared.plugin(withId: "scrypted") as? ScryptedPlugin else {
                respondToolResult(id: id, result: ["error": "Scrypted plugin not available", "success": false])
                return
            }

            if !scryptedPlugin.isConfigured {
                respondToolResult(id: id, result: [
                    "error": "Scrypted plugin not configured. Use configure_plugin to set host, username, and password.",
                    "success": false
                ])
                return
            }

            var result: [String: Any] = [:]
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let cameras = try await scryptedPlugin.listCameras()
                    result = [
                        "cameras": cameras.map { cam in
                            [
                                "id": cam.id,
                                "name": cam.name,
                                "room": cam.room ?? "Unknown",
                                "hasMotionSensor": cam.hasMotionSensor,
                                "hasAudioDetection": cam.hasAudioDetection,
                                "isOnline": cam.isOnline
                            ]
                        },
                        "count": cameras.count,
                        "success": true
                    ]
                } catch {
                    result = ["error": error.localizedDescription, "success": false]
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 30)
            log("  -> Found \(result["count"] ?? 0) Scrypted cameras")
            respondToolResult(id: id, result: result)

        case "scrypted_capture_snapshot":
            guard let scryptedPlugin = PluginManager.shared.plugin(withId: "scrypted") as? ScryptedPlugin else {
                respondToolResult(id: id, result: ["error": "Scrypted plugin not available", "success": false])
                return
            }

            if !scryptedPlugin.isConfigured {
                respondToolResult(id: id, result: [
                    "error": "Scrypted plugin not configured. Use configure_plugin to set host, username, and password.",
                    "success": false
                ])
                return
            }

            // Get camera ID from arguments (either by ID or name)
            var cameraId: String? = arguments["camera_id"] as? String
            if cameraId == nil, let cameraName = arguments["camera_name"] as? String {
                // Look up camera ID by name
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    do {
                        let cameras = try await scryptedPlugin.listCameras()
                        if let camera = cameras.first(where: { $0.name.lowercased() == cameraName.lowercased() }) {
                            cameraId = camera.id
                        }
                    } catch {}
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 10)
            }

            guard let finalCameraId = cameraId else {
                respondToolResult(id: id, result: ["error": "Camera not found. Provide camera_id or valid camera_name.", "success": false])
                return
            }

            var result: [String: Any] = [:]
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let imageData = try await scryptedPlugin.captureSnapshot(cameraId: finalCameraId)
                    let base64 = imageData.base64EncodedString()
                    result = [
                        "success": true,
                        "camera_id": finalCameraId,
                        "image": base64,
                        "contentType": "image/jpeg",
                        "size": imageData.count
                    ]
                } catch {
                    result = ["error": error.localizedDescription, "success": false]
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 30)
            log("  -> Scrypted snapshot captured: \(result["success"] as? Bool ?? false)")
            respondToolResult(id: id, result: result)

        case "scrypted_get_camera_state":
            guard let scryptedPlugin = PluginManager.shared.plugin(withId: "scrypted") as? ScryptedPlugin else {
                respondToolResult(id: id, result: ["error": "Scrypted plugin not available", "success": false])
                return
            }

            if !scryptedPlugin.isConfigured {
                respondToolResult(id: id, result: [
                    "error": "Scrypted plugin not configured. Use configure_plugin to set host, username, and password.",
                    "success": false
                ])
                return
            }

            // Get camera ID from arguments (either by ID or name)
            var cameraId: String? = arguments["camera_id"] as? String
            if cameraId == nil, let cameraName = arguments["camera_name"] as? String {
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    do {
                        let cameras = try await scryptedPlugin.listCameras()
                        if let camera = cameras.first(where: { $0.name.lowercased() == cameraName.lowercased() }) {
                            cameraId = camera.id
                        }
                    } catch {}
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 10)
            }

            guard let finalCameraId = cameraId else {
                respondToolResult(id: id, result: ["error": "Camera not found. Provide camera_id or valid camera_name.", "success": false])
                return
            }

            var result: [String: Any] = [:]
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let state = try await scryptedPlugin.getMotionState(cameraId: finalCameraId)
                    result = state
                    result["success"] = true
                    result["camera_id"] = finalCameraId
                } catch {
                    result = ["error": error.localizedDescription, "success": false]
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 15)
            log("  -> Scrypted camera state for '\(finalCameraId)'")
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
    private var sourcesStackView: UIStackView!
    private var totalDevicesLabel: UILabel!
    private var linkedDevicesLabel: UILabel!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()

        NotificationCenter.default.addObserver(self, selector: #selector(updateStatus), name: .homeKitUpdated, object: nil)

        updateStatus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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

        // Total Devices Card
        let totalCard = createTotalDevicesCard()
        contentView.addSubview(totalCard)

        // Device Sources Header
        let sourcesHeader = UILabel()
        sourcesHeader.text = "Device Sources"
        sourcesHeader.font = .boldSystemFont(ofSize: 16)
        sourcesHeader.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sourcesHeader)

        // Sources stack view (HomeKit + plugins all in same style)
        sourcesStackView = UIStackView()
        sourcesStackView.axis = .vertical
        sourcesStackView.spacing = 8
        sourcesStackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sourcesStackView)

        // Separator
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator)

        // Linked Devices Info
        let linkedHeader = UILabel()
        linkedHeader.text = "Device Links"
        linkedHeader.font = .boldSystemFont(ofSize: 16)
        linkedHeader.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(linkedHeader)

        linkedDevicesLabel = UILabel()
        linkedDevicesLabel.font = .systemFont(ofSize: 14)
        linkedDevicesLabel.textColor = .secondaryLabel
        linkedDevicesLabel.numberOfLines = 0
        linkedDevicesLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(linkedDevicesLabel)

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

            totalCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            totalCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            totalCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            sourcesHeader.topAnchor.constraint(equalTo: totalCard.bottomAnchor, constant: 24),
            sourcesHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            sourcesStackView.topAnchor.constraint(equalTo: sourcesHeader.bottomAnchor, constant: 12),
            sourcesStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            sourcesStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            separator.topAnchor.constraint(equalTo: sourcesStackView.bottomAnchor, constant: 20),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            separator.heightAnchor.constraint(equalToConstant: 1),

            linkedHeader.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            linkedHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            linkedDevicesLabel.topAnchor.constraint(equalTo: linkedHeader.bottomAnchor, constant: 4),
            linkedDevicesLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            linkedDevicesLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            linkedDevicesLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    private func createTotalDevicesCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .systemBlue
        card.layer.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: UIImage(systemName: "square.grid.2x2.fill"))
        iconView.tintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(iconView)

        let titleLabel = UILabel()
        titleLabel.text = "Total Devices"
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .white.withAlphaComponent(0.9)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleLabel)

        totalDevicesLabel = UILabel()
        totalDevicesLabel.text = "0"
        totalDevicesLabel.font = .systemFont(ofSize: 36, weight: .bold)
        totalDevicesLabel.textColor = .white
        totalDevicesLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(totalDevicesLabel)

        let subtitleLabel = UILabel()
        subtitleLabel.text = "across all sources"
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .white.withAlphaComponent(0.8)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 100),

            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            iconView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),

            totalDevicesLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            totalDevicesLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),

            subtitleLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            subtitleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16)
        ])

        return card
    }

    private func createSourceCard(name: String, icon: String, deviceCount: Int, status: String, statusColor: UIColor, isHomeKit: Bool = false) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = isHomeKit ? .systemOrange : .systemBlue
        iconView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(iconView)

        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(nameLabel)

        let countLabel = UILabel()
        countLabel.text = "\(deviceCount) devices"
        countLabel.font = .systemFont(ofSize: 13)
        countLabel.textColor = .secondaryLabel
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(countLabel)

        let statusLabel = UILabel()
        statusLabel.text = status
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = statusColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 60),

            iconView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),

            countLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            countLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),

            statusLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14)
        ])

        return card
    }

    @objc private func updateStatus() {
        // Clear existing source cards
        sourcesStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var totalDevices = 0

        // HomeKit source
        let homeKit = HomeKitManager.shared
        let homeKitCount = homeKit.deviceCount
        totalDevices += homeKitCount

        let homeKitCard = createSourceCard(
            name: "Apple HomeKit",
            icon: "homekit",
            deviceCount: homeKitCount,
            status: "Active",
            statusColor: .systemGreen,
            isHomeKit: true
        )
        sourcesStackView.addArrangedSubview(homeKitCard)

        // Plugin sources
        let plugins = PluginManager.shared.allPlugins().filter { $0.identifier != "homekit" }
        for plugin in plugins {
            let isActive = plugin.isEnabled && plugin.isConfigured
            let status: String
            let statusColor: UIColor

            if isActive {
                status = "Active"
                statusColor = .systemGreen
            } else if plugin.isEnabled && !plugin.isConfigured {
                status = "Not Configured"
                statusColor = .systemOrange
            } else {
                status = "Disabled"
                statusColor = .secondaryLabel
            }

            // Create card with 0 devices initially
            let card = createSourceCard(
                name: plugin.displayName,
                icon: "puzzlepiece.extension.fill",
                deviceCount: 0,
                status: status,
                statusColor: statusColor
            )
            sourcesStackView.addArrangedSubview(card)

            // Update device count asynchronously if active
            if isActive {
                Task {
                    if let devices = try? await plugin.listDevices() {
                        await MainActor.run {
                            totalDevices += devices.count
                            self.totalDevicesLabel.text = "\(totalDevices)"

                            // Update the count label in the card
                            if let countLabel = card.subviews.compactMap({ $0 as? UILabel }).first(where: { $0.text?.contains("devices") == true }) {
                                countLabel.text = "\(devices.count) devices"
                            }
                        }
                    }
                }
            }
        }

        totalDevicesLabel.text = "\(totalDevices)"

        // Device links
        let links = DeviceLinkManager.shared.getAllLinks()
        if links.isEmpty {
            linkedDevicesLabel.text = "No devices linked. Tap (i) on a device in the Devices tab to link it with a device from another source."
        } else {
            linkedDevicesLabel.text = "\(links.count) device link(s) configured"
        }
    }
}

// MARK: - Setup View Controller

class SetupViewController: UIViewController {
    private var menuBarSwitch: UISwitch?
    private var dockSwitch: UISwitch?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = .systemBackground
        setupUI()
    }

    private func setupUI() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        var lastView: UIView = contentView
        var lastAnchor = contentView.topAnchor
        let padding: CGFloat = 20

        // MCP Configuration Section
        let mcpHeader = createSectionHeader("MCP Configuration")
        contentView.addSubview(mcpHeader)
        NSLayoutConstraint.activate([
            mcpHeader.topAnchor.constraint(equalTo: lastAnchor, constant: padding),
            mcpHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            mcpHeader.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding)
        ])
        lastView = mcpHeader

        let mcpDesc = createDescription("Add this to your project's .mcp.json or Claude Desktop config:")
        contentView.addSubview(mcpDesc)
        NSLayoutConstraint.activate([
            mcpDesc.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 4),
            mcpDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            mcpDesc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding)
        ])
        lastView = mcpDesc

        let execPath = Bundle.main.executablePath ?? "/Applications/HomeMCPBridge.app/Contents/MacOS/HomeMCPBridge"
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
        let configTextView = createCodeView(configCode)
        contentView.addSubview(configTextView)
        NSLayoutConstraint.activate([
            configTextView.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 8),
            configTextView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            configTextView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            configTextView.heightAnchor.constraint(equalToConstant: 120)
        ])
        lastView = configTextView

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("Copy Configuration", for: .normal)
        copyButton.addTarget(self, action: #selector(copyConfig), for: .touchUpInside)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(copyButton)
        NSLayoutConstraint.activate([
            copyButton.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 8),
            copyButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding)
        ])
        lastView = copyButton

        // Separator
        let sep1 = createSeparator()
        contentView.addSubview(sep1)
        NSLayoutConstraint.activate([
            sep1.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 16),
            sep1.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            sep1.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            sep1.heightAnchor.constraint(equalToConstant: 1)
        ])
        lastView = sep1

        // Govee Plugin Setup
        let goveeHeader = createSectionHeader("Govee Plugin Setup")
        contentView.addSubview(goveeHeader)
        NSLayoutConstraint.activate([
            goveeHeader.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 16),
            goveeHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding)
        ])
        lastView = goveeHeader

        let goveeSteps = """
1. Open the Govee app on your phone
2. Go to Settings (Profile tab)
3. Tap "About Us"
4. Tap "Apply for API Key"
5. Fill out the form and submit
6. You'll receive your API key via email (usually within 24 hours)
7. Enter the API key in the Plugins tab
"""
        let goveeDesc = createDescription(goveeSteps)
        contentView.addSubview(goveeDesc)
        NSLayoutConstraint.activate([
            goveeDesc.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 8),
            goveeDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            goveeDesc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding)
        ])
        lastView = goveeDesc

        // Separator
        let sep2 = createSeparator()
        contentView.addSubview(sep2)
        NSLayoutConstraint.activate([
            sep2.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 16),
            sep2.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            sep2.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            sep2.heightAnchor.constraint(equalToConstant: 1)
        ])
        lastView = sep2

        // Scrypted Plugin Setup
        let scryptedHeader = createSectionHeader("Scrypted NVR Plugin Setup")
        contentView.addSubview(scryptedHeader)
        NSLayoutConstraint.activate([
            scryptedHeader.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 16),
            scryptedHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding)
        ])
        lastView = scryptedHeader

        let scryptedSteps = """
1. Install and configure Scrypted on your network
2. Note your Scrypted server URL (e.g., https://mac-mini.local:10443)
3. Create an admin user in Scrypted if you haven't already
4. Install the @scrypted/mqtt plugin in Scrypted
5. Enable the built-in MQTT Broker in the MQTT plugin settings
6. Enable MQTT on each camera you want to discover
7. Go to Settings tab and configure Scrypted MQTT:
   - Host: mac-mini.local (your Scrypted server)
   - Port: 1883 (default MQTT port)
   - Enable the connection

Cameras are automatically discovered via MQTT - no manual configuration needed per camera!
"""
        let scryptedDesc = createDescription(scryptedSteps)
        contentView.addSubview(scryptedDesc)
        NSLayoutConstraint.activate([
            scryptedDesc.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 8),
            scryptedDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            scryptedDesc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding)
        ])
        lastView = scryptedDesc

        // Separator
        let sep3 = createSeparator()
        contentView.addSubview(sep3)
        NSLayoutConstraint.activate([
            sep3.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 16),
            sep3.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            sep3.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            sep3.heightAnchor.constraint(equalToConstant: 1)
        ])
        lastView = sep3

        // MCPPost Setup
        let mcpPostHeader = createSectionHeader("MCPPost (Event Broadcasting)")
        contentView.addSubview(mcpPostHeader)
        NSLayoutConstraint.activate([
            mcpPostHeader.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 16),
            mcpPostHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding)
        ])
        lastView = mcpPostHeader

        let mcpPostSteps = """
MCPPost broadcasts real-time sensor events to your AI system (like Jarvis).

1. Set up an HTTP endpoint on your AI server that accepts POST requests
2. Go to the MCPPost tab
3. Enter your endpoint URL
4. Enable broadcasting with the toggle
5. Test the endpoint to verify connectivity

Events are sent as JSON with this format:
{
  "event_type": "motion|contact|doorbell",
  "sensor": { "name": "...", "room": "..." },
  "data": { "detected": true }
}
"""
        let mcpPostDesc = createDescription(mcpPostSteps)
        contentView.addSubview(mcpPostDesc)
        NSLayoutConstraint.activate([
            mcpPostDesc.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 8),
            mcpPostDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            mcpPostDesc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding)
        ])
        lastView = mcpPostDesc

        // Separator
        let sep4 = createSeparator()
        contentView.addSubview(sep4)
        NSLayoutConstraint.activate([
            sep4.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 16),
            sep4.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            sep4.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            sep4.heightAnchor.constraint(equalToConstant: 1)
        ])
        lastView = sep4

        // Device Linking
        let linkHeader = createSectionHeader("Device Linking")
        contentView.addSubview(linkHeader)
        NSLayoutConstraint.activate([
            linkHeader.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 16),
            linkHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding)
        ])
        lastView = linkHeader

        let linkSteps = """
When you have the same device in both HomeKit and a plugin (like Govee), you can link them together so they're treated as one device.

1. Go to the Devices tab
2. Tap the (i) button on any device
3. Select "Link Device..."
4. Choose the corresponding device from another source

Linked devices use the most capable source automatically (plugins usually have more features than HomeKit).
"""
        let linkDesc = createDescription(linkSteps)
        contentView.addSubview(linkDesc)
        NSLayoutConstraint.activate([
            linkDesc.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 8),
            linkDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            linkDesc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding)
        ])
        lastView = linkDesc

        // Separator
        let sep5 = createSeparator()
        contentView.addSubview(sep5)
        NSLayoutConstraint.activate([
            sep5.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 16),
            sep5.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            sep5.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            sep5.heightAnchor.constraint(equalToConstant: 1)
        ])
        lastView = sep5

        // App Settings Section
        let appSettingsHeader = createSectionHeader("App Settings")
        contentView.addSubview(appSettingsHeader)
        NSLayoutConstraint.activate([
            appSettingsHeader.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 16),
            appSettingsHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding)
        ])
        lastView = appSettingsHeader

        // Menu bar toggle
        let menuBarRow = createSettingRow(title: "Show Menu Bar Icon", isOn: SettingsManager.shared.showMenuBarIcon, action: #selector(menuBarSwitchChanged(_:)))
        contentView.addSubview(menuBarRow)
        NSLayoutConstraint.activate([
            menuBarRow.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 12),
            menuBarRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            menuBarRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            menuBarRow.heightAnchor.constraint(equalToConstant: 44)
        ])
        lastView = menuBarRow
        menuBarSwitch = menuBarRow.subviews.compactMap { $0 as? UISwitch }.first

        // Dock toggle
        let dockRow = createSettingRow(title: "Show Dock Icon", isOn: SettingsManager.shared.showDockIcon, action: #selector(dockSwitchChanged(_:)))
        contentView.addSubview(dockRow)
        NSLayoutConstraint.activate([
            dockRow.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 8),
            dockRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            dockRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            dockRow.heightAnchor.constraint(equalToConstant: 44)
        ])
        lastView = dockRow
        dockSwitch = dockRow.subviews.compactMap { $0 as? UISwitch }.first

        // Settings note
        let settingsNote = UILabel()
        settingsNote.text = "Note: At least one must be enabled."
        settingsNote.font = .systemFont(ofSize: 12)
        settingsNote.textColor = .secondaryLabel
        settingsNote.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(settingsNote)
        NSLayoutConstraint.activate([
            settingsNote.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 8),
            settingsNote.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding)
        ])
        lastView = settingsNote

        // Login items button
        let loginButton = UIButton(type: .system)
        loginButton.setTitle("Open Login Items Settings...", for: .normal)
        loginButton.addTarget(self, action: #selector(openLoginItems), for: .touchUpInside)
        loginButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(loginButton)
        NSLayoutConstraint.activate([
            loginButton.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: 12),
            loginButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            loginButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding)
        ])

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    private func createSectionHeader(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .boldSystemFont(ofSize: 18)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func createDescription(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func createCodeView(_ code: String) -> UITextView {
        let textView = UITextView()
        textView.text = code
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        textView.textColor = UIColor(red: 0.6, green: 0.9, blue: 0.6, alpha: 1.0)
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.layer.cornerRadius = 8
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }

    private func createSeparator() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    @objc private func copyConfig() {
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

        let alert = UIAlertController(title: "Copied", message: "MCP configuration copied to clipboard", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func createSettingRow(title: String, isOn: Bool, action: Selector) -> UIView {
        let row = UIView()
        row.backgroundColor = .secondarySystemGroupedBackground
        row.layer.cornerRadius = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(self, action: action, for: .valueChanged)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(toggle)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),

            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16)
        ])

        return row
    }

    @objc private func menuBarSwitchChanged(_ sender: UISwitch) {
        if !sender.isOn && !(dockSwitch?.isOn ?? true) {
            sender.isOn = true
            return
        }
        SettingsManager.shared.showMenuBarIcon = sender.isOn
        #if targetEnvironment(macCatalyst)
        MenuBarManager.shared.updateVisibility()
        #endif
    }

    @objc private func dockSwitchChanged(_ sender: UISwitch) {
        if !sender.isOn && !(menuBarSwitch?.isOn ?? true) {
            sender.isOn = true
            return
        }
        SettingsManager.shared.showDockIcon = sender.isOn
        #if targetEnvironment(macCatalyst)
        MenuBarManager.shared.updateDockVisibility()
        #endif
    }

    @objc private func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Log View Controller

class LogViewController: UIViewController {
    private var textView: UITextView!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Log"
        view.backgroundColor = .systemBackground
        setupUI()

        NotificationCenter.default.addObserver(self, selector: #selector(updateLog), name: .logUpdated, object: nil)
        updateLog()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateLog()
    }

    private func setupUI() {
        textView = UITextView()
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        textView.textColor = .white
        textView.isEditable = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        let clearButton = UIButton(type: .system)
        clearButton.setTitle("Clear Log", for: .normal)
        clearButton.addTarget(self, action: #selector(clearLog), for: .touchUpInside)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = UIToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        let flexSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let clearItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearLog))
        let scrollItem = UIBarButtonItem(title: "Scroll to Bottom", style: .plain, target: self, action: #selector(scrollToBottom))
        toolbar.items = [flexSpace, clearItem, flexSpace, scrollItem, flexSpace]

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            textView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    @objc private func updateLog() {
        let entries = ActivityLog.shared.getEntries()
        textView.text = entries.joined(separator: "\n")
    }

    @objc private func clearLog() {
        textView.text = ""
    }

    @objc private func scrollToBottom() {
        if !textView.text.isEmpty {
            let range = NSRange(location: textView.text.count - 1, length: 1)
            textView.scrollRangeToVisible(range)
        }
    }
}

// MARK: - Main Split Controller (Finder-style sidebar)

class MainSplitController: UISplitViewController {

    enum SidebarItem: String, CaseIterable {
        case status = "Status"
        case devices = "Devices"
        case plugins = "Plugins"
        case mcpPost = "MCPPost"
        case settings = "Settings"
        case log = "Log"

        var icon: UIImage? {
            switch self {
            case .status: return UIImage(systemName: "house.fill")
            case .devices: return UIImage(systemName: "lightbulb.fill")
            case .plugins: return UIImage(systemName: "puzzlepiece.extension.fill")
            case .mcpPost: return UIImage(systemName: "arrow.up.circle.fill")
            case .settings: return UIImage(systemName: "gearshape.fill")
            case .log: return UIImage(systemName: "doc.text.fill")
            }
        }
    }

    private var sidebarVC: SidebarCollectionViewController!
    var selectedIndex: Int = 0

    init() {
        super.init(style: .doubleColumn)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Configure for Mac Catalyst native sidebar
        primaryBackgroundStyle = .sidebar
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile

        // Column widths
        preferredPrimaryColumnWidthFraction = 0.25
        minimumPrimaryColumnWidth = 200
        maximumPrimaryColumnWidth = 280

        // Create sidebar with collection view (native sidebar style)
        sidebarVC = SidebarCollectionViewController { [weak self] item in
            self?.showDetailViewController(for: item)
        }
        setViewController(sidebarVC, for: .primary)

        // Show initial detail
        showDetailViewController(for: .status)
    }

    private func showDetailViewController(for item: SidebarItem) {
        selectedIndex = SidebarItem.allCases.firstIndex(of: item) ?? 0

        let viewController: UIViewController
        switch item {
        case .status:
            viewController = StatusViewController()
        case .devices:
            viewController = DevicesViewController()
        case .plugins:
            let pluginsVC = PluginsViewController()
            let navController = UINavigationController(rootViewController: pluginsVC)
            viewController = navController
        case .mcpPost:
            viewController = MCPPostViewController()
        case .settings:
            viewController = SetupViewController()
        case .log:
            viewController = LogViewController()
        }

        setViewController(viewController, for: .secondary)
    }

    func selectItem(_ item: SidebarItem) {
        sidebarVC.selectItem(item)
        showDetailViewController(for: item)
    }
}

// Native sidebar using UICollectionView with .sidebar appearance
class SidebarCollectionViewController: UIViewController {
    typealias SelectionHandler = (MainSplitController.SidebarItem) -> Void

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, MainSplitController.SidebarItem>!
    private let selectionHandler: SelectionHandler

    init(selectionHandler: @escaping SelectionHandler) {
        self.selectionHandler = selectionHandler
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
        applyInitialSnapshot()

        // Select first item by default
        DispatchQueue.main.async {
            let indexPath = IndexPath(item: 0, section: 0)
            self.collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { _, layoutEnvironment in
            var config = UICollectionLayoutListConfiguration(appearance: .sidebar)
            config.showsSeparators = false
            config.headerMode = .none
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: layoutEnvironment)
        }

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, MainSplitController.SidebarItem> { cell, indexPath, item in
            var config = cell.defaultContentConfiguration()
            config.text = item.rawValue
            config.image = item.icon
            cell.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource<Int, MainSplitController.SidebarItem>(collectionView: collectionView) { collectionView, indexPath, item in
            return collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
    }

    private func applyInitialSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, MainSplitController.SidebarItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(MainSplitController.SidebarItem.allCases, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func selectItem(_ item: MainSplitController.SidebarItem) {
        guard let index = MainSplitController.SidebarItem.allCases.firstIndex(of: item) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
    }
}

extension SidebarCollectionViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        selectionHandler(item)
    }
}

// Legacy alias for compatibility
typealias MainTabController = MainSplitController

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

        // Use specialized config for Scrypted (includes MQTT settings)
        if plugin.identifier == "scrypted" {
            let configVC = ScryptedConfigViewController()
            navigationController?.pushViewController(configVC, animated: true)
        } else {
            let configVC = PluginConfigViewController(plugin: plugin)
            navigationController?.pushViewController(configVC, animated: true)
        }
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

// MARK: - Scrypted Config View Controller (with MQTT)

/// Specialized configuration view for Scrypted with MQTT integration
/// Provides a simple, user-friendly setup experience
class ScryptedConfigViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case mqttConnection = 0
        case mqttStatus
        case actions
    }

    private var mqttHostField: UITextField!
    private var mqttPortField: UITextField!
    private var mqttUsernameField: UITextField!
    private var mqttPasswordField: UITextField!
    private var mqttEnabledSwitch: UISwitch!

    override init(style: UITableView.Style = .insetGrouped) {
        super.init(style: style)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scrypted NVR"

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Save", style: .done, target: self, action: #selector(save))
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .mqttConnection: return 5  // Enable, Host, Port, Username, Password
        case .mqttStatus: return 1
        case .actions: return 2  // Test Connection, Clear Settings
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .mqttConnection: return "MQTT Connection (Recommended)"
        case .mqttStatus: return "Status"
        case .actions: return "Actions"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .mqttConnection:
            return "MQTT provides real-time events from all Scrypted cameras and sensors automatically. Install the MQTT plugin in Scrypted, then enter your MQTT broker details here."
        case .mqttStatus:
            return nil
        case .actions:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .mqttConnection:
            return createConnectionCell(for: indexPath.row)
        case .mqttStatus:
            return createStatusCell()
        case .actions:
            return createActionCell(for: indexPath.row)
        }
    }

    private func createConnectionCell(for row: Int) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        switch row {
        case 0: // Enable MQTT
            var config = cell.defaultContentConfiguration()
            config.text = "Enable MQTT"
            cell.contentConfiguration = config

            mqttEnabledSwitch = UISwitch()
            mqttEnabledSwitch.isOn = ScryptedMQTTManager.shared.isEnabled
            mqttEnabledSwitch.addTarget(self, action: #selector(mqttToggled), for: .valueChanged)
            cell.accessoryView = mqttEnabledSwitch

        case 1: // Host
            let (label, textField) = createLabeledTextField(
                label: "MQTT Host",
                placeholder: "192.168.1.100",
                text: ScryptedMQTTManager.shared.host ?? ""
            )
            mqttHostField = textField
            cell.contentView.addSubview(label)
            cell.contentView.addSubview(textField)
            setupLabeledTextFieldConstraints(label: label, textField: textField, in: cell)

        case 2: // Port
            let (label, textField) = createLabeledTextField(
                label: "Port",
                placeholder: "1883",
                text: String(ScryptedMQTTManager.shared.port)
            )
            textField.keyboardType = .numberPad
            mqttPortField = textField
            cell.contentView.addSubview(label)
            cell.contentView.addSubview(textField)
            setupLabeledTextFieldConstraints(label: label, textField: textField, in: cell)

        case 3: // Username
            let (label, textField) = createLabeledTextField(
                label: "Username",
                placeholder: "Optional",
                text: ScryptedMQTTManager.shared.username ?? ""
            )
            mqttUsernameField = textField
            cell.contentView.addSubview(label)
            cell.contentView.addSubview(textField)
            setupLabeledTextFieldConstraints(label: label, textField: textField, in: cell)

        case 4: // Password
            let (label, textField) = createLabeledTextField(
                label: "Password",
                placeholder: "Optional",
                text: ScryptedMQTTManager.shared.password ?? "",
                isSecure: true
            )
            mqttPasswordField = textField
            cell.contentView.addSubview(label)
            cell.contentView.addSubview(textField)
            setupLabeledTextFieldConstraints(label: label, textField: textField, in: cell)

        default:
            break
        }

        return cell
    }

    private func createStatusCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none

        var config = cell.defaultContentConfiguration()

        if ScryptedMQTTManager.shared.isConnected {
            config.text = "Connected"
            config.textProperties.color = .systemGreen
            config.image = UIImage(systemName: "checkmark.circle.fill")
            config.imageProperties.tintColor = .systemGreen

            let cameras = ScryptedMQTTManager.shared.getDiscoveredCameras()
            let sensors = ScryptedMQTTManager.shared.getDiscoveredSensors()
            config.secondaryText = "\(cameras.count) cameras, \(sensors.count) sensors discovered"
        } else if ScryptedMQTTManager.shared.isEnabled && ScryptedMQTTManager.shared.isConfigured {
            config.text = "Disconnected"
            config.textProperties.color = .systemOrange
            config.image = UIImage(systemName: "exclamationmark.circle.fill")
            config.imageProperties.tintColor = .systemOrange
            config.secondaryText = "Tap 'Test Connection' to connect"
        } else if !ScryptedMQTTManager.shared.isConfigured {
            config.text = "Not Configured"
            config.textProperties.color = .secondaryLabel
            config.image = UIImage(systemName: "circle")
            config.imageProperties.tintColor = .secondaryLabel
            config.secondaryText = "Enter MQTT host to get started"
        } else {
            config.text = "Disabled"
            config.textProperties.color = .secondaryLabel
            config.image = UIImage(systemName: "circle")
            config.imageProperties.tintColor = .secondaryLabel
            config.secondaryText = "Enable MQTT to receive events"
        }

        cell.contentConfiguration = config
        return cell
    }

    private func createActionCell(for row: Int) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var config = cell.defaultContentConfiguration()
        config.textProperties.alignment = .center

        if row == 0 {
            config.text = "Test Connection"
            config.textProperties.color = .systemBlue
        } else {
            config.text = "Clear Settings"
            config.textProperties.color = .systemRed
        }

        cell.contentConfiguration = config
        return cell
    }

    private func createLabeledTextField(label: String, placeholder: String, text: String, isSecure: Bool = false) -> (UILabel, UITextField) {
        let labelView = UILabel()
        labelView.text = label
        labelView.font = .systemFont(ofSize: 15)
        labelView.translatesAutoresizingMaskIntoConstraints = false

        let textField = UITextField()
        textField.placeholder = placeholder
        textField.text = text
        textField.isSecureTextEntry = isSecure
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.textAlignment = .right
        textField.font = .systemFont(ofSize: 15)
        textField.translatesAutoresizingMaskIntoConstraints = false

        return (labelView, textField)
    }

    private func setupLabeledTextFieldConstraints(label: UILabel, textField: UITextField, in cell: UITableViewCell) {
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 100),

            textField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            textField.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            textField.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard indexPath.section == Section.actions.rawValue else { return }

        if indexPath.row == 0 {
            testConnection()
        } else {
            clearSettings()
        }
    }

    @objc private func mqttToggled(_ sender: UISwitch) {
        ScryptedMQTTManager.shared.isEnabled = sender.isOn
        if sender.isOn && ScryptedMQTTManager.shared.isConfigured {
            ScryptedMQTTManager.shared.connect()
        } else if !sender.isOn {
            ScryptedMQTTManager.shared.disconnect()
        }
        tableView.reloadSections(IndexSet(integer: Section.mqttStatus.rawValue), with: .automatic)
    }

    @objc private func save() {
        // Save MQTT settings
        let host = mqttHostField?.text?.trimmingCharacters(in: .whitespaces) ?? ""
        let portText = mqttPortField?.text ?? "1883"
        let port = Int(portText) ?? 1883
        let username = mqttUsernameField?.text?.trimmingCharacters(in: .whitespaces)
        let password = mqttPasswordField?.text

        ScryptedMQTTManager.shared.host = host.isEmpty ? nil : host
        ScryptedMQTTManager.shared.port = port
        ScryptedMQTTManager.shared.username = (username?.isEmpty ?? true) ? nil : username
        ScryptedMQTTManager.shared.password = (password?.isEmpty ?? true) ? nil : password

        log("Scrypted MQTT settings saved")

        // If enabled and configured, connect
        if ScryptedMQTTManager.shared.isEnabled && ScryptedMQTTManager.shared.isConfigured {
            ScryptedMQTTManager.shared.disconnect()
            ScryptedMQTTManager.shared.connect()
        }

        navigationController?.popViewController(animated: true)
    }

    private func testConnection() {
        // Save current values first
        let host = mqttHostField?.text?.trimmingCharacters(in: .whitespaces) ?? ""
        let portText = mqttPortField?.text ?? "1883"
        let port = Int(portText) ?? 1883
        let username = mqttUsernameField?.text?.trimmingCharacters(in: .whitespaces)
        let password = mqttPasswordField?.text

        guard !host.isEmpty else {
            showAlert(title: "Missing Host", message: "Please enter an MQTT host address.")
            return
        }

        ScryptedMQTTManager.shared.host = host
        ScryptedMQTTManager.shared.port = port
        ScryptedMQTTManager.shared.username = (username?.isEmpty ?? true) ? nil : username
        ScryptedMQTTManager.shared.password = (password?.isEmpty ?? true) ? nil : password
        ScryptedMQTTManager.shared.isEnabled = true
        mqttEnabledSwitch?.isOn = true

        // Show loading
        let loadingAlert = UIAlertController(title: nil, message: "Connecting...", preferredStyle: .alert)
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        loadingAlert.view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: loadingAlert.view.centerXAnchor),
            indicator.bottomAnchor.constraint(equalTo: loadingAlert.view.bottomAnchor, constant: -20)
        ])
        present(loadingAlert, animated: true)

        // Disconnect first if connected
        ScryptedMQTTManager.shared.disconnect()

        // Try to connect
        ScryptedMQTTManager.shared.connect()

        // Check result after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            loadingAlert.dismiss(animated: true) {
                if ScryptedMQTTManager.shared.isConnected {
                    self?.showAlert(title: "Success", message: "Connected to MQTT broker!")
                } else {
                    self?.showAlert(title: "Connection Failed", message: "Could not connect to \(host):\(port). Check the host and port are correct.")
                }
                self?.tableView.reloadData()
            }
        }
    }

    private func clearSettings() {
        let alert = UIAlertController(
            title: "Clear Settings?",
            message: "This will remove all Scrypted MQTT settings.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            ScryptedMQTTManager.shared.disconnect()
            ScryptedMQTTManager.shared.host = nil
            ScryptedMQTTManager.shared.port = 1883
            ScryptedMQTTManager.shared.username = nil
            ScryptedMQTTManager.shared.password = nil
            ScryptedMQTTManager.shared.isEnabled = false

            self?.mqttHostField?.text = ""
            self?.mqttPortField?.text = "1883"
            self?.mqttUsernameField?.text = ""
            self?.mqttPasswordField?.text = ""
            self?.mqttEnabledSwitch?.isOn = false

            self?.tableView.reloadData()
            log("Scrypted MQTT settings cleared")
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Devices View Controller

class DevicesViewController: UITableViewController {
    private var allDevices: [UnifiedDevice] = []
    private var devicesByRoom: [String: [UnifiedDevice]] = [:]
    private var rooms: [String] = []

    // Color scheme for each source
    private func colorForSource(_ source: DeviceSource) -> UIColor {
        switch source {
        case .homeKit:
            return .systemBlue
        case .govee:
            return .systemGreen
        case .scrypted:
            return .systemPurple
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Devices"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain,
            target: self,
            action: #selector(refresh)
        )

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DeviceCell")

        // Add legend in footer
        let footerLabel = UILabel()
        footerLabel.text = "🔵 HomeKit  🟢 Govee  🟣 Scrypted"
        footerLabel.textAlignment = .center
        footerLabel.textColor = .secondaryLabel
        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 40)
        tableView.tableFooterView = footerLabel
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
            allDevices = devices

            // Filter linked devices to avoid duplicates
            let filteredDevices = DeviceLinkManager.shared.filterLinkedDevices(devices)

            // Normalize room names for grouping (case-insensitive, trimmed)
            // This groups "Living Room" from HomeKit with "Living Room" from Govee
            devicesByRoom = [:]
            var roomNameMapping: [String: String] = [:] // lowercased -> original

            for device in filteredDevices {
                let roomName = device.room ?? "Unknown Room"
                let normalizedRoom = roomName.trimmingCharacters(in: .whitespaces).lowercased()

                // Use the first encountered room name casing
                if roomNameMapping[normalizedRoom] == nil {
                    roomNameMapping[normalizedRoom] = roomName
                }

                let displayRoom = roomNameMapping[normalizedRoom]!
                if devicesByRoom[displayRoom] == nil {
                    devicesByRoom[displayRoom] = []
                }
                devicesByRoom[displayRoom]!.append(device)
            }

            // Sort devices within each room by source then name
            for room in devicesByRoom.keys {
                devicesByRoom[room]?.sort { d1, d2 in
                    if d1.source != d2.source {
                        // Order: HomeKit, Govee, Scrypted
                        let order: [DeviceSource] = [.homeKit, .govee, .scrypted]
                        let i1 = order.firstIndex(of: d1.source) ?? 0
                        let i2 = order.firstIndex(of: d2.source) ?? 0
                        return i1 < i2
                    }
                    return d1.name < d2.name
                }
            }

            // Sort rooms alphabetically, but put "Unknown Room" at the end
            rooms = devicesByRoom.keys.sorted { r1, r2 in
                if r1 == "Unknown Room" { return false }
                if r2 == "Unknown Room" { return true }
                return r1.lowercased() < r2.lowercased()
            }

            await MainActor.run {
                tableView.reloadData()
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        rooms.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let room = rooms[section]
        let devices = devicesByRoom[room] ?? []

        // Count devices by source for the header
        var sourceCounts: [DeviceSource: Int] = [:]
        for device in devices {
            sourceCounts[device.source, default: 0] += 1
        }

        // Build source summary
        var parts: [String] = []
        if let hk = sourceCounts[.homeKit], hk > 0 { parts.append("🔵\(hk)") }
        if let gov = sourceCounts[.govee], gov > 0 { parts.append("🟢\(gov)") }
        if let scr = sourceCounts[.scrypted], scr > 0 { parts.append("🟣\(scr)") }

        return "\(room) (\(devices.count)) \(parts.joined(separator: " "))"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        devicesByRoom[rooms[section]]?.count ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceCell", for: indexPath)
        let room = rooms[indexPath.section]
        let device = devicesByRoom[room]![indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = device.name

        // Show source and type, plus linked indicator if linked
        var secondaryParts = [device.source.rawValue, device.type]
        if DeviceLinkManager.shared.isLinked(deviceId: device.id) {
            secondaryParts.append("🔗 Linked")
        }
        config.secondaryText = secondaryParts.joined(separator: " · ")
        config.textProperties.color = device.isReachable ? .label : .tertiaryLabel
        config.secondaryTextProperties.color = device.isReachable ? .secondaryLabel : .tertiaryLabel

        // Icon with color based on source
        let icon = deviceIcon(for: device.type)
        config.image = UIImage(systemName: icon)

        // Color code by source - dim if not reachable
        let sourceColor = colorForSource(device.source)
        config.imageProperties.tintColor = device.isReachable ? sourceColor : sourceColor.withAlphaComponent(0.3)

        cell.contentConfiguration = config
        cell.accessoryType = .detailButton
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        let room = rooms[indexPath.section]
        let device = devicesByRoom[room]![indexPath.row]
        showDeviceOptions(device: device)
    }

    private func showDeviceOptions(device: UnifiedDevice) {
        let alert = UIAlertController(title: device.name, message: "\(device.source.rawValue) - \(device.type)", preferredStyle: .actionSheet)

        if DeviceLinkManager.shared.isLinked(deviceId: device.id) {
            alert.addAction(UIAlertAction(title: "Unlink Device", style: .destructive) { [weak self] _ in
                DeviceLinkManager.shared.unlinkDevice(deviceId: device.id)
                self?.loadDevices()
            })
        } else {
            alert.addAction(UIAlertAction(title: "Link Device...", style: .default) { [weak self] _ in
                self?.showLinkDeviceSheet(for: device)
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }

        present(alert, animated: true)
    }

    private func showLinkDeviceSheet(for device: UnifiedDevice) {
        // Find devices from other sources that could be linked
        let otherDevices = allDevices.filter { other in
            other.source != device.source &&
            !DeviceLinkManager.shared.isLinked(deviceId: other.id)
        }.sorted { $0.name < $1.name }

        if otherDevices.isEmpty {
            let alert = UIAlertController(
                title: "No Devices Available",
                message: "There are no devices from other sources to link with.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let alert = UIAlertController(
            title: "Link \(device.name)",
            message: "Select a device to link with. Linked devices are treated as one, using the most capable source.",
            preferredStyle: .actionSheet
        )

        for other in otherDevices {
            let title = "\(other.name) (\(other.source.rawValue))"
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                DeviceLinkManager.shared.linkDevices(primary: device, linked: other)
                self?.loadDevices()
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }

        present(alert, animated: true)
    }

    private func deviceIcon(for type: String) -> String {
        switch type {
        case "light": return "lightbulb.fill"
        case "switch": return "switch.2"
        case "outlet": return "poweroutlet.type.b.fill"
        case "fan": return "fan.fill"
        case "lock": return "lock.fill"
        case "garage_door": return "door.garage.closed"
        case "sensor": return "sensor.fill"
        case "thermostat": return "thermometer"
        case "hub": return "server.rack"
        case "curtain": return "blinds.vertical.closed"
        case "motion": return "figure.walk"
        case "contact": return "door.left.hand.open"
        case "camera": return "video.fill"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - MCPPost View Controller

class MCPPostViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let enabledSwitch = UISwitch()
    private let endpointTextField = UITextField()
    private let statusLabel = UILabel()
    private let deviceCountLabel = UILabel()
    private let eventTableView = UITableView(frame: .zero, style: .plain)

    private var recentEvents: [MCPPostManager.PostedEvent] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "MCPPost"
        view.backgroundColor = .systemBackground

        setupUI()
        loadSettings()
        loadEvents()

        NotificationCenter.default.addObserver(
            self, selector: #selector(eventsUpdated),
            name: .mcpPostEventReceived, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsUpdated),
            name: .mcpPostSettingsUpdated, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadEvents()
        updateStatus()
    }

    private func setupUI() {
        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        var yOffset: CGFloat = 20
        let padding: CGFloat = 20

        // Section: Enable switch
        let enableLabel = UILabel()
        enableLabel.text = "Enable Event Broadcasting"
        enableLabel.font = .systemFont(ofSize: 16, weight: .medium)
        enableLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(enableLabel)

        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false
        enabledSwitch.addTarget(self, action: #selector(enabledChanged), for: .valueChanged)
        contentView.addSubview(enabledSwitch)

        NSLayoutConstraint.activate([
            enableLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: yOffset),
            enableLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            enabledSwitch.centerYAnchor.constraint(equalTo: enableLabel.centerYAnchor),
            enabledSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding)
        ])
        yOffset += 50

        // Section: Endpoint URL
        let urlLabel = UILabel()
        urlLabel.text = "Endpoint URL"
        urlLabel.font = .systemFont(ofSize: 14, weight: .medium)
        urlLabel.textColor = .secondaryLabel
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(urlLabel)

        endpointTextField.placeholder = "https://your-server.com/api/events"
        endpointTextField.borderStyle = .roundedRect
        endpointTextField.autocapitalizationType = .none
        endpointTextField.autocorrectionType = .no
        endpointTextField.keyboardType = .URL
        endpointTextField.clearButtonMode = .whileEditing
        endpointTextField.returnKeyType = .done
        endpointTextField.delegate = self
        endpointTextField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(endpointTextField)

        NSLayoutConstraint.activate([
            urlLabel.topAnchor.constraint(equalTo: enableLabel.bottomAnchor, constant: 20),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            endpointTextField.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 8),
            endpointTextField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            endpointTextField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            endpointTextField.heightAnchor.constraint(equalToConstant: 44)
        ])
        yOffset += 90

        // Status label
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: endpointTextField.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding)
        ])

        // Device count label
        deviceCountLabel.font = .systemFont(ofSize: 14, weight: .medium)
        deviceCountLabel.textColor = .label
        deviceCountLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(deviceCountLabel)

        NSLayoutConstraint.activate([
            deviceCountLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            deviceCountLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding)
        ])

        // Test button
        let testButton = UIButton(type: .system)
        testButton.setTitle("Test Endpoint", for: .normal)
        testButton.addTarget(self, action: #selector(testEndpoint), for: .touchUpInside)
        testButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(testButton)

        NSLayoutConstraint.activate([
            testButton.centerYAnchor.constraint(equalTo: deviceCountLabel.centerYAnchor),
            testButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding)
        ])

        // Recent events section
        let eventsLabel = UILabel()
        eventsLabel.text = "Recent Events"
        eventsLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        eventsLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(eventsLabel)

        let clearButton = UIButton(type: .system)
        clearButton.setTitle("Clear", for: .normal)
        clearButton.addTarget(self, action: #selector(clearEvents), for: .touchUpInside)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(clearButton)

        NSLayoutConstraint.activate([
            eventsLabel.topAnchor.constraint(equalTo: deviceCountLabel.bottomAnchor, constant: 30),
            eventsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            clearButton.centerYAnchor.constraint(equalTo: eventsLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding)
        ])

        // Event table view
        eventTableView.translatesAutoresizingMaskIntoConstraints = false
        eventTableView.register(UITableViewCell.self, forCellReuseIdentifier: "EventCell")
        eventTableView.dataSource = self
        eventTableView.delegate = self
        eventTableView.isScrollEnabled = false
        eventTableView.layer.cornerRadius = 10
        eventTableView.layer.borderWidth = 1
        eventTableView.layer.borderColor = UIColor.separator.cgColor
        contentView.addSubview(eventTableView)

        NSLayoutConstraint.activate([
            eventTableView.topAnchor.constraint(equalTo: eventsLabel.bottomAnchor, constant: 10),
            eventTableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            eventTableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            eventTableView.heightAnchor.constraint(equalToConstant: 250)
        ])

        // Integration Guide Section
        let guideLabel = UILabel()
        guideLabel.text = "Integration Guide"
        guideLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        guideLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(guideLabel)

        let guideText = """
Your server should accept POST requests with JSON payloads:

POST /your-endpoint
Content-Type: application/json

{
  "event_id": "uuid",
  "event_type": "motion|contact|doorbell|occupancy",
  "source": "HomeKit",
  "timestamp": "2024-01-18T21:00:00Z",
  "sensor": {
    "name": "Front Door Motion",
    "id": "uuid",
    "room": "Hallway",
    "home": "Home"
  },
  "data": {
    "detected": true,
    "state": "open"
  }
}

Example Python Flask endpoint:

from flask import Flask, request
app = Flask(__name__)

@app.route('/events', methods=['POST'])
def receive_event():
    event = request.json
    print(f"Event: {event['event_type']} from {event['sensor']['name']}")
    # Process event (turn on lights, send notification, etc.)
    return {'status': 'ok'}, 200
"""
        let guideTextView = UITextView()
        guideTextView.text = guideText
        guideTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        guideTextView.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        guideTextView.textColor = UIColor(red: 0.6, green: 0.9, blue: 0.6, alpha: 1.0)
        guideTextView.isEditable = false
        guideTextView.isScrollEnabled = true
        guideTextView.layer.cornerRadius = 8
        guideTextView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(guideTextView)

        NSLayoutConstraint.activate([
            guideLabel.topAnchor.constraint(equalTo: eventTableView.bottomAnchor, constant: 24),
            guideLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            guideTextView.topAnchor.constraint(equalTo: guideLabel.bottomAnchor, constant: 10),
            guideTextView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            guideTextView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            guideTextView.heightAnchor.constraint(equalToConstant: 400),
            guideTextView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        // Add tap gesture to dismiss keyboard
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)
    }

    private func loadSettings() {
        enabledSwitch.isOn = MCPPostManager.shared.isEnabled
        endpointTextField.text = MCPPostManager.shared.endpointURL
        updateStatus()
    }

    private func loadEvents() {
        recentEvents = MCPPostManager.shared.getRecentEvents()
        eventTableView.reloadData()
    }

    private func updateStatus() {
        let devices = MCPPostManager.shared.listEventProducingDevices()
        deviceCountLabel.text = "Monitoring \(devices.count) event sources"

        if MCPPostManager.shared.isEnabled {
            if MCPPostManager.shared.isConfigured {
                statusLabel.text = "Events will be POSTed to the configured endpoint"
                statusLabel.textColor = .systemGreen
            } else {
                statusLabel.text = "Please enter a valid endpoint URL"
                statusLabel.textColor = .systemOrange
            }
        } else {
            statusLabel.text = "Event broadcasting is disabled"
            statusLabel.textColor = .secondaryLabel
        }
    }

    @objc private func enabledChanged() {
        MCPPostManager.shared.isEnabled = enabledSwitch.isOn
        updateStatus()
    }

    @objc private func eventsUpdated() {
        loadEvents()
    }

    @objc private func settingsUpdated() {
        loadSettings()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
        saveEndpoint()
    }

    @objc private func clearEvents() {
        MCPPostManager.shared.clearRecentEvents()
    }

    @objc private func testEndpoint() {
        guard let urlString = endpointTextField.text, !urlString.isEmpty,
              let url = URL(string: urlString) else {
            let alert = UIAlertController(title: "Invalid URL", message: "Please enter a valid endpoint URL", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        // Send test event
        let testPayload: [String: Any] = [
            "event_id": UUID().uuidString,
            "event_type": "test",
            "source": "HomeMCPBridge",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sensor": [
                "name": "Test",
                "id": "test-id",
                "room": "Test Room",
                "home": "Test Home"
            ],
            "data": [
                "message": "This is a test event from HomeMCPBridge"
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: testPayload)

        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    let alert = UIAlertController(title: "Test Failed", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(alert, animated: true)
                } else if let httpResponse = response as? HTTPURLResponse {
                    let success = httpResponse.statusCode >= 200 && httpResponse.statusCode < 300
                    let alert = UIAlertController(
                        title: success ? "Test Successful" : "Test Failed",
                        message: success ? "Endpoint responded with HTTP \(httpResponse.statusCode)" : "Endpoint responded with HTTP \(httpResponse.statusCode)",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(alert, animated: true)
                }
            }
        }
        task.resume()
    }

    private func saveEndpoint() {
        MCPPostManager.shared.endpointURL = endpointTextField.text
        updateStatus()
    }
}

extension MCPPostViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        saveEndpoint()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        saveEndpoint()
    }
}

extension MCPPostViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(recentEvents.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "EventCell", for: indexPath)

        if recentEvents.isEmpty {
            var config = cell.defaultContentConfiguration()
            let devices = MCPPostManager.shared.listEventProducingDevices()
            if devices.count > 0 {
                config.text = "Waiting for events..."
                config.secondaryText = "Motion, contact, or doorbell events from your \(devices.count) sensors will appear here"
                config.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
                config.imageProperties.tintColor = .systemBlue
            } else {
                config.text = "No event sensors found"
                config.secondaryText = "Add motion, contact, or doorbell sensors to HomeKit"
                config.image = UIImage(systemName: "sensor.fill")
                config.imageProperties.tintColor = .tertiaryLabel
            }
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.selectionStyle = .none
        } else {
            let event = recentEvents[indexPath.row]
            var config = cell.defaultContentConfiguration()

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"
            let timeStr = timeFormatter.string(from: event.timestamp)

            let icon: String
            switch event.eventType {
            case "motion": icon = "figure.walk"
            case "occupancy": icon = "person.fill"
            case "doorbell": icon = "bell.fill"
            case "contact": icon = "door.left.hand.open"
            default: icon = "sensor.fill"
            }

            let statusIcon = event.postSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            let statusColor: UIColor = event.postSuccess ? .systemGreen : .systemRed

            config.text = "\(event.sensorName) - \(event.eventType)"
            config.secondaryText = "\(timeStr) | \(event.room)"
            config.image = UIImage(systemName: icon)

            let statusImage = UIImageView(image: UIImage(systemName: statusIcon))
            statusImage.tintColor = statusColor
            cell.accessoryView = statusImage

            cell.contentConfiguration = config
            cell.selectionStyle = .none
        }

        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        56
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

        // Note: Don't set activation policy here - AppDelegate.makeRegularApp() already did it
        // Setting it again could interfere with the app's state
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

    private func setActivationPolicy(regular: Bool) {
        guard let nsApp = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = nsApp.value(forKey: "sharedApplication") as? NSObject else { return }

        // 0 = NSApplicationActivationPolicyRegular (normal app with menu bar)
        // 1 = NSApplicationActivationPolicyAccessory (no dock icon, no menu bar)
        // 2 = NSApplicationActivationPolicyProhibited (background only)
        let policy = regular ? 0 : 1

        let selector = NSSelectorFromString("setActivationPolicy:")
        guard let method = class_getInstanceMethod(type(of: app), selector) else { return }

        typealias SetPolicyFunc = @convention(c) (AnyObject, Selector, Int) -> Void
        let imp = method_getImplementation(method)
        let setPolicy = unsafeBitCast(imp, to: SetPolicyFunc.self)
        setPolicy(app, selector, policy)
    }

    func setDockIconVisible(_ visible: Bool) {
        // Note: We always keep the app as a "regular" app so it appears in App Switcher
        // The dock icon visibility is controlled separately via NSApp.setActivationPolicy
        // However, macOS ties dock icon to activation policy, so we have limited options:
        // - Regular (0): Dock icon + menu bar + app switcher
        // - Accessory (1): No dock icon, menu bar only when frontmost, still in app switcher
        //
        // For now, we respect the user's choice but warn that hiding dock affects behavior
        if visible {
            setActivationPolicy(regular: true)
        } else {
            // Accessory mode: no dock icon but still appears in App Switcher (Cmd+Tab)
            // Menu bar only shows when app window is frontmost
            setActivationPolicy(regular: false)
        }
    }

    func activateApp() {
        guard let nsApp = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = nsApp.value(forKey: "sharedApplication") as? NSObject else { return }

        // Activate the app and bring to front
        let activateSelector = NSSelectorFromString("activateIgnoringOtherApps:")
        if app.responds(to: activateSelector) {
            app.perform(activateSelector, with: true)
        }
    }

    func unhideApp() {
        guard let nsApp = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = nsApp.value(forKey: "sharedApplication") as? NSObject else { return }

        // Unhide the application
        let unhideSelector = NSSelectorFromString("unhide:")
        if app.responds(to: unhideSelector) {
            app.perform(unhideSelector, with: nil)
        }
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

        // Create status bar icon if enabled
        if SettingsManager.shared.showMenuBarIcon {
            createStatusItem()
        }

        // Note: Don't call updateDockVisibility() here - AppDelegate already set the
        // activation policy. Only apply dock visibility changes when user toggles the setting.
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
        let statusItemSel = NSSelectorFromString("statusItemWithLength:")
        guard let item = statusBar.perform(statusItemSel, with: length)?.takeUnretainedValue() else { return }

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
        let addItemSel = NSSelectorFromString("addItem:")

        // Header item (disabled)
        if let headerItem = createMenuItem(title: "HomeMCPBridge", action: nil, keyEquivalent: "") {
            headerItem.setValue(false, forKey: "enabled")
            newMenu.perform(addItemSel, with: headerItem)
        }

        // Separator
        if let sep = (menuItemClass as AnyObject).perform(NSSelectorFromString("separatorItem"))?.takeUnretainedValue() {
            newMenu.perform(addItemSel, with: sep)
        }

        // Open item - tag 1
        if let openItem = createMenuItem(title: "Open", action: nil, keyEquivalent: "") {
            openItem.setValue(1, forKey: "tag")
            newMenu.perform(addItemSel, with: openItem)
        }

        // Copy Config item - tag 2
        if let copyItem = createMenuItem(title: "Copy MCP Config", action: nil, keyEquivalent: "") {
            copyItem.setValue(2, forKey: "tag")
            newMenu.perform(addItemSel, with: copyItem)
        }

        // Separator
        if let sep = (menuItemClass as AnyObject).perform(NSSelectorFromString("separatorItem"))?.takeUnretainedValue() {
            newMenu.perform(addItemSel, with: sep)
        }

        // Quit item - tag 3
        if let quitItem = createMenuItem(title: "Quit", action: nil, keyEquivalent: "q") {
            quitItem.setValue(3, forKey: "tag")
            newMenu.perform(addItemSel, with: quitItem)
        }

        item.setValue(newMenu, forKey: "menu")

        // Set up the menu actions with our runtime-created target
        setupMenuActions()
    }

    private func createMenuItem(title: String, action: Selector?, keyEquivalent: String) -> NSObject? {
        guard let itemClass = NSClassFromString("NSMenuItem") else { return nil }

        // Use alloc + init and then set properties
        guard let allocated = (itemClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject else { return nil }

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

        statusBar.perform(NSSelectorFromString("removeStatusItem:"), with: item)
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

        // Set window size constraints for sidebar layout
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 700, height: 550)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 1200, height: 900)

        // Set window title
        windowScene.title = "HomeMCPBridge"

        // Set up menu bar and status item
        MenuBarManager.shared.setup(windowScene: windowScene)

        // Build menu bar
        UIMenuSystem.main.setNeedsRebuild()

        // Activate the app so it becomes frontmost and shows menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AppKitBridge.shared.activateApp()
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Window was closed - update menu bar to show "Open" instead of "Show Window"
        MenuBarManager.shared.windowClosed()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        MenuBarManager.shared.windowOpened()
        // Ensure app is activated when window becomes active
        AppKitBridge.shared.activateApp()
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard builder.system == .main else { return }

        // Remove unwanted menus
        builder.remove(menu: .format)

        // === App Menu (HomeMCPBridge) ===
        // Add Preferences to app menu
        let preferencesAction = UIKeyCommand(
            title: "Settings…",
            image: UIImage(systemName: "gear"),
            action: #selector(openPreferences),
            input: ",",
            modifierFlags: .command
        )

        let aboutAction = UIAction(title: "About HomeMCPBridge", image: UIImage(systemName: "info.circle")) { _ in
            self.showAbout()
        }

        let appMenuItems = UIMenu(title: "", options: .displayInline, children: [aboutAction, preferencesAction])
        builder.insertSibling(appMenuItems, afterMenu: .about)

        // === File Menu ===
        let copyConfigAction = UIAction(
            title: "Copy MCP Configuration",
            image: UIImage(systemName: "doc.on.doc"),
            identifier: nil
        ) { _ in
            MenuBarManager.shared.doCopyConfig()
        }

        let exportLogAction = UIAction(
            title: "Export Log…",
            image: UIImage(systemName: "square.and.arrow.up"),
            identifier: nil
        ) { _ in
            self.exportLog()
        }

        let fileMenuItems = UIMenu(title: "", options: .displayInline, children: [copyConfigAction, exportLogAction])
        builder.insertChild(fileMenuItems, atStartOfMenu: .file)

        // === Edit Menu ===
        let openLoginItemsAction = UIAction(
            title: "Add to Login Items…",
            image: UIImage(systemName: "person.badge.plus"),
            identifier: nil
        ) { _ in
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                UIApplication.shared.open(url)
            }
        }

        let editMenuItems = UIMenu(title: "", options: .displayInline, children: [openLoginItemsAction])
        builder.insertChild(editMenuItems, atEndOfMenu: .edit)

        // === View Menu ===
        let toggleStatusBarAction = UIAction(
            title: SettingsManager.shared.showMenuBarIcon ? "Hide Status Bar Icon" : "Show Status Bar Icon",
            image: UIImage(systemName: "menubar.rectangle"),
            identifier: nil
        ) { _ in
            SettingsManager.shared.showMenuBarIcon.toggle()
            MenuBarManager.shared.updateVisibility()
            UIMenuSystem.main.setNeedsRebuild()
        }

        let toggleDockIconAction = UIAction(
            title: SettingsManager.shared.showDockIcon ? "Hide Dock Icon" : "Show Dock Icon",
            image: UIImage(systemName: "dock.rectangle"),
            identifier: nil
        ) { _ in
            SettingsManager.shared.showDockIcon.toggle()
            MenuBarManager.shared.updateDockVisibility()
            UIMenuSystem.main.setNeedsRebuild()
        }

        let viewMenuItems = UIMenu(title: "", options: .displayInline, children: [toggleStatusBarAction, toggleDockIconAction])
        builder.insertChild(viewMenuItems, atEndOfMenu: .view)

        // === Help Menu ===
        let helpAction = UIAction(title: "HomeMCPBridge Help", image: UIImage(systemName: "questionmark.circle")) { _ in
            if let url = URL(string: "https://github.com/coalsi/HomeMCPBridge") {
                UIApplication.shared.open(url)
            }
        }

        let helpMenuItems = UIMenu(title: "", options: .displayInline, children: [helpAction])
        builder.replaceChildren(ofMenu: .help) { _ in [helpMenuItems] }
    }

    @objc func openPreferences() {
        // Switch to Status tab (which has settings)
        if let tabController = window?.rootViewController as? MainTabController {
            tabController.selectedIndex = 0  // Status tab
        }
        window?.makeKeyAndVisible()
        AppKitBridge.shared.activateApp()
    }

    func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        let alert = UIAlertController(
            title: "HomeMCPBridge",
            message: "Version \(version) (\(build))\n\nNative macOS HomeKit integration for AI assistants via the Model Context Protocol.\n\n© 2024 HomeMCPBridge",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        window?.rootViewController?.present(alert, animated: true)
    }

    func exportLog() {
        let logEntries = ActivityLog.shared.getEntries()
        let logContent = logEntries.joined(separator: "\n")
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("HomeMCPBridge.log")
        try? logContent.write(to: tempURL, atomically: true, encoding: String.Encoding.utf8)

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = window?.rootViewController?.view
            popover.sourceRect = CGRect(x: 100, y: 100, width: 1, height: 1)
        }
        window?.rootViewController?.present(activityVC, animated: true)
    }
}
#endif

// MARK: - App Delegate

class AppDelegate: UIResponder, UIApplicationDelegate {
    let homeKit = HomeKitManager.shared
    let server = MCPServer()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        log("HomeMCPBridge v2.0.0 starting...")

        #if targetEnvironment(macCatalyst)
        // CRITICAL: Set activation policy to Regular immediately so app appears in app switcher
        // This must happen before any UI is shown
        makeRegularApp()
        #endif

        // Register plugins
        log("Registering plugins...")
        let pluginManager = PluginManager.shared
        pluginManager.register(HomeKitPlugin())
        pluginManager.register(GoveePlugin())
        pluginManager.register(ScryptedPlugin())

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

            // Subscribe to motion and contact events after HomeKit is ready
            self.homeKit.waitUntilReady {
                MotionSensorManager.shared.subscribeToEvents()
                ContactSensorManager.shared.subscribeToEvents()
                log("Motion and contact event subscriptions initialized")

                // Auto-connect to Scrypted MQTT if configured
                if ScryptedMQTTManager.shared.isEnabled && ScryptedMQTTManager.shared.isConfigured {
                    ScryptedMQTTManager.shared.connect()
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

    /// Makes the app a regular macOS app that appears in the Dock and App Switcher
    private func makeRegularApp() {
        guard let nsAppClass = NSClassFromString("NSApplication"),
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject else {
            return
        }

        // NSApplicationActivationPolicyRegular = 0 (normal app with dock icon and menu bar)
        // NSApplicationActivationPolicyAccessory = 1 (no dock icon, menu bar only when active)
        // NSApplicationActivationPolicyProhibited = 2 (background only, no UI)
        let regularPolicy = 0

        let selector = NSSelectorFromString("setActivationPolicy:")
        if sharedApp.responds(to: selector) {
            // Use NSInvocation-style call for Int parameter
            typealias SetPolicyFunc = @convention(c) (NSObject, Selector, Int) -> Bool
            let method = class_getInstanceMethod(type(of: sharedApp), selector)!
            let impl = method_getImplementation(method)
            let setPolicy = unsafeBitCast(impl, to: SetPolicyFunc.self)
            _ = setPolicy(sharedApp, selector, regularPolicy)
            log("Set app to regular activation policy (appears in Dock/App Switcher)")
        }

        // Also activate the app to bring it to front
        let activateSelector = NSSelectorFromString("activateIgnoringOtherApps:")
        if sharedApp.responds(to: activateSelector) {
            sharedApp.perform(activateSelector, with: true)
        }
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
