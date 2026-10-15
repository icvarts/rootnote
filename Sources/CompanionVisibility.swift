import Foundation
import CoreFoundation

struct PetOverlayState: Decodable {
    struct Bounds: Decodable {
        let x: Double
        let y: Double
        let displayId: UInt32
    }
    let isOpen: Bool?
    let bounds: Bounds?

    private enum CodingKeys: String, CodingKey {
        case isOpen = "electron-avatar-overlay-open"
        case bounds = "electron-avatar-overlay-bounds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOpen = try? container.decode(Bool.self, forKey: .isOpen)
        bounds = try? container.decode(Bounds.self, forKey: .bounds)
    }
}

// Share the small decoded snapshot between visibility and position checks.
final class PetOverlayStateCache {
    private struct Fingerprint: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64
    }
    private let url: URL
    private var lastChecked: TimeInterval = -.infinity
    private var fingerprint: Fingerprint?
    private var snapshot: PetOverlayState?
    private(set) var decodeCount = 0
    static let checkInterval: TimeInterval = 0.2

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/.codex-global-state.json")) {
        self.url = url
    }

    func invalidate() {
        lastChecked = -.infinity
        fingerprint = nil
        snapshot = nil
    }

    func read(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PetOverlayState? {
        if now >= lastChecked && now - lastChecked < Self.checkInterval { return snapshot }
        lastChecked = now
        guard let current = fileFingerprint() else {
            fingerprint = nil
            snapshot = nil
            return nil
        }
        if current == fingerprint { return snapshot }
        // Invalidate first: failed reads must never keep a visible old pet.
        fingerprint = nil
        snapshot = nil
        guard let data = try? Data(contentsOf: url), fileFingerprint() == current else { return nil }
        decodeCount += 1
        snapshot = try? JSONDecoder().decode(PetOverlayState.self, from: data)
        fingerprint = current
        return snapshot
    }

    private func fileFingerprint() -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Fingerprint(size: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }
}

enum CompanionSuspension: Hashable { case system, display }

final class CompanionVisibility {
    private(set) var petAvailable = false
    private var suspensions: Set<CompanionSuspension> = []
    var sleeping: Bool { !suspensions.isEmpty }
    private(set) var scenePaused = false
    private(set) var generation: UInt64 = 0

    var accessoriesVisible: Bool { petAvailable && !sleeping }
    var sceneVisible: Bool { accessoriesVisible && !scenePaused }

    @discardableResult
    func setPetAvailable(_ available: Bool) -> Bool {
        guard petAvailable != available else { return false }
        petAvailable = available
        generation &+= 1
        return true
    }

    func setScenePaused(_ paused: Bool) {
        guard scenePaused != paused else { return }
        scenePaused = paused
        generation &+= 1
    }

    func invalidateAnchor() {
        petAvailable = false
        generation &+= 1
    }

    func sleep(_ reason: CompanionSuspension = .system) {
        suspensions.insert(reason)
        invalidateAnchor()
    }

    func wake(_ reason: CompanionSuspension = .system) {
        suspensions.remove(reason)
        invalidateAnchor()
    }

    func allowsSceneCallback(_ token: UInt64) -> Bool {
        sceneVisible && generation == token
    }

    static func decodePetOpen(_ data: Data?) -> Bool? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["electron-avatar-overlay-open"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return value.boolValue
    }
}

enum RootnoteRuntimePaths {
    static var nativeControlsEnabled: Bool {
        CommandLine.arguments.contains("--paired-native-controls") ||
            Bundle.main.object(forInfoDictionaryKey: "RootnoteNativeControlsEnabled") as? Bool == true
    }

    static var isCandidate: Bool {
        Bundle.main.bundleIdentifier != "com.selfsystem.rootnote-resonance"
    }

    static func statusURL(_ name: String) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard isCandidate else { return root.appendingPathComponent(name) }
        let isolated = root.appendingPathComponent("rootnote-unified-visibility-candidate", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        return isolated.appendingPathComponent(name)
    }

    static func nativeBridgeURL(_ name: String) -> URL {
        guard !isCandidate else { return statusURL(name) }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Rootnote/NativeBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root.appendingPathComponent(name)
    }
}

