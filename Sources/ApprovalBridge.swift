import AppKit
import ApplicationServices
import Foundation

private enum ApprovalResolution {
    case reject
    case allowOnce
}

private enum ApprovalScanResult {
    case none
    case one(reject: AXUIElement, allowOnce: AXUIElement)
    case ambiguous
}

private struct PendingApprovalRequest {
    let key: String
    let summary: String
    let observedAt: Date
    let sequence: Int
}

private final class ApprovalActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Watches all recently active Codex sessions instead of following only the
/// newest JSONL file. This is required because approvals may be raised by a
/// different task than the one that most recently wrote a session event.
private final class ApprovalRequestMonitor {
    var onPendingChanged: ((String?) -> Void)?

    private let root: URL
    private var timer: Timer?
    private var files: [URL] = []
    private var offsets: [URL: UInt64] = [:]
    private var partials: [URL: String] = [:]
    private var pending: [String: PendingApprovalRequest] = [:]
    private var sequence = 0
    private var lastDiscovery = Date.distantPast
    private var lastEmittedKey: String?

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    ) {
        self.root = root
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        files.removeAll()
        offsets.removeAll()
        partials.removeAll()
        pending.removeAll()
        lastEmittedKey = nil
    }

    private func poll() {
        let now = Date()
        if now.timeIntervalSince(lastDiscovery) >= 1.5 {
            discoverRecentFiles(now: now)
            lastDiscovery = now
        }
        files.forEach(readAppendedLines)
        pending = pending.filter { now.timeIntervalSince($0.value.observedAt) < 90 * 60 }
        emitIfChanged()
    }

    private func discoverRecentFiles(now: Date) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var candidates: [(url: URL, date: Date, size: UInt64)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) < 2 * 60 * 60
            else { continue }
            candidates.append((url, modified, UInt64(values.fileSize ?? 0)))
        }
        candidates.sort { $0.date > $1.date }
        files = Array(candidates.prefix(20).map(\.url))

        for candidate in candidates.prefix(20) where offsets[candidate.url] == nil {
            let maximumInitialRead: UInt64 = 6 * 1024 * 1024
            offsets[candidate.url] = candidate.size > maximumInitialRead
                ? candidate.size - maximumInitialRead
                : 0
            partials[candidate.url] = ""
        }
    }

    private func readAppendedLines(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber
        else { return }
        let size = number.uint64Value
        var offset = offsets[url] ?? 0
        if size < offset {
            offset = 0
            partials[url] = ""
        }
        guard size > offset,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8)
            else { return }
            offsets[url] = offset + UInt64(data.count)
            let combined = (partials[url] ?? "") + chunk
            var lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
            partials[url] = combined.hasSuffix("\n") ? "" : String(lines.popLast() ?? "")
            for line in lines where !line.isEmpty {
                handleLine(String(line), sessionURL: url)
            }
        } catch {
            return
        }
    }

    private func handleLine(_ line: String, sessionURL: URL) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let payload = object["payload"] as? [String: Any] ?? object
        let itemType = payload["type"] as? String ?? ""

        if itemType == "custom_tool_call" || itemType == "function_call" {
            let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? ""
            guard !callID.isEmpty else { return }
            let content = Self.toolContent(payload)
            guard Self.isApprovalRequest(content) else { return }
            sequence += 1
            let key = "\(sessionURL.path)#\(callID)"
            pending[key] = PendingApprovalRequest(
                key: key,
                summary: Self.approvalSummary(payload, fallback: content),
                observedAt: Self.timestamp(from: object) ?? Date(),
                sequence: sequence
            )
        } else if itemType == "custom_tool_call_output" || itemType == "function_call_output" {
            guard let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String)
            else { return }
            pending.removeValue(forKey: "\(sessionURL.path)#\(callID)")
        } else if itemType == "task_complete" {
            let prefix = "\(sessionURL.path)#"
            pending = pending.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    private func emitIfChanged() {
        let latest = pending.values.max { $0.sequence < $1.sequence }
        guard latest?.key != lastEmittedKey else { return }
        lastEmittedKey = latest?.key
        onPendingChanged?(latest?.summary)
    }

    private static func toolContent(_ payload: [String: Any]) -> String {
        var parts: [String] = []
        for key in ["name", "input", "arguments"] {
            guard let value = payload[key] else { continue }
            if let text = value as? String {
                parts.append(text)
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let text = String(data: data, encoding: .utf8) {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func isApprovalRequest(_ content: String) -> Bool {
        let value = content.lowercased()
        return value.contains("require_escalated") ||
            value.contains("request_user_input") ||
            value.contains("\"approval\"")
    }

    private static func approvalSummary(
        _ payload: [String: Any],
        fallback: String
    ) -> String {
        for key in ["input", "arguments"] {
            if let dictionary = payload[key] as? [String: Any],
               let summary = preferredSummary(in: dictionary) {
                return summary
            }
            if let string = payload[key] as? String,
               let summary = preferredSummary(in: string) {
                return summary
            }
        }
        let compact = fallback.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return String(compact.prefix(120))
    }

    private static func preferredSummary(in dictionary: [String: Any]) -> String? {
        for key in ["justification", "question", "cmd", "command", "path"] {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return String(value.prefix(160))
            }
        }
        for value in dictionary.values {
            if let nested = value as? [String: Any],
               let summary = preferredSummary(in: nested) {
                return summary
            }
        }
        return nil
    }

    private static func preferredSummary(in string: String) -> String? {
        if let data = string.data(using: .utf8),
           let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let summary = preferredSummary(in: dictionary) {
            return summary
        }
        let patterns = [
            #"justification\s*:\s*"([^"]+)""#,
            #"justification\s*:\s*'([^']+)'"#,
            #""justification"\s*:\s*"([^"]+)""#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: string,
                    range: NSRange(string.startIndex..., in: string)
                  ),
                  let range = Range(match.range(at: 1), in: string)
            else { continue }
            return String(string[range].prefix(160))
        }
        return nil
    }

    private static func timestamp(from object: [String: Any]) -> Date? {
        guard let value = object["timestamp"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

private final class ApprovalActionDockController: NSObject {
    private let panel: NSPanel
    private let visualEffect: NSVisualEffectView
    private let rejectButton = ApprovalActionButton(title: "拒绝", target: nil, action: nil)
    private let allowButton = ApprovalActionButton(title: "允许一次", target: nil, action: nil)
    private var rejectWidthConstraint: NSLayoutConstraint!
    private var allowLeadingConstraint: NSLayoutConstraint!
    private var lastSample: CharacterOverlaySample?
    private var failureReset: DispatchWorkItem?

    var onReject: (() -> Void)?
    var onAllowOnce: (() -> Void)?
    var onRequestPermission: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 124, height: 26),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        visualEffect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        super.init()

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Assign after `isFloatingPanel`; otherwise AppKit resets this to the
        // ordinary floating level shared by Codex's transparent pet surfaces.
        panel.level = .modalPanel
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.title = "Rootnote 宠物气泡审批操作"
        panel.appearance = NSAppearance(named: .darkAqua)

        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 9
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.borderWidth = 0.6
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        visualEffect.layer?.backgroundColor =
            NSColor(srgbRed: 0.06, green: 0.075, blue: 0.08, alpha: 0.92).cgColor
        visualEffect.translatesAutoresizingMaskIntoConstraints = false

        configureButton(rejectButton, action: #selector(reject))
        configureButton(allowButton, action: #selector(allowOnce))
        allowButton.keyEquivalent = "\r"

        guard let content = panel.contentView else { return }
        content.addSubview(visualEffect)
        [rejectButton, allowButton].forEach(visualEffect.addSubview)
        rejectWidthConstraint = rejectButton.widthAnchor.constraint(equalToConstant: 46)
        allowLeadingConstraint = allowButton.leadingAnchor.constraint(
            equalTo: rejectButton.trailingAnchor,
            constant: 3
        )
        NSLayoutConstraint.activate([
            visualEffect.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            visualEffect.topAnchor.constraint(equalTo: content.topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rejectButton.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 3),
            rejectButton.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 3),
            rejectButton.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -3),
            rejectWidthConstraint,
            allowLeadingConstraint,
            allowButton.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -3),
            allowButton.topAnchor.constraint(equalTo: rejectButton.topAnchor),
            allowButton.bottomAnchor.constraint(equalTo: rejectButton.bottomAnchor),
        ])
        applyReadyStyle()
    }

    func updateAnchor(_ sample: CharacterOverlaySample) {
        lastSample = sample
        guard panel.isVisible else { return }
        place(near: sample)
    }

    func showReady(summary _: String) {
        applyTwoActionLayout()
        rejectButton.isHidden = false
        rejectButton.title = "拒绝"
        rejectButton.isEnabled = true
        rejectButton.action = #selector(reject)
        allowButton.title = "允许一次"
        allowButton.isEnabled = true
        allowButton.action = #selector(allowOnce)
        rejectButton.toolTip = "拒绝当前这一项原生审批"
        allowButton.toolTip = "只允许当前这一次；不扩大到本会话"
        applyReadyStyle()
        show()
    }

    func showPermissionRequired(summary _: String) {
        hide()
    }

    func showAmbiguous(summary _: String) {
        applyTwoActionLayout()
        rejectButton.isHidden = false
        rejectButton.title = "拒绝"
        rejectButton.isEnabled = false
        allowButton.title = "允许一次"
        allowButton.isEnabled = false
        let message = "检测到多个或不完整的原生审批，快捷操作已停止；请回 Codex 处理"
        rejectButton.toolTip = message
        allowButton.toolTip = message
        applyUnavailableStyle()
        show()
    }

    func showResolutionFailure(_ text: String) {
        failureReset?.cancel()
        visualEffect.layer?.borderColor =
            NSColor(srgbRed: 1, green: 0.35, blue: 0.34, alpha: 0.82).cgColor
        rejectButton.toolTip = text
        allowButton.toolTip = text
        NSSound.beep()
        let reset = DispatchWorkItem { [weak self] in self?.applyReadyStyle() }
        failureReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: reset)
    }

    func hide() {
        failureReset?.cancel()
        panel.orderOut(nil)
    }

    func clearAnchor() {
        lastSample = nil
        hide()
    }

    private func show() {
        if let lastSample {
            place(near: lastSample)
        } else {
            panel.orderOut(nil)
            return
        }
        panel.orderFrontRegardless()
    }

    private func place(near sample: CharacterOverlaySample) {
        guard let activityBounds = Self.activityStackBounds(near: sample) else {
            panel.orderOut(nil)
            return
        }
        let displayBounds = CGDisplayBounds(sample.displayID)
        let size = panel.frame.size
        let localMaxX = activityBounds.maxX - displayBounds.minX
        let localBottom = activityBounds.maxY - displayBounds.minY
        let visible = sample.screen.visibleFrame.insetBy(dx: 4, dy: 4)
        // CGWindow bounds use a top-left origin while AppKit uses bottom-left.
        // Expanded cards expose the Follow up row at the bottom; compact cards
        // only expose the title row. Keep the actions in the matching native row.
        let preferredX = sample.screen.frame.minX + localMaxX - size.width - 8
        let cardBottomY = sample.screen.frame.maxY - localBottom
        let rowInset = activityBounds.height >= 80
            ? 8
            : max((activityBounds.height - size.height) / 2, 0)
        let preferredY = cardBottomY + rowInset
        panel.setFrameOrigin(NSPoint(
            x: min(max(preferredX, visible.minX), visible.maxX - size.width),
            y: min(max(preferredY, visible.minY), visible.maxY - size.height)
        ))
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.cornerCurve = .continuous
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func applyTwoActionLayout() {
        rejectWidthConstraint.constant = 46
        allowLeadingConstraint.constant = 3
    }

    private func applyPermissionLayout() {
        rejectWidthConstraint.constant = 0
        allowLeadingConstraint.constant = 0
    }

    private func applyReadyStyle() {
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        rejectButton.contentTintColor = NSColor.white.withAlphaComponent(0.80)
        rejectButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        allowButton.contentTintColor = NSColor(srgbRed: 0.72, green: 0.91, blue: 0.81, alpha: 1)
        allowButton.layer?.backgroundColor =
            NSColor(srgbRed: 0.32, green: 0.69, blue: 0.49, alpha: 0.16).cgColor
    }

    private func applyPermissionStyle() {
        visualEffect.layer?.borderColor =
            NSColor(srgbRed: 0.95, green: 0.70, blue: 0.27, alpha: 0.45).cgColor
        rejectButton.contentTintColor = .clear
        rejectButton.layer?.backgroundColor = NSColor.clear.cgColor
        allowButton.contentTintColor =
            NSColor(srgbRed: 0.95, green: 0.72, blue: 0.33, alpha: 0.92)
        allowButton.layer?.backgroundColor =
            NSColor(srgbRed: 0.95, green: 0.70, blue: 0.27, alpha: 0.11).cgColor
    }

    private func applyUnavailableStyle() {
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        rejectButton.contentTintColor = NSColor.white.withAlphaComponent(0.32)
        rejectButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.025).cgColor
        allowButton.contentTintColor = NSColor.white.withAlphaComponent(0.32)
        allowButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.025).cgColor
    }

    private static func activityStackBounds(near sample: CharacterOverlaySample) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else { return nil }

        let exact = windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowName as String] as? String) ==
                    "Codex Pet Activity Stack Backing",
                  let dictionary = window[kCGWindowBounds as String] as? [String: Any]
            else { return nil }
            return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }.first
        if let exact { return exact }

        return windows.compactMap { window -> (CGRect, CGFloat)? in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  Self.isCodexOwner(owner),
                  let layer = Self.intValue(window[kCGWindowLayer as String]),
                  (2...4).contains(layer),
                  let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width >= 300, bounds.width <= 390,
                  bounds.height >= 44, bounds.height <= 120,
                  // The activity card is fully above the mascot. This excludes
                  // the 384x134 pet container that was previously selected when
                  // macOS withheld window titles without Screen Recording access.
                  bounds.maxY <= sample.mascotBounds.minY + 2
            else { return nil }
            let centerDistance = abs(bounds.midX - sample.mascotBounds.midX)
            let verticalDistance = abs(bounds.maxY - sample.mascotBounds.minY)
            let knownHeightDistance = min(
                abs(bounds.height - 54),
                abs(bounds.height - 94)
            )
            let sizeDistance = abs(bounds.width - 345) * 1.4 +
                knownHeightDistance * 3.0
            return (
                bounds,
                sizeDistance + centerDistance * 0.15 + verticalDistance * 0.15
            )
        }
        .min(by: { $0.1 < $1.1 })?
        .0
    }

    private static func isCodexOwner(_ owner: String) -> Bool {
        let value = owner.lowercased()
        return value.contains("chatgpt") || value.contains("codex") ||
            value.contains("openai")
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    @objc private func reject() {
        writeClickReceipt("reject")
        onReject?()
    }

    @objc private func allowOnce() {
        writeClickReceipt("allow-once")
        onAllowOnce?()
    }

    @objc private func requestPermission() {
        writeClickReceipt("request-permission")
        onRequestPermission?()
    }

    private func writeClickReceipt(_ action: String) {
        let receipt: [String: Any] = [
            "action": action,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: receipt,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(
            to: RootnoteRuntimePaths.statusURL("rootnote-resonance-approval-click.json"),
            options: .atomic
        )
    }
}

final class ApprovalBridgeCoordinator {
    private let panel = ApprovalActionDockController()
    private let requestMonitor = ApprovalRequestMonitor()
    private var timer: Timer?
    private var routedExpectedSummary: String?
    private var monitoredExpectedSummary: String?
    private var scanning = false
    private var lastStatusWrite = Date.distantPast

    private var expectedSummary: String? {
        monitoredExpectedSummary ?? routedExpectedSummary
    }

    init() {
        requestMonitor.onPendingChanged = { [weak self] summary in
            self?.monitoredExpectedSummary = summary
            self?.poll()
        }
    }

    func start() {
        // Shared desktop approval requests are unavailable; do not scan logs
        // for an action that this process cannot safely complete.
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        requestMonitor.stop()
        panel.clearAnchor()
    }

    func updateAnchor(_ sample: CharacterOverlaySample) {
        panel.updateAnchor(sample)
    }

    func hideOverlay() {
        panel.clearAnchor()
    }

    func expectApproval(summary: String) {
        routedExpectedSummary = summary.isEmpty ? "Codex 请求执行一项受控操作" : summary
        poll()
    }

    func clearExpectedApproval() {
        routedExpectedSummary = nil
        if monitoredExpectedSummary == nil { panel.hide() }
    }

    private func poll() {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        // Rootnote can detect that a Codex task is waiting, but it does not own
        // the server-initiated app-server approval request. Accessibility
        // clicking is not a protocol bridge and proved unreliable in live use,
        // so the sidecar must never present approval buttons or open Settings.
        panel.hide()
        writeStatus(
            trusted: false,
            nativeMatch: expectedSummary == nil
                ? "none"
                : "blocked-no-shared-approval-transport"
        )
    }

    private func writeStatus(trusted: Bool, nativeMatch: String) {
        let now = Date()
        guard now.timeIntervalSince(lastStatusWrite) >= 1.5 else { return }
        lastStatusWrite = now
        let status: [String: Any] = [
            "trusted": trusted,
            "pendingDetected": expectedSummary != nil,
            "nativeMatch": nativeMatch,
            "timestamp": ISO8601DateFormatter().string(from: now),
            "bodyPersisted": false
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: status,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(
            to: RootnoteRuntimePaths.statusURL("rootnote-resonance-approval-status.json"),
            options: .atomic
        )
    }

    private func resolve(_: ApprovalResolution) {
        panel.showResolutionFailure("Rootnote 未持有 Codex 审批请求，未执行任何操作")
    }

    private func scanNativeApproval() -> ApprovalScanResult {
        .none
    }

    private static let rejectLabels: Set<String> = ["拒绝", "Decline"]
    private static let allowOnceLabels: Set<String> = ["允许一次", "Allow once"]

    private static func isCodexHost(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName?.lowercased() ?? ""
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        return name == "chatgpt" || name == "codex" ||
            bundle == "com.openai.chat" || bundle.contains("openai.chatgpt")
    }

    private static func elementLabel(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let value = attributeString(element, key as CFString), !value.isEmpty {
                return value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }
        }
        return ""
    }

    private static func attributeString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func attributeChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }
}

