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

// MARK: - MCP Server

class MCPServer {
    private let homeKit = HomeKitManager.shared
    private var isRunning = false

    private let tools: [[String: Any]] = [
        [
            "name": "list_devices",
            "description": "List all HomeKit devices in all homes with their names, rooms, types, and reachability status.",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ],
        [
            "name": "list_rooms",
            "description": "List all rooms in all HomeKit homes.",
            "inputSchema": ["type": "object", "properties": [:], "required": []]
        ],
        [
            "name": "get_device_state",
            "description": "Get the current state of a HomeKit device (on/off, brightness, color, etc.).",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string", "description": "The name of the device"]],
                "required": ["name"]
            ]
        ],
        [
            "name": "control_device",
            "description": "Control a HomeKit device. Actions: on, off, toggle, brightness (0-100), color ({hue, saturation}), lock, unlock, open, close.",
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
            let devices = homeKit.listDevices()
            log("  -> Found \(devices.count) devices")
            respondToolResult(id: id, result: ["devices": devices, "count": devices.count])

        case "list_rooms":
            let rooms = homeKit.listRooms()
            log("  -> Found \(rooms.count) rooms")
            respondToolResult(id: id, result: ["rooms": rooms, "count": rooms.count])

        case "list_homes":
            let homes = homeKit.listHomes()
            log("  -> Found \(homes.count) homes")
            respondToolResult(id: id, result: ["homes": homes, "count": homes.count])

        case "get_device_state":
            guard let name = arguments["name"] as? String else {
                respondToolResult(id: id, result: ["error": "Missing 'name' parameter"])
                return
            }

            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any] = [:]

            homeKit.getDeviceState(name: name) { state in
                result = state
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 10)
            log("  -> State for '\(name)'")
            respondToolResult(id: id, result: result)

        case "control_device":
            guard let name = arguments["name"] as? String,
                  let action = arguments["action"] as? String else {
                respondToolResult(id: id, result: ["error": "Missing 'name' or 'action' parameter"])
                return
            }

            let value = arguments["value"]

            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any] = [:]

            homeKit.controlDevice(name: name, action: action, value: value) { response in
                result = response
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 10)
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

// MARK: - Status View Controller

class StatusViewController: UIViewController {
    private var textView: UITextView!
    private var statusLabel: UILabel!

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
        // Header
        let headerLabel = UILabel()
        headerLabel.text = "HomeMCPBridge"
        headerLabel.font = .boldSystemFont(ofSize: 24)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerLabel)

        // Subtitle
        let subtitleLabel = UILabel()
        subtitleLabel.text = "Native HomeKit MCP Server for Claude Code"
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subtitleLabel)

        // Status
        statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .systemGreen
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Separator
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        // MCP Config section header
        let configHeader = UILabel()
        configHeader.text = "MCP Configuration"
        configHeader.font = .boldSystemFont(ofSize: 16)
        configHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(configHeader)

        // Config description
        let configDesc = UILabel()
        configDesc.text = "Add this to your project's .mcp.json:"
        configDesc.font = .systemFont(ofSize: 12)
        configDesc.textColor = .secondaryLabel
        configDesc.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(configDesc)

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
        configTextView.layer.cornerRadius = 8
        configTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(configTextView)

        // Copy button
        let copyButton = UIButton(type: .system)
        copyButton.setTitle("Copy Configuration", for: .normal)
        copyButton.addTarget(self, action: #selector(copyConfig), for: .touchUpInside)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(copyButton)

        // Separator 2
        let separator2 = UIView()
        separator2.backgroundColor = .separator
        separator2.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator2)

        // Log section header
        let logHeader = UILabel()
        logHeader.text = "Activity Log"
        logHeader.font = .boldSystemFont(ofSize: 16)
        logHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logHeader)

        // Log text view
        textView = UITextView()
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        textView.textColor = .white
        textView.isEditable = false
        textView.layer.cornerRadius = 8
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            subtitleLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            statusLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            separator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            separator.heightAnchor.constraint(equalToConstant: 1),

            configHeader.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            configHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            configDesc.topAnchor.constraint(equalTo: configHeader.bottomAnchor, constant: 4),
            configDesc.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            configTextView.topAnchor.constraint(equalTo: configDesc.bottomAnchor, constant: 8),
            configTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            configTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            configTextView.heightAnchor.constraint(equalToConstant: 100),

            copyButton.topAnchor.constraint(equalTo: configTextView.bottomAnchor, constant: 8),
            copyButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            separator2.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 16),
            separator2.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            separator2.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            separator2.heightAnchor.constraint(equalToConstant: 1),

            logHeader.topAnchor.constraint(equalTo: separator2.bottomAnchor, constant: 16),
            logHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            textView.topAnchor.constraint(equalTo: logHeader.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
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

// MARK: - Scene Delegate (for Mac Catalyst menu bar)

#if targetEnvironment(macCatalyst)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Configure window
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = StatusViewController()
        window?.makeKeyAndVisible()

        // Set minimum window size
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 500, height: 600)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 800, height: 1000)

        // Build menu bar
        buildMenuBar()
    }

    private func buildMenuBar() {
        // Add menu items via UIMenuBuilder
        UIMenuSystem.main.setNeedsRebuild()
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard builder.system == .main else { return }

        // Add Copy Config menu item
        let copyConfigAction = UIAction(title: "Copy MCP Configuration", image: UIImage(systemName: "doc.on.doc")) { _ in
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

        let editMenu = UIMenu(title: "", options: .displayInline, children: [copyConfigAction])
        builder.insertChild(editMenu, atStartOfMenu: .edit)
    }
}
#endif

// MARK: - App Delegate

class AppDelegate: UIResponder, UIApplicationDelegate {
    let homeKit = HomeKitManager.shared
    let server = MCPServer()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        log("HomeMCPBridge v1.0.0 starting...")

        // Initialize HomeKit
        log("Initializing HomeKit...")
        homeKit.waitUntilReady { [weak self] in
            // Start MCP server on background thread
            DispatchQueue.global(qos: .userInitiated).async {
                self?.server.run()
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
    #endif
}

// MARK: - Main

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
