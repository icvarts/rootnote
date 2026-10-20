import AppKit
import Foundation
import WebKit

private enum CallKind: Equatable {
    case approval
    case spawnAgent
    case closeAgent
    case waitAgent
    case search
    case generic
}

final class EventRouter {
    typealias Emitter = (_ type: String, _ detail: [String: Any]) -> Void

    private let emit: Emitter
    private var taskActive = false
    private var activeAgents = 0
    private var activeCalls: [String: CallKind] = [:]
    private var taskStartedAt: Date?
    private var reaction = "none"
    private var pressureTriggered = false
    private var usedAgents = false
    private var completionGeneration = 0
    private var lastCompletion = Date.distantPast

    init(emit: @escaping Emitter) {
        self.emit = emit
    }

    func resetForSession() {
        completionGeneration += 1
        taskActive = false
        activeAgents = 0
        activeCalls.removeAll()
        taskStartedAt = nil
        reaction = "none"
        pressureTriggered = false
        usedAgents = false
        emit("no-task", [:])
    }

    func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        handle(object)
    }

    func handle(_ object: [String: Any]) {
        guard let outerType = object["type"] as? String,
              let payload = object["payload"] as? [String: Any]
        else { return }

        if outerType == "event_msg" {
            handleEvent(payload)
        } else if outerType == "response_item" {
            handleResponseItem(payload)
        }
    }

    func tick(now: Date = Date()) {
        guard taskActive,
              activeAgents > 0,
              !pressureTriggered,
              let taskStartedAt,
              now.timeIntervalSince(taskStartedAt) >= 45
        else { return }
        pressureTriggered = true
        emit("pressure", [:])
    }

    private func handleEvent(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "user_message", "task_started":
            beginTask()
        case "agent_reasoning", "web_search_end", "patch_apply_end", "image_generation_end":
            if !taskActive { beginTask() }
            if activeAgents == 0 && reaction == "none" { emit("analysis", [:]) }
        case "agent_message":
            if (payload["phase"] as? String) == "final_answer" { completeTask() }
        case "task_complete":
            completeTask()
        default:
            break
        }
    }

    private func handleResponseItem(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "custom_tool_call", "function_call":
            handleCall(payload)
        case "custom_tool_call_output", "function_call_output":
            handleOutput(payload)
        case "message":
            if (payload["role"] as? String) == "user" {
                beginTask()
            } else if (payload["role"] as? String) == "assistant",
                      (payload["phase"] as? String) == "final_answer" {
                completeTask()
            }
        default:
            break
        }
    }

    private func handleCall(_ payload: [String: Any]) {
        if !taskActive { beginTask() }
        let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? UUID().uuidString
        let content = [payload["name"], payload["input"], payload["arguments"]]
            .compactMap(stringValue)
            .joined(separator: " ")
            .lowercased()
        let kind = classifyCall(content)
        activeCalls[callID] = kind

        switch kind {
        case .approval:
            reaction = "waiting"
            emit("approval", ["summary": approvalSummary(payload)])
        case .spawnAgent:
            activeAgents = min(5, activeAgents + 1)
            usedAgents = true
            reaction = "none"
            emit("agents", ["agents": activeAgents])
        case .closeAgent:
            break
        case .waitAgent:
            if activeAgents > 0 { emit("agents", ["agents": activeAgents]) }
        case .search, .generic:
            if activeAgents > 0 {
                emit("agents", ["agents": activeAgents])
            } else if reaction == "none" {
                emit("analysis", [:])
            }
        }
    }

    private func handleOutput(_ payload: [String: Any]) {
        let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? ""
        let kind = activeCalls.removeValue(forKey: callID) ?? .generic
        let output = stringValue(payload["output"])?.lowercased() ?? ""
        let failed = outputIndicatesFailure(output)

        if kind == .approval && reaction == "waiting" {
            reaction = "none"
            emit("clear", [:])
        }

        if kind == .closeAgent || (kind == .waitAgent && output.contains("completed")) {
            activeAgents = max(0, activeAgents - 1)
            if activeAgents > 0 {
                emit("agents", ["agents": activeAgents])
            } else if taskActive {
                emit("analysis", [:])
            }
        }

        if kind == .spawnAgent && failed {
            activeAgents = max(0, activeAgents - 1)
        }

        if failed {
            reaction = "failure"
            emit("failure", [:])
        } else if reaction == "failure" {
            reaction = "none"
            emit("clear", [:])
        }
    }

    private func beginTask() {
        completionGeneration += 1
        if !taskActive {
            activeAgents = 0
            activeCalls.removeAll()
            pressureTriggered = false
            usedAgents = false
            taskStartedAt = Date()
        }
        taskActive = true
        reaction = "none"
        emit("analysis", [:])
    }

    private func completeTask() {
        let now = Date()
        guard now.timeIntervalSince(lastCompletion) > 0.8 else { return }
        lastCompletion = now
        taskActive = false
        reaction = "review"
        completionGeneration += 1
        let generation = completionGeneration
        emit("complete", [:])
        let returnDelay = usedAgents ? RevealTiming.review : RevealTiming.explorationTail
        DispatchQueue.main.asyncAfter(deadline: .now() + returnDelay) { [weak self] in
            guard let self, self.completionGeneration == generation, !self.taskActive else { return }
            self.activeAgents = 0
            self.activeCalls.removeAll()
            self.reaction = "none"
            self.taskStartedAt = nil
            self.pressureTriggered = false
            self.usedAgents = false
            self.emit("no-task", [:])
        }
    }

    private func classifyCall(_ content: String) -> CallKind {
        if content.contains("require_escalated") || content.contains("request_user_input") {
            return .approval
        }
        if content.contains("multi_agent_v1__spawn_agent") || content.contains("spawn_agent") {
            return .spawnAgent
        }
        if content.contains("multi_agent_v1__close_agent") || content.contains("close_agent") {
            return .closeAgent
        }
        if content.contains("multi_agent_v1__wait_agent") || content.contains("wait_agent") {
            return .waitAgent
        }
        let searchSignals = [
            "search_query", "web__run", "read_mcp", "view_image", "screenshot",
            "rg -n", "rg --files", "sed -n", "tail -n", "find ", "jq "
        ]
        if searchSignals.contains(where: content.contains) { return .search }
        return .generic
    }

    private func outputIndicatesFailure(_ output: String) -> Bool {
        let signals = [
            "exit_code=1", "exit_code\":1", "script failed", "process exited with code 1",
            "error when starting", "uncaught error", "fatal error", "\"ok\":false"
        ]
        return signals.contains(where: output.contains)
    }

    private func approvalSummary(_ payload: [String: Any]) -> String {
        let preferredKeys = ["justification", "question", "cmd", "command", "path"]
        for containerKey in ["input", "arguments"] {
            guard let value = payload[containerKey] else { continue }
            if let dictionary = value as? [String: Any] {
                for key in preferredKeys {
                    if let text = stringValue(dictionary[key]), !text.isEmpty {
                        return compactApprovalText(text)
                    }
                }
            }
            if let text = stringValue(value), !text.isEmpty {
                if let data = text.data(using: .utf8),
                   let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for key in preferredKeys {
                        if let candidate = stringValue(dictionary[key]), !candidate.isEmpty {
                            return compactApprovalText(candidate)
                        }
                    }
                }
                return compactApprovalText(text)
            }
        }
        return "Codex 请求执行一项受控操作"
    }

    private func compactApprovalText(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard singleLine.count > 220 else { return singleLine }
        return String(singleLine.prefix(217)) + "…"
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }
}