func runVisibilitySelfTest() -> Int32 {
    var checks: [String: Bool] = [:]
    let state = CompanionVisibility()
    checks["startup_hidden"] = !state.sceneVisible && !state.accessoriesVisible
    state.setPetAvailable(true)
    let beforeHide = state.generation
    checks["visible_anchor_opens_scene"] = state.sceneVisible
    state.setPetAvailable(false)
    checks["hidden_task_event_rejected"] = !state.allowsSceneCallback(state.generation)
    checks["hidden_delayed_reveal_rejected"] = !state.allowsSceneCallback(beforeHide)
    state.setPetAvailable(true)
    checks["old_callback_stays_invalid_after_show"] = !state.allowsSceneCallback(beforeHide)
    let beforeSpace = state.generation
    state.invalidateAnchor()
    checks["space_change_requires_fresh_anchor"] = !state.sceneVisible
    state.setPetAvailable(true)
    checks["space_change_invalidates_old_callback"] = !state.allowsSceneCallback(beforeSpace)
    state.setScenePaused(true)
    checks["scene_pause_preserves_accessories"] = !state.sceneVisible && state.accessoriesVisible
    state.sleep()
    checks["sleep_hides_all_accessories"] = !state.sceneVisible && !state.accessoriesVisible
    state.wake()
    checks["wake_does_not_reuse_anchor"] = !state.sceneVisible && !state.accessoriesVisible
    state.setPetAvailable(true)
    checks["wake_preserves_scene_preference"] = !state.sceneVisible && state.accessoriesVisible
    state.setScenePaused(false)
    checks["resume_scene_after_fresh_anchor"] = state.sceneVisible
    state.sleep(.system)
    state.sleep(.display)
    state.wake(.system)
    state.setPetAvailable(true)
    checks["system_wake_does_not_wake_sleeping_display"] = !state.accessoriesVisible
    state.wake(.display)
    checks["display_wake_still_requires_fresh_anchor"] = !state.accessoriesVisible
    for (name, value, expected) in [
        ("true", "true", true as Bool?), ("false", "false", false as Bool?),
        ("number", "1", nil), ("string", "\"true\"", nil), ("null", "null", nil),
    ] {
        let data = "{\"electron-avatar-overlay-open\":\(value)}".data(using: .utf8)
        checks["pet_open_\(name)"] = CompanionVisibility.decodePetOpen(data) == expected
    }
    checks["missing_intent_fails_closed"] = CompanionVisibility.decodePetOpen(Data("{}".utf8)) == nil
    checks["malformed_intent_fails_closed"] = CompanionVisibility.decodePetOpen(Data("{".utf8)) == nil
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("rootnote-pet-cache-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    do {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let file = temporary.appendingPathComponent("state.json")
        func write(_ open: Bool, x: Double) throws {
            let object: [String: Any] = [
                "electron-avatar-overlay-open": open,
                "electron-avatar-overlay-bounds": ["x": x, "y": 50, "displayId": 1],
                "unrelated": String(repeating: "x", count: 800_000)
            ]
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        }
        try write(true, x: 40)
        let cache = PetOverlayStateCache(url: file)
        checks["cache_initial_read_immediate"] = cache.read(now: 0)?.isOpen == true
        for tick in 1...100 { _ = cache.read(now: Double(tick) / 5) }
        checks["unchanged_large_state_decoded_once"] = cache.decodeCount == 1
        checks["cache_keeps_only_typed_anchor"] = cache.read(now: 21)?.bounds?.x == 40
        try write(false, x: 80)
        checks["atomic_replace_updates_visibility_and_anchor"] = cache.read(now: 22)?.isOpen == false && cache.read(now: 22)?.bounds?.x == 80
        checks["consumers_share_one_decode"] = cache.decodeCount == 2
        try Data("{".utf8).write(to: file, options: .atomic)
        checks["invalid_replacement_clears_old_state"] = cache.read(now: 23) == nil
        try FileManager.default.removeItem(at: file)
        checks["missing_file_clears_old_state"] = cache.read(now: 24) == nil
        try write(true, x: 100)
        checks["recreated_file_recovers"] = cache.read(now: 25)?.bounds?.x == 100
        cache.invalidate()
        checks["refresh_bypasses_throttle"] = cache.read(now: 25)?.isOpen == true && cache.decodeCount == 5
        let invalid = Data(#"{"electron-avatar-overlay-open":1,"electron-avatar-overlay-bounds":{"x":1,"y":1,"displayId":-1}}"#.utf8)
        let decoded = try JSONDecoder().decode(PetOverlayState.self, from: invalid)
        checks["typed_invalid_fields_fail_closed"] = decoded.isOpen == nil && decoded.bounds == nil
    } catch { checks["cache_fixture_io"] = false }
    let passed = checks.values.allSatisfy { $0 }
    let report: [String: Any] = ["ok": passed, "checks": checks, "count": checks.count,
                                "liveWindowsUsed": false, "liveApprovalSent": false]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        print("")
    }
    return passed ? 0 : 1
}
