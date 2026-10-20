import AppKit
import ApplicationServices

// Only the independent, manually launched acceptance bundle enters this lifecycle.
// No AppDelegate, CompanionVisibility, scene, pet monitor, or performance collector is constructed.
private final class SidebarQuotaFunctionalDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let sidebar = SidebarQuotaCoordinator()
    private lazy var details = PetRiskDetailController()
    private var window: NSWindow!
    private var status: NSTextField!
    private var running = false
    private var location = "尚未开始"
    private var dataStatus = "尚未同步"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出额度验收", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 350),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Rootnote 额度功能验收 · \(version)"
        window.delegate = self; window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "真实额度与现有额度页")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "开始后读取当前登录账号的真实周额度，未同步时显示“待同步”。\n点击侧栏胶囊打开额度页，再点一次关闭。\n此独立验收应用不与现用 Rootnote 共用窗口；正式使用请退出本应用。")
        explanation.font = .systemFont(ofSize: 14); explanation.textColor = .secondaryLabelColor
        status = NSTextField(wrappingLabelWithString: "尚未开始。点击“开始功能验收”后切回 Codex。")
        status.font = .systemFont(ofSize: 13)
        let start = NSButton(title: "开始功能验收", target: self, action: #selector(begin))
        let open = NSButton(title: "打开额度页", target: self, action: #selector(openQuota))
        let stop = NSButton(title: "停止并查看结果", target: self, action: #selector(stop))
        let quit = NSButton(title: "退出", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        for button in [start, open, stop, quit] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [start, open, stop, quit]); buttons.spacing = 12
        let stack = NSStackView(views: [heading, explanation, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 23
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28)
            ])
        }
        SidebarQuotaConnection.connect(sidebar: sidebar, details: details) { [weak self] payload in
            guard let self, self.running else { return }
            if payload["syncing"] as? Bool == true { self.dataStatus = "正在同步当前账号" }
            else if let error = payload["error"] as? String { self.dataStatus = error }
            else {
                let value = SidebarQuotaValue.read(payload, now: Date().timeIntervalSince1970)
                self.dataStatus = value.remaining == nil ? "尚未取得有效周额度，胶囊显示待同步" : "真实周额度：剩余 \(value.text)"
            }
            self.renderStatus()
        }
        sidebar.onDiagnostic = { [weak self] failure in
            guard let self, self.running else { return }
            self.location = failure?.message ?? "已请求原位置显示"
            self.renderStatus()
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func renderStatus() { status.stringValue = "\(dataStatus)\n侧栏：\(location)" }
    @objc private func begin() {
        guard AXIsProcessTrusted() else {
            status.stringValue = "请在系统设置的辅助功能中开启本验收应用，再回来开始。只读取侧栏边界，不发送按键或点击。"
            return
        }
        running = true; location = "等待切回 Codex"; dataStatus = "正在同步当前账号"
        details.startAccountSync(); sidebar.start(); renderStatus()
    }
    @objc private func openQuota() { details.showQuota() }
    @objc private func stop() {
        running = false
        sidebar.stop(); details.stopAccountSync(); details.hide()
        status.stringValue = "已停止同步并隐藏胶囊和额度页。\n最近定位：\(location)。"
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationWillTerminate(_ notification: Notification) { stop() }
}

func runSidebarQuotaFunctionalAcceptance() {
    guard RootnoteRuntimePaths.isCandidate,
          Bundle.main.bundleIdentifier == "com.cv.rootnote-sidebar-acceptance" else { return }
    if ProcessInfo.processInfo.environment["ROOTNOTE_PANEL_STATE"] == nil {
        let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("functional-state")
        setenv("ROOTNOTE_PANEL_STATE", directory.path, 1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.appearance = NSAppearance(named: .darkAqua)
    let delegate = SidebarQuotaFunctionalDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

// Tests the real reader's sanitized result, without constructing any target UI adapter.
func runSidebarQuotaLiveReadCheck() -> Int32 {
    guard RootnoteRuntimePaths.isCandidate else { return 2 }
    do {
        let reader = RootnoteAccountReader()
        let account = try withExtendedLifetime(reader) { try reader.read() }
        let payload: [String: Any] = ["currentAccount": account["id"] ?? NSNull(), "accounts": [account],
                                      "settings": ["appearance": "dark"], "syncing": false]
        let value = SidebarQuotaValue.read(payload, now: Date().timeIntervalSince1970)
        let verifyPage = CommandLine.arguments.contains("--verify-existing-quota-page")
        let pageOK = !verifyPage || verifyExistingQuotaPage(account: account, expected: value.remaining)
        let report: [String: Any] = ["ok": value.remaining != nil && pageOK, "remainingPercent": value.remaining as Any? ?? NSNull(),
            "displayText": value.text, "weeklyWindowValid": value.remaining != nil,
            "scope": verifyPage ? "readonly_account_api_and_own_existing_quota_page" : "readonly_account_api_only", "liveCodexUIInspected": false,
            "existingQuotaPageVerified": verifyPage ? pageOK as Any : NSNull(),
            "credentialsExported": false, "accountIdentityExported": false, "petControlCalls": 0]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        return value.remaining == nil || !pageOK ? 1 : 0
    } catch {
        let reason = (error as? RootnoteReadError).map { String(describing: $0) } ?? "read_failed"
        print("{\"ok\":false,\"error\":\"\(reason)\",\"scope\":\"readonly_account_api_only\"}")
        return 1
    }
}

private final class SidebarQuotaFixtureReader {
    private let lock = NSLock()
    private var mode = 0
    private var gate: DispatchSemaphore?
    private(set) var started = 0
    func configure(_ mode: Int, gate: DispatchSemaphore? = nil) {
        lock.lock(); self.mode = mode; self.gate = gate; lock.unlock()
    }
    func calls() -> Int { lock.lock(); defer { lock.unlock() }; return started }
    func read() throws -> [String: Any] {
        lock.lock(); let mode = self.mode, gate = self.gate; started += 1; lock.unlock()
        if let gate, gate.wait(timeout: .now() + 6) == .timedOut { throw RootnoteReadError.timeout }
        if mode == 1 { throw RootnoteReadError.timeout }
        return try RootnoteAccountReader.sanitize(account: ["email": mode == 2 ? "other@example.test" : "sample@example.test"],
            limits: ["accountId": mode == 2 ? "other-fixture" : "first-fixture", "rateLimitsByLimitId": ["codex": [
                "primary": ["windowDurationMins": 300, "usedPercent": 7],
                "secondary": ["windowDurationMins": 10080, "usedPercent": mode == 2 ? 82 : 31,
                              "resetsAt": Date().timeIntervalSince1970 + 3600]]]])
    }
}

func runSidebarQuotaFunctionalSelfTest() -> Int32 {
    guard RootnoteRuntimePaths.isCandidate, CommandLine.arguments.contains("--presentation-self-test"),
          ProcessInfo.processInfo.environment["ROOTNOTE_PANEL_STATE"] != nil else { return 2 }
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    let source = SidebarQuotaFixtureReader()
    let store = RootnotePanelStore(readAccount: { try source.read() })
    let details = PetRiskDetailController(store: store), sidebar = SidebarQuotaCoordinator()
    var snapshots = 0, checks: [String: Bool] = [:]
    SidebarQuotaConnection.connect(sidebar: sidebar, details: details) { _ in snapshots += 1 }
    func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(6)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
    func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
    checks["no_fixture_percentage_before_sync"] = sidebar.currentValue.remaining == nil
    details.startAccountSync()
    checks["sanitized_reader_store_shared_connection_to_capsule"] = wait { !store.syncing && sidebar.currentValue.remaining == 69 }
    checks["same_payload_reaches_existing_details_and_sidebar"] = snapshots >= 2 && store.currentAccount != nil
    sidebar.onOpen?()
    checks["capsule_callback_opens_existing_detail"] = wait { details.detailVisible }
    sidebar.onOpen?(); drain()
    checks["repeat_callback_closes_shared_panel"] = !details.detailVisible
    details.toggle()
    checks["performance_entry_reopens_shared_panel"] = details.detailVisible
    sidebar.onOpen?(); drain()
    checks["sidebar_closes_performance_entry_panel"] = !details.detailVisible
    sidebar.onOpen?()
    checks["sidebar_reopens_after_cross_entry_close"] = wait { details.detailVisible }
    details.toggle()
    checks["performance_entry_closes_sidebar_panel"] = !details.detailVisible
    checks["closing_details_keeps_synced_quota"] = !details.detailVisible && sidebar.currentValue.remaining == 69
    source.configure(1); store.refresh()
    checks["refresh_does_not_present_unconfirmed_identity"] = sidebar.currentValue.remaining == nil
    checks["failed_sync_shows_unknown_preserves_history"] = wait { !store.syncing && store.error != nil } && sidebar.currentValue.remaining == nil && store.accounts.count == 1
    sidebar.onOpen?()
    checks["unknown_still_opens_existing_quota_page"] = wait { details.detailVisible }
    details.hide(); source.configure(2); store.refresh()
    checks["changed_account_never_reuses_previous_quota"] = wait { !store.syncing && sidebar.currentValue.remaining == 18 } && store.accounts.count == 2
    let old = DispatchSemaphore(value: 0), newer = DispatchSemaphore(value: 0)
    let calls = source.calls()
    source.configure(0, gate: old); store.refresh()
    checks["old_request_started"] = wait { source.calls() > calls }
    details.stopAccountSync()
    source.configure(2, gate: newer); store.refresh()
    checks["new_request_started_after_stop"] = wait { source.calls() > calls + 1 }
    old.signal(); drain()
    checks["late_stopped_request_cannot_end_new_sync"] = store.syncing && store.currentAccount == nil && sidebar.currentValue.remaining == nil
    newer.signal()
    checks["new_sync_owns_final_identity_and_value"] = wait { !store.syncing && sidebar.currentValue.remaining == 18 }
    let cleared = DispatchSemaphore(value: 0), beforeClear = source.calls()
    source.configure(0, gate: cleared); store.refresh(); _ = wait { source.calls() > beforeClear }
    store.clearAccounts(); cleared.signal(); drain()
    checks["cleared_inflight_response_cannot_restore_history_or_sync_flag"] = !store.syncing && store.accounts.isEmpty && sidebar.currentValue.remaining == nil
    details.stopAccountSync(); details.hide(); sidebar.stop()
    checks["stop_invalidates_current_identity"] = store.currentAccount == nil && !store.syncing
    let report: [String: Any] = ["ok": checks.values.allSatisfy { $0 }, "checks": checks,
        "scope": "isolated_existing_store_details_sidebar_connection", "realAccountRead": false,
        "liveCodexInspected": false, "targetAnchorReaderStarted": false, "petControlCalls": 0]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data); print("")
    }
    return checks.values.allSatisfy { $0 } ? 0 : 1
}