final class SessionMonitor {
    private let sessionsRoot: URL
    private let router: EventRouter
    private var timer: Timer?
    private var currentURL: URL?
    private var offset: UInt64 = 0
    private var partial = ""
    private var lastScan = Date.distantPast

    init(router: EventRouter) {
        self.router = router
        sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let now = Date()
        if now.timeIntervalSince(lastScan) >= 2 {
            lastScan = now
            if let latest = latestSessionURL(), latest != currentURL {
                switchSession(to: latest)
            }
        }
        readAppendedData()
        router.tick(now: now)
    }

    private func latestSessionURL() -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var latestURL: URL?
        var latestDate = Date.distantPast
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified > latestDate
            else { continue }
            latestDate = modified
            latestURL = url
        }
        return latestURL
    }

    private func switchSession(to url: URL) {
        currentURL = url
        partial = ""
        router.resetForSession()
        offset = fileSize(url)
    }

    private func readAppendedData() {
        guard let currentURL else { return }
        let size = fileSize(currentURL)
        if size < offset {
            offset = 0
            partial = ""
        }
        guard size > offset,
              let handle = try? FileHandle(forReadingFrom: currentURL)
        else { return }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            try handle.close()
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            var lines = (partial + chunk).components(separatedBy: "\n")
            partial = lines.popLast() ?? ""
            for line in lines where !line.isEmpty { router.handle(line: line) }
        } catch {
            try? handle.close()
        }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.uint64Value
    }
}

final class LocalSceneSchemeHandler: NSObject, WKURLSchemeHandler {
    private let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let decodedPath = requestURL.path.removingPercentEncoding ?? requestURL.path
        let relativePath = decodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resourcePath = relativePath.isEmpty ? "index.html" : relativePath
        let resourceURL = rootDirectory.appendingPathComponent(resourcePath).standardizedFileURL
        let rootPrefix = rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/"
        guard resourceURL.path.hasPrefix(rootPrefix),
              let data = try? Data(contentsOf: resourceURL)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = URLResponse(
            url: requestURL,
            mimeType: mimeType(for: resourceURL.pathExtension.lowercased()),
            expectedContentLength: data.count,
            textEncodingName: isTextExtension(resourceURL.pathExtension.lowercased()) ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    private func isTextExtension(_ pathExtension: String) -> Bool {
        ["html", "js", "mjs", "css", "svg", "json"].contains(pathExtension)
    }
}

struct CharacterOverlaySample {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let x: CGFloat
    let y: CGFloat
    let windowBounds: CGRect
    let mascotBounds: CGRect
    let controlOverlayBounds: CGRect?
    let voiceControlsBounds: CGRect?
    let voiceBackingBounds: CGRect?
    let voiceChromeExpanded: Bool
    let windowNumber: Int
    let owner: String
    let trailSide: String
    let detectionStrategy: String
}

private enum AvatarOverlayGeometry {
    static let knownViewportSizes = [
        CGSize(width: 356, height: 320),
        CGSize(width: 384, height: 400)
    ]
    static let mascotSideInset: CGFloat = 28
    static let mascotBottomInset: CGFloat = 8
    static let trailOffsetRatio: CGFloat = 0.16
    static let trailHeightRatio: CGFloat = 0.66

    static func candidateScore(bounds: CGRect, layer: Int, owner: String) -> CGFloat {
        let sizeDistance = knownViewportSizes.map {
            abs(bounds.width - $0.width) + abs(bounds.height - $0.height)
        }.min() ?? .greatestFiniteMagnitude
        let ownerPenalty: CGFloat = owner.lowercased().contains("computer use") ? 500 : 0
        return sizeDistance + CGFloat(abs(layer - 3)) * 80 + ownerPenalty
    }

    static func mascotBounds(
        in viewport: CGRect,
        avatarWidth: CGFloat,
        trailDirection: CGFloat
    ) -> CGRect {
        let avatarHeight = avatarWidth * 208 / 192
        let bodyIsOnRight = trailDirection < 0
        let originX = bodyIsOnRight
            ? viewport.maxX - mascotSideInset - avatarWidth
            : viewport.minX + mascotSideInset
        return CGRect(
            x: originX,
            y: viewport.maxY - mascotBottomInset - avatarHeight,
            width: avatarWidth,
            height: avatarHeight
        )
    }

    static func attachment(in mascot: CGRect, trailDirection: CGFloat) -> CGPoint {
        CGPoint(
            x: mascot.midX + trailDirection * mascot.width * trailOffsetRatio,
            y: mascot.minY + mascot.height * trailHeightRatio
        )
    }
}

private final class CharacterOverlayMonitor {
    private struct NativeOverlayAnchor {
        let displayID: CGDirectDisplayID
        let mascotBounds: CGRect
        let voiceBackingBounds: CGRect
    }

    var onSample: ((CharacterOverlaySample) -> Void)?
    var onStableSample: ((CharacterOverlaySample) -> Void)?
    var onUnavailable: (() -> Void)?
    private var lastReconciliationAt = Date.distantPast

    private var timer: Timer?
    private var lastAnchor: CGPoint?
    private var lastDisplayID: CGDirectDisplayID?
    private var lastStatusAt = Date.distantPast
    private var lastStatusActive: Bool?
    private var unavailableSince: Date?
    private var lastCharacterCenterX: CGFloat?
    private var lastVoiceBackingBounds: CGRect?
    private var lastVoiceChromeExpanded = false
    private var trailDirection: CGFloat = -1
    private var nativeAnchorCache: NativeOverlayAnchor?
    private var nativeAnchorCacheAt = Date.distantPast
    private let petStateCache = PetOverlayStateCache()
    private var pointerMonitor: Any?
    private var lastSample: CharacterOverlaySample?
    private var dragStart: CGPoint?
    private var dragInitialAnchor: NativeOverlayAnchor?
    private var dragAnchor: NativeOverlayAnchor?
    private var dragReleasedAt: Date?
    private let avatarWidth: CGFloat

    init() {
        avatarWidth = Self.configuredAvatarWidth()
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: PetOverlayStateCache.checkInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.followPetDrag(event)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        clearDrag()
    }

    func refresh() {
        nativeAnchorCacheAt = .distantPast
        nativeAnchorCache = nil
        petStateCache.invalidate()
        lastStatusActive = nil
        unavailableSince = nil
        lastSample = nil
        clearDrag()
        poll()
    }

    private func clearDrag() {
        dragStart = nil
        dragInitialAnchor = nil
        dragAnchor = nil
        dragReleasedAt = nil
    }

