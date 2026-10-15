import AppKit
import CryptoKit
import Foundation

enum RootnotePanelPaths {
    static var resources: URL? {
        if let path = ProcessInfo.processInfo.environment["ROOTNOTE_RESOURCES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return Bundle.main.resourceURL
    }

    static var state: URL {
        if let path = ProcessInfo.processInfo.environment["ROOTNOTE_PANEL_STATE"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if RootnoteRuntimePaths.isCandidate {
            return FileManager.default.temporaryDirectory.appendingPathComponent("rootnote-panel-development")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Rootnote/Panel")
    }
}

enum RootnoteReadError: Error {
    case unavailable, loginRequired, unsupportedAccount, timeout, disconnected, service, invalid, accountChanged

    var userMessage: String {
        switch self {
        case .unavailable: return "未找到可用的 Codex 连接，请检查应用安装。"
        case .loginRequired: return "尚未登录 Codex，登录后可同步额度。"
        case .unsupportedAccount: return "当前登录方式不提供账号额度，请在 Codex 中查看。"
        case .timeout: return "同步超时，稍后可重试。已有记录保留。"
        case .accountChanged: return "账号状态发生变化，请刷新后确认。已有记录保留。"
        case .invalid: return "暂未取得完整额度数据，已有记录保留。"
        case .disconnected, .service: return "暂时无法同步，稍后可重试。已有记录保留。"
        }
    }
}

// A short-lived, read-only client. It never attaches to a thread or handles credentials.
final class RootnoteAccountReader {
    private let condition = NSCondition()
    private var responses: [Int: [String: Any]] = [:]
    private var buffer = Data()
    private var disconnected = false
    private var changed = false
    private var sequence = 0
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let deadline = Date().addingTimeInterval(25)

    func read() throws -> [String: Any] {
        let locations = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        guard let executable = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw RootnoteReadError.unavailable }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let bytes = handle.availableData
            self.condition.lock()
            defer { self.condition.broadcast(); self.condition.unlock() }
            if bytes.isEmpty { self.disconnected = true; return }
            self.buffer.append(bytes)
            if self.buffer.count > 2_000_000 { self.disconnected = true; return }
            while let end = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.prefix(upTo: end)
                self.buffer.removeSubrange(...end)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                if let id = object["id"] as? Int { self.responses[id] = object }
                if object["method"] as? String == "account/updated" { self.changed = true }
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        try process.run()
        _ = try call("initialize", ["clientInfo": ["name": "rootnote_readonly", "version": "0.10.0"]])
        try send(["method": "initialized"])
        let before = try call("account/read", ["refreshToken": false])
        guard let account = before["account"] as? [String: Any] else { throw RootnoteReadError.loginRequired }
        guard account["type"] as? String == "chatgpt" else { throw RootnoteReadError.unsupportedAccount }
        condition.lock(); changed = false; condition.unlock()
        let limits = try call("account/rateLimits/read", [:])
        let after = try call("account/read", ["refreshToken": false])
        condition.lock(); let didChange = changed; condition.unlock()
        guard !didChange, NSDictionary(dictionary: before).isEqual(to: after) else {
            throw RootnoteReadError.accountChanged
        }
        return try Self.sanitize(account: account, limits: limits)
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        guard ["initialize", "account/read", "account/rateLimits/read"].contains(method)
        else { throw RootnoteReadError.invalid }
        sequence += 1
        let id = sequence
        try send(["id": id, "method": method, "params": params])
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil && !disconnected && Date() < deadline {
            _ = condition.wait(until: deadline)
        }
        guard let response = responses.removeValue(forKey: id) else {
            throw Date() >= deadline ? RootnoteReadError.timeout : RootnoteReadError.disconnected
        }
        guard response["error"] == nil else { throw RootnoteReadError.service }
        guard let result = response["result"] as? [String: Any] else { throw RootnoteReadError.invalid }
        return result
    }

    static func sanitize(account: [String: Any], limits: [String: Any]) throws -> [String: Any] {
        guard let accountID = limits["accountId"] as? String, !accountID.isEmpty,
              let email = account["email"] as? String, !email.isEmpty else { throw RootnoteReadError.invalid }
        let identity = accountID + "\n" + email.lowercased()
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let parts = email.split(separator: "@", maxSplits: 1)
        let label = String(parts[0].prefix(2)) + "•••" + (parts.count == 2 ? "@" + String(parts[1]) : "")
        let raw = limits["rateLimitsByLimitId"] as? [String: Any]
            ?? ["codex": limits["rateLimits"] ?? [:]]
        let buckets: [[String: Any]] = raw.keys.sorted().compactMap { id in
            guard let bucket = raw[id] as? [String: Any] else { return nil }
            var windows: [[String: Any]] = []
            for slot in ["primary", "secondary"] {
                guard let window = bucket[slot] as? [String: Any] else { continue }
                var clean: [String: Any] = ["slot": slot]
                if let used = number(window["usedPercent"]), (0...100).contains(used) { clean["usedPercent"] = used }
                if let minutes = number(window["windowDurationMins"]), minutes > 0 { clean["minutes"] = minutes }
                if let reset = number(window["resetsAt"]), reset > 0 { clean["resetsAt"] = reset }
                windows.append(clean)
            }
            return ["id": String(id.prefix(100)), "name": String((bucket["limitName"] as? String ?? id).prefix(100)), "windows": windows]
        }
        var result: [String: Any] = ["id": key, "label": label, "plan": account["planType"] as? String ?? "未知",
                                   "updatedAt": Date().timeIntervalSince1970, "buckets": buckets]
        if let creditInfo = limits["rateLimitResetCredits"] as? [String: Any] {
            var credits: [String: Any] = [:]
            if let count = number(creditInfo["availableCount"]), count >= 0, count.rounded() == count { credits["availableCount"] = count }
            if let rows = creditInfo["credits"] as? [[String: Any]] {
                credits["items"] = rows.prefix(50).map { row -> [String: Any] in
                    var clean: [String: Any] = [:]
                    for field in ["status", "resetType", "title"] {
                        if let value = row[field] as? String { clean[field] = String(value.prefix(160)) }
                    }
                    if let expiry = number(row["expiresAt"]), expiry > 0 { clean["expiresAt"] = expiry }
                    return clean
                }
            }
            result["resetCredits"] = credits
        }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
}

final class RootnotePanelStore {
    var onChange: (() -> Void)?
    private(set) var accounts: [[String: Any]] = []
    private(set) var currentAccount: String?
    private(set) var lastKnownAccount: String?
    private(set) var settings: [String: Any] = ["appearance": "light", "giftReminder": true, "resetReminder": true, "leadDays": 3, "quiet": false]
    private(set) var syncing = false
    private(set) var error: String?
    private var timer: Timer?
    private var generation = 0

    init() {
        // Preserve the effective appearance once when migrating the old automatic mode.
        settings["appearance"] = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        let file = RootnotePanelPaths.state.appendingPathComponent("panel.json")
        var needsAppearanceMigration = !FileManager.default.fileExists(atPath: file.path)
        if let data = try? Data(contentsOf: file), data.count < 500_000,
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            needsAppearanceMigration = true
            accounts = Array((saved["accounts"] as? [[String: Any]] ?? []).prefix(8))
            if let stored = saved["settings"] as? [String: Any] {
                needsAppearanceMigration = !["light", "dark"].contains(stored["appearance"] as? String ?? "")
                for (key, value) in stored { set(key: key, value: value, persist: false) }
            }
        }
        if needsAppearanceMigration { save() }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var payload: [String: Any] {
        ["accounts": accounts, "currentAccount": currentAccount as Any? ?? NSNull(),
         "lastKnownAccount": lastKnownAccount as Any? ?? NSNull(),
         "settings": settings, "syncing": syncing, "error": error as Any? ?? NSNull(),
         "approvalAvailable": false, "now": Date().timeIntervalSince1970]
    }

    var reminder: String? {
        guard settings["quiet"] as? Bool != true else { return nil }
        let now = Date().timeIntervalSince1970
        let horizon = Double(settings["leadDays"] as? Int ?? 3) * 86400
        for account in accounts {
            let credits = (account["resetCredits"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            if settings["giftReminder"] as? Bool == true,
               credits.contains(where: { ($0["status"] as? String) == "available" && ($0["expiresAt"] as? Double ?? 0) > now && ($0["expiresAt"] as? Double ?? 0) - now <= horizon }) {
                return "\(account["label"] as? String ?? "账号") · 赠送机会即将到期"
            }
            if settings["resetReminder"] as? Bool == true {
                for bucket in account["buckets"] as? [[String: Any]] ?? [] {
                    for window in bucket["windows"] as? [[String: Any]] ?? [] {
                        if let reset = window["resetsAt"] as? Double, reset <= now,
                           reset > (account["updatedAt"] as? Double ?? now) { return "\(account["label"] as? String ?? "账号") · 已到预计重置时间" }
                    }
                }
            }
        }
        return nil
    }

    func refresh() {
        guard !syncing else { return }
        syncing = true; error = nil
        lastKnownAccount = currentAccount ?? lastKnownAccount
        currentAccount = nil
        let expected = generation
        onChange?()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = RootnoteAccountReader()
            let result = Result { try withExtendedLifetime(reader) { try reader.read() } }
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncing = false
                guard self.generation == expected else { self.onChange?(); return }
                switch result {
                case .success(let account):
                    self.currentAccount = account["id"] as? String
                    self.lastKnownAccount = self.currentAccount
                    self.accounts.removeAll { $0["id"] as? String == self.currentAccount }
                    self.accounts.insert(account, at: 0)
                    self.accounts = Array(self.accounts.prefix(8))
                    self.save()
                case .failure(let failure):
                    self.currentAccount = nil
                    self.error = ((failure as? RootnoteReadError) ?? .disconnected).userMessage
                }
                self.onChange?()
            }
        }
    }

    func set(key: String, value: Any, persist: Bool = true) {
        if key == "appearance", let mode = value as? String, ["light", "dark"].contains(mode) {
            settings[key] = mode
        } else if key == "leadDays", let days = value as? Int, [1, 3, 7].contains(days) {
            settings[key] = days
        } else if ["giftReminder", "resetReminder", "quiet"].contains(key),
                  let bool = value as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() {
            settings[key] = bool.boolValue
        } else { return }
        if persist { save(); onChange?() }
    }

    func clearAccounts() {
        generation += 1; accounts = []; currentAccount = nil; lastKnownAccount = nil; error = nil
        save(); onChange?()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: RootnotePanelPaths.state, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: ["accounts": accounts, "settings": settings])
            let file = RootnotePanelPaths.state.appendingPathComponent("panel.json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { self.error = "本地设置未能保存，请检查磁盘空间与目录权限。" }
    }
}

func runPanelDataSelfTest(live: Bool = false) -> Int32 {
    do {
        if live {
            let reader = RootnoteAccountReader()
            let account = try withExtendedLifetime(reader) { try reader.read() }
            let report: [String: Any] = ["ok": true, "bucketCount": (account["buckets"] as? [Any])?.count ?? 0,
                "resetCredits": account["resetCredits"] ?? NSNull(), "credentialsPersisted": false, "mutations": 0]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data); print("")
            return 0
        }
        let input: [String: Any] = ["accountId": "sample-only-account", "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 24, "windowDurationMins": 300, "resetsAt": 1000], "secondary": NSNull()]], "rateLimitResetCredits": ["availableCount": 2, "credits": NSNull()]]
        let result = try RootnoteAccountReader.sanitize(account: ["email": "sample@example.test", "planType": "plus", "accessToken": "must-not-leak"], limits: input)
        let data = try JSONSerialization.data(withJSONObject: result)
        let text = String(data: data, encoding: .utf8) ?? ""
        let buckets = result["buckets"] as? [[String: Any]] ?? []
        let other = try RootnoteAccountReader.sanitize(account: ["email": "other@example.test"], limits: input)
        let partial = try RootnoteAccountReader.sanitize(account: ["email": "sample@example.test"], limits: [
            "accountId": "sample", "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": NSNull(), "windowDurationMins": 300, "resetsAt": 1000]]],
            "rateLimitResetCredits": ["availableCount": 2, "credits": [
                ["id": "private-credit", "resetType": "codexRateLimits", "status": "available", "expiresAt": 2000],
                ["status": "available", "expiresAt": 3000]]]])
        let partialWindows = ((partial["buckets"] as? [[String: Any]])?.first?["windows"] as? [[String: Any]]) ?? []
        let partialText = String(data: try JSONSerialization.data(withJSONObject: partial), encoding: .utf8) ?? ""
        let checks = ["identity_hashed": (result["id"] as? String)?.count == 64,
                      "accounts_have_distinct_keys": result["id"] as? String != other["id"] as? String,
                      "email_masked": !text.contains("sample@example.test"),
                      "credentials_excluded": !text.contains("must-not-leak") && !text.contains("accessToken"),
                      "missing_window_not_zero": (buckets.first?["windows"] as? [Any])?.count == 1,
                      "unknown_expiry_not_invented": !text.contains("expiresAt"),
                      "timeout_not_login_failure": RootnoteReadError.timeout.userMessage.contains("超时") && !RootnoteReadError.timeout.userMessage.contains("登录"),
                      "service_error_not_login_failure": !RootnoteReadError.service.userMessage.contains("登录"),
                      "login_failure_explicit": RootnoteReadError.loginRequired.userMessage.contains("登录"),
                      "account_change_not_assumed_switch": RootnoteReadError.accountChanged.userMessage.contains("账号状态") && !RootnoteReadError.accountChanged.userMessage.contains("切换"),
                      "partial_quota_keeps_known_period": partialWindows.first?["minutes"] as? Double == 300,
                      "partial_quota_not_zero": partialWindows.first?["usedPercent"] == nil,
                      "gift_rows_kept": (partial["resetCredits"] as? [String: Any])?["items"] is [[String: Any]],
                      "gift_identifiers_excluded": !partialText.contains("private-credit")]
        print(String(data: try JSONSerialization.data(withJSONObject: ["ok": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        return checks.values.allSatisfy { $0 } ? 0 : 1
    } catch {
        let reason = (error as? RootnoteReadError).map { String(describing: $0) } ?? "read_failed"
        print("{\"ok\":false,\"error\":\"\(reason)\"}"); return 1
    }
}