func runApprovalBridgeSelfTest() -> Int32 {
    let reject = Set(["拒绝", "Decline"])
    let allow = Set(["允许一次", "Allow once"])
    let persistentExcluded = !allow.contains("本会话允许") && !allow.contains("Allow for session")
    let disjoint = reject.isDisjoint(with: allow)
    let monitorOK = runApprovalRequestMonitorSelfTest()
    let report: [String: Any] = [
        "ok": persistentExcluded && disjoint && monitorOK,
        "rejectLabels": Array(reject).sorted(),
        "allowOnceLabels": Array(allow).sorted(),
        "persistentApprovalExcluded": persistentExcluded,
        "ambiguousMatchPolicy": "fail-closed",
        "approvalTransport": "blocked-no-shared-approval-transport",
        "directActionsDisplayed": false,
        "opensSystemSettings": false,
        "multiSessionMonitor": monitorOK,
    ]
    if let data = try? JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys]
    ), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    return (report["ok"] as? Bool) == true ? 0 : 1
}

private func runApprovalRequestMonitorSelfTest() -> Bool {
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(
            "rootnote-approval-monitor-\(UUID().uuidString)",
            isDirectory: true
        )
    let first = root.appendingPathComponent("2026/07/31/first.jsonl")
    let second = root.appendingPathComponent("2026/07/31/second.jsonl")
    do {
        try fileManager.createDirectory(
            at: first.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let approval: [String: Any] = [
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call",
                "call_id": "approval-1",
                "name": "exec",
                "input": """
                    await tools.exec_command({
                      sandbox_permissions: "require_escalated",
                      justification: "跨任务审批测试"
                    })
                    """
            ]
        ]
        let unrelated: [String: Any] = [
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call",
                "call_id": "ordinary-1",
                "name": "exec",
                "input": "await tools.exec_command({cmd: \"pwd\"})"
            ]
        ]
        try jsonLine(approval).write(to: first, atomically: true, encoding: .utf8)
        try jsonLine(unrelated).write(to: second, atomically: true, encoding: .utf8)

        let monitor = ApprovalRequestMonitor(root: root)
        var observed: String?
        var cleared = false
        monitor.onPendingChanged = { summary in
            if let summary {
                observed = summary
            } else if observed != nil {
                cleared = true
            }
        }
        monitor.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))

        let output: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call_output",
                "call_id": "approval-1",
                "output": "exit_code=0"
            ]
        ]
        let handle = try FileHandle(forWritingTo: first)
        try handle.seekToEnd()
        try handle.write(contentsOf: jsonLine(output).data(using: .utf8) ?? Data())
        try handle.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
        monitor.stop()
        try? fileManager.removeItem(at: root)
        return observed == "跨任务审批测试" && cleared
    } catch {
        try? fileManager.removeItem(at: root)
        return false
    }
}

private func jsonLine(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    return (String(data: data, encoding: .utf8) ?? "") + "\n"
}