    private func followPetDrag(_ event: NSEvent) {
        guard let point = event.cgEvent?.location else { return }
        if event.type == .leftMouseDown {
            clearDrag()
            guard currentPetOpenIntent() == true,
                  let sample = lastSample,
                  sample.detectionStrategy == "native-draw-window-persisted-anchor",
                  sample.mascotBounds.contains(point),
                  let row = sample.voiceBackingBounds else { return }
            dragStart = point
            dragInitialAnchor = NativeOverlayAnchor(displayID: sample.displayID, mascotBounds: sample.mascotBounds, voiceBackingBounds: row)
        } else if event.type == .leftMouseDragged,
                  let start = dragStart, let initial = dragInitialAnchor {
            let dx = point.x - start.x, dy = point.y - start.y
            let mascot = initial.mascotBounds.offsetBy(dx: dx, dy: dy)
            let displayID = NSScreen.screens.compactMap(Self.displayID).first {
                CGDisplayBounds($0).contains(CGPoint(x: mascot.midX, y: mascot.midY))
            } ?? initial.displayID
            dragAnchor = NativeOverlayAnchor(displayID: displayID, mascotBounds: mascot, voiceBackingBounds: initial.voiceBackingBounds.offsetBy(dx: dx, dy: dy))
            poll()
        } else if event.type == .leftMouseUp, dragStart != nil {
            dragStart = nil
            dragInitialAnchor = nil
            dragReleasedAt = Date()
            nativeAnchorCacheAt = .distantPast
            petStateCache.invalidate()
            poll()
        }
    }

    private func poll() {
        guard currentPetOpenIntent() == true else {
            clearDrag()
            lastSample = nil
            if lastStatusActive != false {
                writeStatus(active: false, sample: nil)
                onUnavailable?()
            }
            unavailableSince = nil
            return
        }
        guard let sample = locateCharacterOverlay() else {
            clearDrag()
            lastSample = nil
            if lastStatusActive != false {
                writeStatus(active: false, sample: nil)
                onUnavailable?()
            }
            return
        }

        unavailableSince = nil
        lastSample = sample
        let anchor = CGPoint(x: sample.x, y: sample.y)
        let moved = lastAnchor.map { hypot($0.x - anchor.x, $0.y - anchor.y) > 0.0004 } ?? true
        let changedScreen = lastDisplayID != sample.displayID
        let becameAvailable = lastStatusActive != true
        let changedVoiceBacking = !Self.rectsAreNearlyEqual(
            lastVoiceBackingBounds,
            sample.voiceBackingBounds
        ) || lastVoiceChromeExpanded != sample.voiceChromeExpanded
        if moved || changedScreen || becameAvailable || changedVoiceBacking {
            lastAnchor = anchor
            lastDisplayID = sample.displayID
            lastVoiceBackingBounds = sample.voiceBackingBounds
            lastVoiceChromeExpanded = sample.voiceChromeExpanded
            onSample?(sample)
            lastReconciliationAt = Date()
        } else if Date().timeIntervalSince(lastReconciliationAt) >= 1 {
            // Reconcile only a freshly validated anchor, never a hidden pet.
            onStableSample?(sample)
            lastReconciliationAt = Date()
        }
        writeStatus(active: true, sample: sample)
    }

    private func currentPetOpenIntent() -> Bool? {
        petStateCache.read()?.isOpen
    }

    private func locateCharacterOverlay() -> CharacterOverlaySample? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let exactMascots = windowInfo.compactMap { window -> (CGRect, String, Int, Int, CGFloat)? in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  Self.isCodexOwner(owner),
                  let layer = Self.intValue(window[kCGWindowLayer as String]),
                  let windowNumber = Self.intValue(window[kCGWindowNumber as String]),
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  Self.isMascotEffectWindow(
                      name: window[kCGWindowName as String] as? String,
                      layer: layer,
                      bounds: bounds
                  )
            else { return nil }
            let named = (window[kCGWindowName as String] as? String) == "Codex Pet Mascot Effect"
            let sizeDistance = abs(bounds.width - 264) + abs(bounds.height - 275)
            return (bounds, owner, layer, windowNumber, named ? sizeDistance : sizeDistance + 100)
        }
        let exactMascot = exactMascots.sorted {
            if $0.4 != $1.4 { return $0.4 < $1.4 }
            return $0.0.area < $1.0.area
        }.first

        let candidates = windowInfo.compactMap { window -> (CGRect, String, Int, Int, CGFloat)? in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  Self.isCodexOwner(owner),
                  let layer = Self.intValue(window[kCGWindowLayer as String]),
                  (1...10).contains(layer),
                  let windowNumber = Self.intValue(window[kCGWindowNumber as String]),
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 300,
                  bounds.height >= 260,
                  bounds.width <= 520,
                  bounds.height <= 520
            else { return nil }
            return (
                bounds,
                owner,
                layer,
                windowNumber,
                AvatarOverlayGeometry.candidateScore(bounds: bounds, layer: layer, owner: owner)
            )
        }
        let fallback = candidates.sorted(by: { lhs, rhs in
            if lhs.4 != rhs.4 { return lhs.4 < rhs.4 }
            return lhs.0.area < rhs.0.area
        }).first

        // Codex 26.825 moved the native pet, activity pills and controls into
        // one oversized transparent layer-3 draw window. Its bounds describe
        // the rendering canvas, not the pet. The pet's actual anchor remains
        // persisted by Codex in .codex-global-state.json.
        let nativeDrawWindow = windowInfo.compactMap { window -> (CGRect, String, Int)? in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  Self.isCodexOwner(owner),
                  let layer = Self.intValue(window[kCGWindowLayer as String]),
                  layer == 3,
                  let windowNumber = Self.intValue(window[kCGWindowNumber as String]),
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 540,
                  bounds.width <= 2400,
                  bounds.height >= 600,
                  bounds.height <= 5000
            else { return nil }
            return (bounds, owner, windowNumber)
        }.min { $0.0.area < $1.0.area }
        let nativeAnchor = nativeDrawWindow.flatMap {
            currentNativeOverlayAnchor(overlayBounds: $0.0)
        }
        guard exactMascot != nil || fallback != nil || nativeAnchor != nil else { return nil }

        let windowBounds: CGRect
        let owner: String
        let windowNumber: Int
        let detectionStrategy: String
        if let exactMascot {
            windowBounds = exactMascot.0
            owner = exactMascot.1
            windowNumber = exactMascot.3
            detectionStrategy = "legacy-mascot-effect"
        } else if let fallback {
            windowBounds = fallback.0
            owner = fallback.1
            windowNumber = fallback.3
            detectionStrategy = "legacy-viewport-fallback"
        } else if let nativeDrawWindow, nativeAnchor != nil {
            windowBounds = nativeDrawWindow.0
            owner = nativeDrawWindow.1
            windowNumber = nativeDrawWindow.2
            detectionStrategy = "native-draw-window-persisted-anchor"
        } else {
            return nil
        }

        // Codex renders the visible pet controls inside a separate 384×142
        // interaction overlay. The 264×275 mascot-effect window includes
        // transparent effect space, so its bottom edge is not the visual
        // control-row baseline.
        let controlOverlayBounds = windowInfo.compactMap { window -> CGRect? in
            guard let overlayOwner = window[kCGWindowOwnerName as String] as? String,
                  Self.isCodexOwner(overlayOwner),
                  let layer = Self.intValue(window[kCGWindowLayer as String]),
                  layer == 3,
                  (window[kCGWindowName as String] as? String) == "Codex",
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 360,
                  bounds.width <= 410,
                  bounds.height >= 120,
                  bounds.height <= 170,
                  abs(bounds.midX - windowBounds.midX) <= 40,
                  abs(bounds.maxY - windowBounds.maxY) <= 100
            else { return nil }
            return bounds
        }.min {
            abs($0.midX - windowBounds.midX) + abs($0.maxY - windowBounds.maxY) <
                abs($1.midX - windowBounds.midX) + abs($1.maxY - windowBounds.maxY)
        }

        let expectedVoiceCenter = CGPoint(
            x: windowBounds.midX - 16,
            y: windowBounds.maxY - 56
        )
        let discoveredVoiceBackingBounds = windowInfo.compactMap { window -> CGRect? in
            guard let voiceOwner = window[kCGWindowOwnerName as String] as? String,
                  Self.isCodexOwner(voiceOwner),
                  let layer = Self.intValue(window[kCGWindowLayer as String]),
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 12,
                  bounds.width <= 220,
                  bounds.height >= 4,
                  bounds.height <= 96
            else { return nil }
            let name = window[kCGWindowName as String] as? String
            let isNamedBacking = name == "Codex Pet Voice Controls Backing"
            let isUntitledBacking = name?.isEmpty != false &&
                layer == 3 &&
                Self.isPlausibleUntitledVoiceBacking(
                    bounds,
                    expectedCenter: expectedVoiceCenter
                )
            guard isNamedBacking || isUntitledBacking else { return nil }
            return bounds
        }.min {
            abs($0.midX - windowBounds.midX) + abs($0.midY - windowBounds.maxY) <
                abs($1.midX - windowBounds.midX) + abs($1.midY - windowBounds.maxY)
        }
        let voiceBackingBounds = discoveredVoiceBackingBounds ?? nativeAnchor?.voiceBackingBounds
        let voiceControlsBounds = voiceBackingBounds.flatMap { bounds -> CGRect? in
            guard bounds.width >= 40,
                  bounds.width <= 72,
                  bounds.height >= 16,
                  bounds.height <= 32
            else { return nil }
            return bounds
        }
        let voiceChromeExpanded = voiceBackingBounds.map {
            $0.width >= 40 && $0.height >= 16
        } ?? false

        let viewportCenterX = nativeAnchor?.mascotBounds.midX ?? windowBounds.midX
        if let lastCharacterCenterX {
            let movement = viewportCenterX - lastCharacterCenterX
            if abs(movement) >= 1.5 {
                trailDirection = movement > 0 ? -1 : 1
            }
        }
        lastCharacterCenterX = viewportCenterX
        let mascotBounds = nativeAnchor?.mascotBounds ?? AvatarOverlayGeometry.mascotBounds(
            in: windowBounds,
            avatarWidth: avatarWidth,
            trailDirection: trailDirection
        )
        let attachment = AvatarOverlayGeometry.attachment(
            in: mascotBounds,
            trailDirection: trailDirection
        )
        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(for: screen) else { continue }
            let displayBounds = CGDisplayBounds(displayID)
            guard displayBounds.insetBy(dx: -1, dy: -1).contains(attachment) else { continue }
            let x = min(max((attachment.x - displayBounds.minX) / max(displayBounds.width, 1), 0), 1)
            let y = min(max((attachment.y - displayBounds.minY) / max(displayBounds.height, 1), 0), 1)
            return CharacterOverlaySample(
                screen: screen,
                displayID: displayID,
                x: x,
                y: y,
                windowBounds: windowBounds,
                mascotBounds: mascotBounds,
                controlOverlayBounds: controlOverlayBounds,
                voiceControlsBounds: voiceControlsBounds,
                voiceBackingBounds: voiceBackingBounds,
                voiceChromeExpanded: voiceChromeExpanded,
                windowNumber: windowNumber,
                owner: owner,
                trailSide: trailDirection < 0 ? "left" : "right",
                detectionStrategy: detectionStrategy
            )
        }
        return nil
    }

    private func writeStatus(active: Bool, sample: CharacterOverlaySample?) {
        let now = Date()
        guard lastStatusActive != active || now.timeIntervalSince(lastStatusAt) >= 2 else { return }
        lastStatusActive = active
        lastStatusAt = now
        var status: [String: Any] = [
            "active": active,
            "avatarWidth": avatarWidth,
            "source": "cg-window-metadata",
            "timestamp": ISO8601DateFormatter().string(from: now)
        ]
        if let sample {
            status["anchor"] = ["x": sample.x, "y": sample.y]
            status["displayID"] = sample.displayID
            status["owner"] = sample.owner
            status["trailSide"] = sample.trailSide
            status["detectionStrategy"] = sample.detectionStrategy
            status["windowBounds"] = NSStringFromRect(sample.windowBounds)
            status["mascotBounds"] = NSStringFromRect(sample.mascotBounds)
            if let controlOverlayBounds = sample.controlOverlayBounds {
                status["controlOverlayBounds"] = NSStringFromRect(controlOverlayBounds)
            }
            if let voiceControlsBounds = sample.voiceControlsBounds {
                status["voiceControlsBounds"] = NSStringFromRect(voiceControlsBounds)
            }
            if let voiceBackingBounds = sample.voiceBackingBounds {
                status["voiceBackingBounds"] = NSStringFromRect(voiceBackingBounds)
            }
            status["voiceChromeExpanded"] = sample.voiceChromeExpanded
            status["windowNumber"] = sample.windowNumber
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: status,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(
            to: RootnoteRuntimePaths.statusURL("rootnote-resonance-anchor-status.json"),
            options: .atomic
        )
    }

    private static func rectsAreNearlyEqual(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.minX - rhs.minX) < 0.5 &&
                abs(lhs.minY - rhs.minY) < 0.5 &&
                abs(lhs.width - rhs.width) < 0.5 &&
                abs(lhs.height - rhs.height) < 0.5
        default:
            return false
        }
    }

    func diagnosticSample() -> CharacterOverlaySample? {
        locateCharacterOverlay()
    }

    private func currentNativeOverlayAnchor(overlayBounds: CGRect) -> NativeOverlayAnchor? {
        let now = Date()
        if dragStart != nil, let dragAnchor { return dragAnchor }
        if now.timeIntervalSince(nativeAnchorCacheAt) < 0.04 {
            return nativeAnchorCache
        }
        nativeAnchorCacheAt = now
        nativeAnchorCache = nil

        guard let state = petStateCache.read()?.bounds else { return nil }
        let displayID = CGDirectDisplayID(state.displayId)
        guard let screen = NSScreen.screens.first(where: { Self.displayID(for: $0) == displayID })
        else { return nil }
        let displayBounds = CGDisplayBounds(displayID)
        let mascotHeight = ceil(avatarWidth * 208 / 192)
        let mascotBounds = CGRect(
            x: CGFloat(state.x),
            y: CGFloat(state.y),
            width: avatarWidth,
            height: mascotHeight
        )
        guard displayBounds.insetBy(dx: -80, dy: -80).intersects(mascotBounds),
              overlayBounds.insetBy(dx: -8, dy: -8).contains(
                  CGPoint(x: mascotBounds.midX, y: mascotBounds.midY)
              ),
              screen.frame.width > 0
        else { return nil }

        // Match the installed native arc's two middle 24 pt controls (8 pt gap).
        // Keep the whole native row reserved; the performance circle stays left.
        let radius = avatarWidth / 2 + 12
        let rowTop = round(mascotHeight / 2 + sqrt(radius * radius - 16 * 16) - 12 + 10)
        let voiceBackingBounds = CGRect(
            x: mascotBounds.midX - 28,
            y: mascotBounds.minY + rowTop,
            width: 56,
            height: 24
        )
        let anchor = NativeOverlayAnchor(
            displayID: displayID,
            mascotBounds: mascotBounds,
            voiceBackingBounds: voiceBackingBounds
        )
        if let dragAnchor, let releasedAt = dragReleasedAt,
           now.timeIntervalSince(releasedAt) < 0.4,
           hypot(anchor.mascotBounds.minX - dragAnchor.mascotBounds.minX, anchor.mascotBounds.minY - dragAnchor.mascotBounds.minY) > 2 {
            nativeAnchorCache = dragAnchor
            return dragAnchor
        }
        if dragReleasedAt != nil { clearDrag() }
        nativeAnchorCache = anchor
        return anchor
    }

    private static func isPlausibleUntitledVoiceBacking(
        _ bounds: CGRect,
        expectedCenter: CGPoint
    ) -> Bool {
        let isCompact = bounds.width >= 14 && bounds.width <= 22 &&
            bounds.height >= 4 && bounds.height <= 10
        let isExpanded = bounds.width >= 40 && bounds.width <= 220 &&
            bounds.height >= 16 && bounds.height <= 96
        guard isCompact || isExpanded else { return false }
        return hypot(bounds.midX - expectedCenter.x, bounds.midY - expectedCenter.y) <= 150
    }

    private static func configuredAvatarWidth() -> CGFloat {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"avatar-overlay-mascot-width-px\s*=\s*([0-9]+)"#
              ),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text),
              let width = Double(text[range])
        else { return 123 }
        return CGFloat(min(max(width, 80), 220))
    }

    private static func isMascotEffectWindow(
        name: String?,
        layer: Int,
        bounds: CGRect
    ) -> Bool {
        if name == "Codex Pet Mascot Effect" {
            return bounds.width >= 80 && bounds.height >= 100 &&
                bounds.width <= 520 && bounds.height <= 520
        }
        // Window titles are withheld from an app that does not have Screen
        // Recording permission. The native mascot still has a stable layer-2,
        // near-square effect surface, unlike activity cards and task stacks.
        let ratio = bounds.width / max(bounds.height, 1)
        return layer == 2 &&
            bounds.width >= 160 && bounds.width <= 340 &&
            bounds.height >= 190 && bounds.height <= 380 &&
            ratio >= 0.72 && ratio <= 1.25
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let value = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(value.uint32Value)
    }

    private static func isCodexOwner(_ owner: String) -> Bool {
        let normalized = owner.lowercased()
        return normalized.contains("chatgpt") || normalized.contains("codex") || normalized.contains("openai")
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

private enum RevealTiming {
    static let agents: TimeInterval = 8
    static let pressure: TimeInterval = 10
    static let failure: TimeInterval = 6
    static let approval: TimeInterval = 8
    static let spaceChange: TimeInterval = 7
    static let preview: TimeInterval = 12
    static let review: TimeInterval = 8
    static let explorationTail: TimeInterval = 20

    static let status: [String: TimeInterval] = [
        "agents": agents,
        "approval": approval,
        "failure": failure,
        "explorationTail": explorationTail,
        "pressure": pressure,
        "preview": preview,
        "review": review,
        "spaceChange": spaceChange
    ]
}

final class SceneController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let visibility: CompanionVisibility
    private var presentationEnabled = false
    private(set) var panel: NSPanel!
    private var webView: WKWebView!
    private let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    private var schemeHandler: LocalSceneSchemeHandler!
    private var ready = false
    private var pendingCommands: [(String, [String: Any])] = []
    private var pendingPresentation = "background"
    private var pendingPetAnchor = (x: 0.82, y: 0.86)
    private var demotionWorkItem: DispatchWorkItem?
    private var lastRevealAt = Date.distantPast
    private var ignoreInteractionUntil = Date.distantPast
    private var transitionHistory: [[String: Any]] = []
    private(set) var isRevealing = false

    init?(sceneDirectory: URL, visibility: CompanionVisibility) {
        self.visibility = visibility
        let indexURL = sceneDirectory.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        schemeHandler = LocalSceneSchemeHandler(rootDirectory: sceneDirectory)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "rootnote-scene")
        configuration.userContentController.add(self, name: "rootnoteDesktop")
        configuration.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.classList.add('desktop-runtime');",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor

        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        webView.navigationDelegate = self
        panel.contentView = webView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = desktopLevel
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.title = "Rootnote Resonance"
        placeOnPrimaryScreen()
        guard let sceneURL = URL(string: "rootnote-scene://local/index.html") else { return nil }
        webView.load(URLRequest(url: sceneURL))
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rootnoteDesktop")
    }

    func show() {
        guard visibility.sceneVisible else { return }
        panel.orderFrontRegardless()
    }

    func synchronizeVisibility(showRootnote: Bool) {
        if !visibility.sceneVisible {
            hide()
        } else if !presentationEnabled {
            presentationEnabled = true
            setAnimationSuspended(false)
            sinkToDesktop(showRootnote: showRootnote)
        }
    }

    private func setAnimationSuspended(_ suspended: Bool) {
        guard ready else { return }
        webView.evaluateJavaScript("window.RootnoteSceneLifecycle?.setSuspended(\(suspended ? "true" : "false"));")
    }

    func hide() {
        demotionWorkItem?.cancel()
        demotionWorkItem = nil
        pendingCommands.removeAll()
        presentationEnabled = false
        isRevealing = false
        lastRevealAt = .distantPast
        pendingPresentation = "background"
        setAnimationSuspended(true)
        panel.orderOut(nil)
        writeHealthStatus(transition: "hidden")
    }

    func placeOnPrimaryScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        place(on: screen)
    }

    func place(on screen: NSScreen) {
        panel.setFrame(screen.frame, display: true)
    }

    func dispatch(_ type: String, detail: [String: Any] = [:]) {
        guard visibility.sceneVisible else { return }
        guard ready else {
            pendingCommands.append((type, detail))
            if pendingCommands.count > 24 { pendingCommands.removeFirst() }
            return
        }
        guard let typeJSON = jsonFragment(type), let detailJSON = jsonFragment(detail) else { return }
        let script = "window.RootnoteResonance && window.RootnoteResonance.dispatch(\(typeJSON), \(detailJSON));"
        webView.evaluateJavaScript(script)
    }

    func setPetAnchor(x: CGFloat, y: CGFloat) {
        pendingPetAnchor = (Double(x), Double(y))
        guard ready,
              let xJSON = jsonFragment(pendingPetAnchor.x),
              let yJSON = jsonFragment(pendingPetAnchor.y)
        else { return }
        let script = "window.RootnoteResonance && window.RootnoteResonance.setPetAnchor(\(xJSON), \(yJSON));"
        webView.evaluateJavaScript(script)
    }

    func reveal(for duration: TimeInterval, force: Bool, showRootnoteAfter: Bool) {
        guard visibility.sceneVisible else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastRevealAt) >= 8 else { return }
        lastRevealAt = now
        ignoreInteractionUntil = now.addingTimeInterval(0.65)
        isRevealing = true
        demotionWorkItem?.cancel()
        setPresentationMode("reveal")
        panel.level = .floating
        panel.orderFrontRegardless()
        writeHealthStatus(transition: "reveal")

        let token = visibility.generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.visibility.allowsSceneCallback(token) else { return }
            self.sinkToDesktop(showRootnote: showRootnoteAfter)
        }
        demotionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func sinkAfterInteraction(showRootnote: Bool) {
        guard isRevealing, Date() >= ignoreInteractionUntil else { return }
        sinkToDesktop(showRootnote: showRootnote)
    }

    func sinkToDesktop(showRootnote: Bool) {
        guard visibility.sceneVisible else { return }
        demotionWorkItem?.cancel()
        demotionWorkItem = nil
        isRevealing = false
        panel.level = desktopLevel
        setPresentationMode(showRootnote ? "desktop" : "background")
        panel.orderFrontRegardless()
        writeHealthStatus(transition: "sink")
    }

    func refreshBackgroundPresentation(showRootnote: Bool) {
        guard visibility.sceneVisible, !isRevealing else { return }
        setPresentationMode(showRootnote ? "desktop" : "background")
    }

    private func setPresentationMode(_ mode: String) {
        pendingPresentation = mode
        guard ready, let modeJSON = jsonFragment(mode) else { return }
        let script = "window.RootnoteResonance && window.RootnoteResonance.setPresentationMode(\(modeJSON));"
        webView.evaluateJavaScript(script)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "rootnoteDesktop",
              let body = message.body as? [String: Any],
              (body["type"] as? String) == "ready"
        else { return }
        markReady()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        verifyJavaScriptReady(attempt: 0)
    }

    private func verifyJavaScriptReady(attempt: Int) {
        webView.evaluateJavaScript("Boolean(window.RootnoteResonance && window.RootnoteResonance.dispatch)") { [weak self] value, _ in
            guard let self else { return }
            if (value as? Bool) == true {
                self.markReady()
            } else if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.verifyJavaScriptReady(attempt: attempt + 1)
                }
            }
        }
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        setAnimationSuspended(!visibility.sceneVisible)
        setPresentationMode(pendingPresentation)
        setPetAnchor(x: pendingPetAnchor.x, y: pendingPetAnchor.y)
        writeHealthStatus(transition: "ready")
        let commands = pendingCommands
        pendingCommands.removeAll()
        for command in commands { dispatch(command.0, detail: command.1) }
    }

    private func jsonFragment(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeHealthStatus(transition: String) {
        transitionHistory.append([
            "name": transition,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "windowLevel": panel.level.rawValue
        ])
        if transitionHistory.count > 8 { transitionHistory.removeFirst(transitionHistory.count - 8) }
        let status: [String: Any] = [
            "characterOwner": "codex-client",
            "externalPetWindow": false,
            "ready": ready,
            "windowVisible": panel.isVisible,
            "sceneAllowed": visibility.sceneVisible,
            "visibilityGeneration": visibility.generation,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "revealDurations": RevealTiming.status,
            "sceneAnchor": ["x": pendingPetAnchor.x, "y": pendingPetAnchor.y],
            "sceneLayer": isRevealing ? "foreground-reveal" : "desktop-background",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "transitions": transitionHistory,
            "windowFrame": NSStringFromRect(panel.frame),
            "windowLevel": panel.level.rawValue
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = RootnoteRuntimePaths.statusURL("rootnote-resonance-desktop-status.json")
        try? data.write(to: url, options: .atomic)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let visibility = CompanionVisibility()
    private var scene: SceneController?
    private var router: EventRouter?
    private var monitor: SessionMonitor?
    private var overlayMonitor: CharacterOverlayMonitor?
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var interactionMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var petRisk: PetRiskBeaconCoordinator?
    private var approvalBridge: ApprovalBridgeCoordinator?
    private var performanceSummaryItem: NSMenuItem?
    private var performanceDetailsItem: NSMenuItem?
    private var approvalPermissionItem: NSMenuItem?
    private var paused = false
    private var treeActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.removeItem(
            at: RootnoteRuntimePaths.statusURL("rootnote-resonance-pet-status.json")
        )
        installStatusItem()
        guard let resourceURL = Bundle.main.resourceURL else {
            NSApp.terminate(nil)
            return
        }
        let sceneDirectory = resourceURL.appendingPathComponent("scene", isDirectory: true)
        guard let scene = SceneController(sceneDirectory: sceneDirectory, visibility: visibility) else {
            NSAlert(error: NSError(domain: "RootnoteResonance", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Scene resources are missing."
            ])).runModal()
            NSApp.terminate(nil)
            return
        }

        self.scene = scene
        scene.setPetAnchor(x: 0.82, y: 0.86)
        let overlayMonitor = CharacterOverlayMonitor()
        let petRisk = PetRiskBeaconCoordinator(visibility: visibility)
        let approvalBridge = ApprovalBridgeCoordinator()
        self.petRisk = petRisk
        self.approvalBridge = approvalBridge
        petRisk.onSnapshot = { [weak self] snapshot in
            self?.updatePerformanceStatus(snapshot)
        }
        petRisk.onDetailVisibilityChanged = { [weak self] _ in
            self?.updatePerformanceDetailsMenu()
        }
        overlayMonitor.onStableSample = { [weak petRisk] sample in
            petRisk?.updateAnchor(sample)
        }
        overlayMonitor.onSample = { [weak self, weak scene, weak petRisk, weak approvalBridge] sample in
            guard let self, !self.visibility.sleeping else { return }
            self.visibility.setPetAvailable(true)
            scene?.place(on: sample.screen)
            scene?.setPetAnchor(x: sample.x, y: sample.y)
            self.synchronizeVisibility()
            petRisk?.updateAnchor(sample)
            approvalBridge?.updateAnchor(sample)
        }
        overlayMonitor.onUnavailable = { [weak self] in
            self?.visibility.setPetAvailable(false)
            self?.synchronizeVisibility()
        }
        self.overlayMonitor = overlayMonitor
        let router = EventRouter { [weak self] type, detail in
            self?.handleSceneEvent(type, detail: detail)
        }
        self.router = router
        monitor = SessionMonitor(router: router)
        petRisk.start()
        approvalBridge.start()
        paused = UserDefaults.standard.bool(forKey: "desktopScenePaused")
        installNaturalLayering()
        updatePauseState()
        if CommandLine.arguments.contains("--ui-layer-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.previewReveal()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.revalidateVisibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        overlayMonitor?.stop()
        petRisk?.stop()
        approvalBridge?.stop()
        if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        petRisk?.showDetails()
        updatePerformanceDetailsMenu()
        return false
    }

    @objc private func togglePause() {
        paused.toggle()
        UserDefaults.standard.set(paused, forKey: "desktopScenePaused")
        updatePauseState()
    }

    @objc private func returnToCompanion() {
        guard visibility.sceneVisible else { return }
        treeActive = false
        scene?.dispatch("no-task")
        scene?.sinkToDesktop(showRootnote: isFinderFrontmost)
    }

    @objc private func previewReveal() {
        guard visibility.sceneVisible else { return }
        treeActive = true
        scene?.dispatch("agents", detail: ["agents": 5])
        scene?.reveal(for: RevealTiming.preview, force: true, showRootnoteAfter: isFinderFrontmost)
        let token = visibility.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.visibility.allowsSceneCallback(token) else { return }
            self.scene?.dispatch("pressure")
        }
    }

    @objc private func togglePerformanceDetails() {
        petRisk?.toggleDetails()
        updatePerformanceDetailsMenu()
    }

    private func updatePerformanceDetailsMenu() {
        performanceDetailsItem?.title = PetRiskDetailController.menuTitle(
            isVisible: petRisk?.detailsVisible == true
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updatePerformanceDetailsMenu()
    }

    @objc private func refreshPerformance() {
        petRisk?.refresh()
    }

    @objc private func quitUntilLogin() {
        monitor?.stop()
        NSApp.terminate(nil)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = " ⋯"
        item.button?.imagePosition = .imageLeft
        item.button?.toolTip = "Rootnote 性能守卫 · 正在读取"
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Rootnote Resonance · 性能守卫", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let performanceSummary = NSMenuItem(title: "性能状态：正在读取", action: nil, keyEquivalent: "")
        performanceSummary.isEnabled = false
        menu.addItem(performanceSummary)
        menu.addItem(.separator())
        let pauseItem = NSMenuItem(title: "Pause Desktop Scene", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)
        let preview = NSMenuItem(title: "预览生长场景", action: #selector(previewReveal), keyEquivalent: "r")
        preview.target = self
        menu.addItem(preview)
        let companion = NSMenuItem(title: "返回陪伴状态", action: #selector(returnToCompanion), keyEquivalent: "0")
        companion.target = self
        menu.addItem(companion)
        menu.addItem(.separator())
        let performance = NSMenuItem(
            title: PetRiskDetailController.menuTitle(isVisible: false),
            action: #selector(togglePerformanceDetails),
            keyEquivalent: ""
        )
        performance.target = self
        menu.addItem(performance)
        let refreshPerformance = NSMenuItem(
            title: "立即刷新性能",
            action: #selector(refreshPerformance),
            keyEquivalent: ""
        )
        refreshPerformance.target = self
        menu.addItem(refreshPerformance)
        menu.addItem(.separator())
        let approvalPermission = NSMenuItem(
            title: "审批请在 Codex 中处理",
            action: nil,
            keyEquivalent: ""
        )
        approvalPermission.isEnabled = false
        menu.addItem(approvalPermission)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出至下次登录", action: #selector(quitUntilLogin), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        self.pauseItem = pauseItem
        performanceSummaryItem = performanceSummary
        performanceDetailsItem = performance
        approvalPermissionItem = approvalPermission
    }

    private func updatePerformanceStatus(_ snapshot: [String: Any]) {
        guard let state = snapshot["microState"] as? String,
              let level = PetRiskLevel(rawValue: state)
        else { return }
        statusItem?.button?.image = nil
        statusItem?.button?.title = level.menuGlyph
        statusItem?.button?.toolTip = "\(level.accessibilityLabel) · 点击打开性能详情"
        let severity = snapshot["severityLabel"] as? String ?? level.accessibilityLabel
        performanceSummaryItem?.title = "性能状态：\(severity)"
    }

    private func updatePauseState() {
        pauseItem?.title = paused ? "恢复环境效果" : "暂停环境效果"
        visibility.setScenePaused(paused)
        synchronizeVisibility()
        monitor?.start()
        overlayMonitor?.start()
    }

    private func synchronizeVisibility() {
        if !visibility.sceneVisible { treeActive = false }
        scene?.synchronizeVisibility(showRootnote: isFinderFrontmost)
        petRisk?.synchronizeVisibility()
        if !visibility.accessoriesVisible { approvalBridge?.hideOverlay() }
    }

    private func revalidateVisibility() {
        visibility.invalidateAnchor()
        synchronizeVisibility()
        guard !visibility.sleeping else { return }
        overlayMonitor?.refresh()
    }

    private func suspendPresentation(_ reason: CompanionSuspension) {
        visibility.sleep(reason)
        synchronizeVisibility()
        overlayMonitor?.stop()
    }

    private func resumePresentation(_ reason: CompanionSuspension) {
        visibility.wake(reason)
        synchronizeVisibility()
        guard !visibility.sleeping else { return }
        overlayMonitor?.refresh()
        overlayMonitor?.start()
    }

    private var isFinderFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    private func handleSceneEvent(_ type: String, detail: [String: Any]) {
        if type == "approval" {
            approvalBridge?.expectApproval(
                summary: detail["summary"] as? String ?? "Codex 请求执行一项受控操作"
            )
        } else if type == "clear" || type == "complete" || type == "no-task" {
            approvalBridge?.clearExpectedApproval()
        }
        guard visibility.sceneVisible else { return }
        scene?.dispatch(type, detail: detail)
        switch type {
        case "agents":
            treeActive = true
            scene?.reveal(for: RevealTiming.agents, force: false, showRootnoteAfter: isFinderFrontmost)
        case "pressure":
            treeActive = true
            scene?.reveal(for: RevealTiming.pressure, force: true, showRootnoteAfter: isFinderFrontmost)
        case "failure":
            scene?.reveal(for: RevealTiming.failure, force: true, showRootnoteAfter: isFinderFrontmost)
        case "approval":
            if treeActive {
                scene?.reveal(for: RevealTiming.approval, force: false, showRootnoteAfter: isFinderFrontmost)
            }
        case "no-task":
            treeActive = false
            scene?.sinkToDesktop(showRootnote: isFinderFrontmost)
        default:
            break
        }
    }

    private func installNaturalLayering() {
        interactionMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scene?.sinkAfterInteraction(showRootnote: self.isFinderFrontmost)
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.revalidateVisibility()
        })
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.suspendPresentation(event == NSWorkspace.willSleepNotification ? .system : .display)
            })
        }
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.resumePresentation(event == NSWorkspace.didWakeNotification ? .system : .display)
            })
        }
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.scene?.refreshBackgroundPresentation(showRootnote: self.isFinderFrontmost)
        })
    }
}

private func runSelfTest() -> Int32 {
    var events: [[String: Any]] = []
    let router = EventRouter { type, detail in
        var event = detail
        event["type"] = type
        events.append(event)
    }
    router.resetForSession()
    router.handle(["type": "event_msg", "payload": ["type": "user_message"]])
    router.handle([
        "type": "response_item",
        "payload": ["type": "custom_tool_call", "call_id": "a1", "name": "exec", "input": "tools.multi_agent_v1__spawn_agent"]
    ])
    router.handle([
        "type": "response_item",
        "payload": ["type": "custom_tool_call", "call_id": "a2", "name": "exec", "input": "tools.multi_agent_v1__spawn_agent"]
    ])
    router.tick(now: Date().addingTimeInterval(60))
    router.handle([
        "type": "response_item",
        "payload": ["type": "custom_tool_call", "call_id": "approval", "name": "exec", "input": "sandbox_permissions: require_escalated"]
    ])
    router.handle([
        "type": "response_item",
        "payload": ["type": "custom_tool_call_output", "call_id": "approval", "output": "exit_code=0"]
    ])
    router.handle([
        "type": "response_item",
        "payload": ["type": "custom_tool_call", "call_id": "failed", "name": "exec", "input": "build"]
    ])
    router.handle([
        "type": "response_item",
        "payload": ["type": "custom_tool_call_output", "call_id": "failed", "output": "exit_code=1"]
    ])
    router.handle(["type": "event_msg", "payload": ["type": "task_complete"]])

    let types = events.compactMap { $0["type"] as? String }
    let required = ["analysis", "agents", "pressure", "approval", "clear", "failure", "complete"]
    let viewport = CGRect(x: 986, y: 362, width: 356, height: 320)
    let rightMascot = AvatarOverlayGeometry.mascotBounds(
        in: viewport,
        avatarWidth: 123,
        trailDirection: -1
    )
    let leftMascot = AvatarOverlayGeometry.mascotBounds(
        in: viewport,
        avatarWidth: 123,
        trailDirection: 1
    )
    let attachment = AvatarOverlayGeometry.attachment(in: rightMascot, trailDirection: -1)
    let occlusionDepth = attachment.x - rightMascot.minX
    let geometryOK = abs(rightMascot.maxX - (viewport.maxX - 28)) < 0.01
        && abs(leftMascot.minX - (viewport.minX + 28)) < 0.01
        && abs(rightMascot.maxY - (viewport.maxY - 8)) < 0.01
        && occlusionDepth >= rightMascot.width * 0.3
        && attachment.x < rightMascot.midX
        && attachment.y > rightMascot.midY
        && attachment.y < rightMascot.maxY
    let ok = required.allSatisfy(types.contains) && geometryOK
    let report: [String: Any] = [
        "ok": ok,
        "events": events,
        "avatarOverlayGeometry": [
            "ok": geometryOK,
            "viewport": NSStringFromRect(viewport),
            "rightMascot": NSStringFromRect(rightMascot),
            "leftMascot": NSStringFromRect(leftMascot),
            "leftTrailAttachment": NSStringFromPoint(attachment),
            "occlusionDepth": occlusionDepth
        ]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
        print(string)
    }
    return ok ? 0 : 1
}

private func runPetWindowInventory(includeAllStructuralWindows: Bool = false) -> Int32 {
    func readWindows() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
    }

    guard var windowInfo = readWindows() else {
        return 1
    }

    if CommandLine.arguments.contains("--hover"),
       let voiceBacking = windowInfo.first(where: {
           ($0[kCGWindowName as String] as? String) == "Codex Pet Voice Controls Backing"
       }),
       let boundsDictionary = voiceBacking[kCGWindowBounds as String] as? [String: Any],
       let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) {
        let originalCursor = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        Thread.sleep(forTimeInterval: 0.65)
        if let refreshed = readWindows() {
            windowInfo = refreshed
        }
        if let originalCursor {
            CGWarpMouseCursorPosition(originalCursor)
        }
    }

    let rows: [[String: Any]] = windowInfo.compactMap { window in
        guard let owner = window[kCGWindowOwnerName as String] as? String,
              owner == "ChatGPT" || owner == "Codex" ||
                owner.hasPrefix("ChatGPT ") || owner.hasPrefix("Codex ") ||
                owner.hasPrefix("Rootnote Resonance"),
              let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else { return nil }

        let name = window[kCGWindowName as String] as? String ?? ""
        let isStructuralName = name.contains("Pet") || name.contains("pet") ||
            name.contains("Voice") || name.contains("voice") ||
            name.contains("宠物语音") || name.contains("性能微提示") ||
            name == "Codex" || name == "ChatGPT"
        guard includeAllStructuralWindows || isStructuralName else {
            return nil
        }

        return [
            "alpha": window[kCGWindowAlpha as String] as? Double ?? 0,
            "bounds": NSStringFromRect(bounds),
            "layer": window[kCGWindowLayer as String] as? Int ?? -1,
            // Do not expose task or conversation titles in diagnostic output.
            "name": isStructuralName ? name : "<redacted>",
            "nameEmpty": name.isEmpty,
            "number": window[kCGWindowNumber as String] as? Int ?? -1,
            "onScreen": window[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "owner": owner,
        ]
    }

    guard JSONSerialization.isValidJSONObject(rows),
          let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    else { return 1 }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
    return 0
}

private func runAnchorProbe() -> Int32 {
    let monitor = CharacterOverlayMonitor()
    guard let sample = monitor.diagnosticSample() else {
        print("{\"active\":false}")
        return 2
    }
    let report: [String: Any] = [
        "active": true,
        "detectionStrategy": sample.detectionStrategy,
        "displayID": sample.displayID,
        "mascotBounds": NSStringFromRect(sample.mascotBounds),
        "owner": sample.owner,
        "trailSide": sample.trailSide,
        "voiceBackingBounds": sample.voiceBackingBounds.map(NSStringFromRect) ?? "",
        "windowBounds": NSStringFromRect(sample.windowBounds),
        "windowNumber": sample.windowNumber,
    ]
    guard let data = try? JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys]
    ) else { return 1 }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
    return 0
}

if CommandLine.arguments.contains("--sidebar-quota-functional-self-test") {
    exit(runSidebarQuotaFunctionalSelfTest())
}

if CommandLine.arguments.contains("--sidebar-quota-live-read-check") {
    exit(runSidebarQuotaLiveReadCheck())
}

if CommandLine.arguments.contains("--sidebar-quota-self-test") {
    exit(runSidebarQuotaSelfTest())
}

if CommandLine.arguments.contains("--sidebar-quota-presentation-self-test") {
    exit(runSidebarQuotaPresentationSelfTest())
}

if CommandLine.arguments.contains("--sidebar-quota-component-self-test") {
    exit(runSidebarQuotaComponentSelfTest())
}

if CommandLine.arguments.contains("--panel-data-self-test") {
    exit(runPanelDataSelfTest())
}

if CommandLine.arguments.contains("--panel-account-read-check") {
    exit(runPanelDataSelfTest(live: true))
}

if CommandLine.arguments.contains("--panel-live-check") {
    runPanelLiveCheck()
    exit(0)
}

if CommandLine.arguments.contains("--presentation-self-test") {
    exit(runPresentationSelfTest())
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTest())
}

if CommandLine.arguments.contains("--pet-window-inventory") {
    exit(runPetWindowInventory())
}

if CommandLine.arguments.contains("--codex-window-probe") {
    exit(runPetWindowInventory(includeAllStructuralWindows: true))
}

if CommandLine.arguments.contains("--anchor-probe") {
    exit(runAnchorProbe())
}

if CommandLine.arguments.contains("--visibility-self-test") {
    exit(runVisibilitySelfTest())
}

if CommandLine.arguments.contains("--beacon-self-test") {
    exit(runPetRiskBeaconSelfTest())
}

if CommandLine.arguments.contains("--approval-self-test") {
    exit(runApprovalBridgeSelfTest())
}

if CommandLine.arguments.contains("--idle-policy-self-test") {
    let report = PRBRunIdlePolicySelfTest()
    if JSONSerialization.isValidJSONObject(report),
       let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    exit((report["ok"] as? Bool) == true ? 0 : 1)
}

if CommandLine.arguments.contains("--event-parser-self-test") {
    let report = PRBRunEventParsingSelfTest()
    if JSONSerialization.isValidJSONObject(report),
       let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    exit((report["ok"] as? Bool) == true ? 0 : 1)
}

if CommandLine.arguments.contains("--collector-json") {
    let simulate = CommandLine.arguments.contains("--simulate-degraded")
    let snapshot = PRBCollectSnapshot([AnyHashable: Any](), simulate)
    if JSONSerialization.isValidJSONObject(snapshot),
       let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        exit(0)
    }
    exit(1)
}

if Bundle.main.bundleIdentifier == "com.cv.rootnote-sidebar-acceptance" {
    runSidebarQuotaFunctionalAcceptance()
    exit(0)
}

if RootnoteRuntimePaths.isCandidate && !CommandLine.arguments.contains("--observe-live") {
    fputs("隔离 Candidate 默认只运行自测；实屏观察需显式使用 --observe-live。\n", stderr)
    exit(64)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
