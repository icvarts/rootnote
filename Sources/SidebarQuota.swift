import AppKit
import ApplicationServices
import WebKit

// Read-only compatibility adapter for desktop mode and each chrome theme's surface.
// Never queries target UI, auth, sessions, or Rootnote panel settings.
struct SidebarHostTheme {
    let mode: String
    let surfaces: [String: String]
    func appearance(systemDark: Bool) -> String? {
        guard let selected = SidebarHostAppearance.resolve(mode: mode, systemDark: systemDark) else { return nil }
        guard let surface = surfaces[selected] else { return selected }
        guard let rgb = Int(surface.dropFirst(), radix: 16) else { return nil }
        // Pick the foreground/background pair with greater contrast against the actual
        // custom surface; a light mode can deliberately have a dark custom background.
        func linear(_ byte: Int) -> Double {
            let n = Double(byte) / 255
            return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((rgb >> 16) & 255) + 0.7152 * linear((rgb >> 8) & 255) + 0.0722 * linear(rgb & 255)
        return (1.05 / (luminance + 0.05)) >= ((luminance + 0.05) / 0.05) ? "dark" : "light"
    }
}

enum SidebarHostAppearance {
    static func mode(_ source: String) -> String? { settings(source)?.mode }
    static func settings(_ source: String) -> SidebarHostTheme? {
        // Collect TOML statements while respecting strings, comments and compound values.
        // Unsupported/malformed forms fail closed instead of guessing a light/dark mode.
        let chars = Array(source)
        var statements: [String] = [], current = "", quote: Character?, triple = false
        var escaped = false, comment = false, depth = 0, index = 0
        while index < chars.count {
            let c = chars[index]
            if comment {
                if c == "\n" { comment = false; if depth == 0 { statements.append(current); current = "" } }
            } else if let q = quote {
                current.append(c)
                if escaped { escaped = false }
                else if q == "\"" && c == "\\" { escaped = true }
                else if c == q {
                    if triple {
                        if index + 2 < chars.count, chars[index + 1] == q, chars[index + 2] == q {
                            current.append(q); current.append(q); index += 2; quote = nil; triple = false
                        }
                    } else { quote = nil }
                } else if c == "\n" && !triple { return nil }
            } else if c == "#" { comment = true }
            else if c == "\"" || c == "'" {
                quote = c; current.append(c)
                triple = index + 2 < chars.count && chars[index + 1] == c && chars[index + 2] == c
                if triple { current.append(c); current.append(c); index += 2 }
            } else if c == "[" || c == "{" { depth += 1; current.append(c) }
            else if c == "]" || c == "}" { depth -= 1; if depth < 0 { return nil }; current.append(c) }
            else if c == "\n" && depth == 0 { statements.append(current); current = "" }
            else { current.append(c) }
            index += 1
        }
        guard quote == nil, depth == 0 else { return nil }
        statements.append(current)
        func path(_ raw: String) -> [String]? {
            let pattern = #"^\s*(?:[A-Za-z0-9_-]+|"[A-Za-z0-9_-]+"|'[A-Za-z0-9_-]+')(?:\s*\.\s*(?:[A-Za-z0-9_-]+|"[A-Za-z0-9_-]+"|'[A-Za-z0-9_-]+'))*\s*$"#
            guard raw.range(of: pattern, options: .regularExpression) != nil else { return nil }
            return raw.split(separator: ".").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        // Split only at top-level separators. Quoted commas and nested inline tables
        // belong to their value, not to a new appearance assignment.
        func split(_ text: String, on separator: Character) -> [String]? {
            var result: [String] = [], part = "", q: Character?, escape = false, level = 0
            for c in text {
                if let active = q {
                    part.append(c)
                    if escape { escape = false }
                    else if active == "\"" && c == "\\" { escape = true }
                    else if c == active { q = nil }
                } else if c == "\"" || c == "'" { q = c; part.append(c) }
                else if c == "{" || c == "[" { level += 1; part.append(c) }
                else if c == "}" || c == "]" { level -= 1; if level < 0 { return nil }; part.append(c) }
                else if c == separator && level == 0 { result.append(part); part = "" }
                else { part.append(c) }
            }
            guard q == nil, level == 0 else { return nil }
            result.append(part); return result
        }
        var table: [String] = [], found: String?, surfaces: [String: String] = [:]
        let themes = ["appearanceLightChromeTheme": "light", "appearanceDarkChromeTheme": "dark"]
        func apply(_ full: [String], _ value: String) -> Bool {
            if full == ["desktop", "appearanceTheme"] {
                guard found == nil, ["\"system\"", "\"light\"", "\"dark\"", "'system'", "'light'", "'dark'"].contains(value) else { return false }
                found = String(value.dropFirst().dropLast()); return true
            }
            if full.count == 3, full.first == "desktop", full.last == "surface", let mode = themes[full[1]] {
                guard surfaces[mode] == nil, value.range(of: ##"^(?:"#[0-9a-fA-F]{6}"|'#[0-9a-fA-F]{6}')$"##, options: .regularExpression) != nil else { return false }
                surfaces[mode] = String(value.dropFirst().dropLast()); return true
            }
            if full == ["desktop"] || (full.count == 2 && full[0] == "desktop" && themes[full[1]] != nil) {
                guard value.hasPrefix("{"), value.hasSuffix("}"), let members = split(String(value.dropFirst().dropLast()), on: ",") else { return false }
                for member in members where !member.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let pair = split(member, on: "="), pair.count == 2, let key = path(pair[0]),
                          apply(full + key, pair[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
                }
            }
            return true
        }
        for raw in statements {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                let array = line.hasPrefix("[[")
                let count = array ? 2 : 1
                guard line.hasSuffix(array ? "]]" : "]") else { return nil }
                // Arbitrary quoted keys are outside this adapter; never interpret their contents as a mode.
                table = path(String(line.dropFirst(count).dropLast(count))) ?? ["<unsupported>"]
                if array { table.append("<array>") }
                continue
            }
            guard let equal = line.firstIndex(of: "=") else { return nil }
            let key = path(String(line[..<equal])) ?? ["<unsupported>"]
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard apply(table + key, value) else { return nil }
        }
        return SidebarHostTheme(mode: found ?? "system", surfaces: surfaces)
    }
    static func resolve(mode: String, systemDark: Bool) -> String? {
        switch mode {
        case "dark", "light": return mode
        case "system": return systemDark ? "dark" : "light"
        default: return nil
        }
    }
}

final class SidebarHostAppearanceReader {
    private let url: URL
    private let read: (URL) throws -> String
    private var nextRead: TimeInterval = 0
    private var theme: SidebarHostTheme?
    init(url: URL? = nil, read: @escaping (URL) throws -> String = { url in
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }) {
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.url = url ?? base.appendingPathComponent("config.toml")
        self.read = read
    }
    func appearance(now: TimeInterval, systemDark: Bool) -> String? {
        if now >= nextRead {
            nextRead = now + 0.5
            do { theme = SidebarHostAppearance.settings(try read(url)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { theme = .init(mode: "system", surfaces: [:]) }
            catch { theme = nil }
        }
        return theme?.appearance(systemDark: systemDark)
    }
}

// These models are deliberately independent of CompanionVisibility and pet geometry.
struct SidebarQuotaValue {
    let remaining: Double?
    let appearance: String
    var reduceTransparency = false
    var text: String {
        guard let remaining else { return "—" }
        return remaining > 0 && remaining < 1 ? "<1%" : "\(Int(floor(remaining)))%"
    }
    var payload: [String: Any] {
        ["remaining": remaining as Any? ?? NSNull(), "text": text,
         "appearance": appearance, "reduceTransparency": reduceTransparency,
         "low": remaining.map { $0 <= 10 } ?? false]
    }
    static func number(_ input: Any?) -> Double? {
        guard let value = input as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    static func read(_ payload: [String: Any], now: TimeInterval, appearance: String = "dark", reduceTransparency: Bool = false) -> Self {
        let unknown = Self(remaining: nil, appearance: appearance, reduceTransparency: reduceTransparency)
        guard payload["error"] == nil || payload["error"] is NSNull,
              payload["syncing"] as? Bool != true,
              let id = payload["currentAccount"] as? String, !id.isEmpty,
              let accounts = payload["accounts"] as? [[String: Any]] else { return unknown }
        let matches = accounts.filter { $0["id"] as? String == id }
        guard matches.count == 1, let account = matches.first,
              let updated = number(account["updatedAt"]), now - updated >= -5, now - updated <= 300 else { return unknown }
        let buckets = (account["buckets"] as? [[String: Any]] ?? []).filter { $0["id"] as? String == "codex" }
        guard buckets.count == 1 else { return unknown }
        let weeks = (buckets[0]["windows"] as? [[String: Any]] ?? []).filter { number($0["minutes"]) == 10080 }
        guard weeks.count == 1, let used = number(weeks[0]["usedPercent"]), (0...100).contains(used) else { return unknown }
        if let reset = number(weeks[0]["resetsAt"]), reset <= now { return unknown }
        return Self(remaining: 100 - used, appearance: appearance, reduceTransparency: reduceTransparency)
    }
}

struct SidebarAnchorNode {
    let parent: Int?
    let role: String
    let domID: String
    let frame: CGRect?
    let profile: Bool
    var subrole: String = ""
}

enum SidebarQuotaAccountButton {
    static func matches(role: String, attribute: (String) -> String?) -> Bool {
        guard ["AXButton", "AXPopUpButton"].contains(role) else { return false }
        let labels: Set<String> = ["打开个人资料菜单", "Open profile menu", "打开设置", "Open settings"]
        // Chromium exposes accessible names through AXDescription or AXTitle.
        // Exact known labels only; never infer account identity from initials or location.
        return ["AXDescription", "AXTitle"].contains { key in
            guard let value = attribute(key) else { return false }
            return labels.contains(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// Coarse product diagnostics only: no UI text, coordinates, or tree export.
enum SidebarQuotaFailure: String, Error {
    case permission, targetMissing, targetHidden, windowUnavailable, minimized
    case scanTimeout, scanLimit, sidebarMissing, sidebarAmbiguous
    case profileMissing, profileAmbiguous, footerMissing, navigationMissing, geometryBlocked
    case sidebarTooNarrow, positionOccupied
    case windowListUnavailable, windowMismatch, occluded, windowChanged, componentUnavailable, appearanceUnavailable
    var message: String {
        switch self {
        case .permission: return "辅助功能权限尚未生效"
        case .targetMissing: return "未找到唯一的 Codex 应用"
        case .targetHidden: return "Codex 当前已隐藏"
        case .windowUnavailable: return "未读到 Codex 主窗口边界"
        case .minimized: return "Codex 窗口已最小化"
        case .scanTimeout: return "侧栏识别超时"
        case .scanLimit: return "侧栏识别达到节点上限"
        case .sidebarMissing: return "未识别到侧栏锚点"
        case .sidebarAmbiguous: return "识别到多个侧栏锚点"
        case .profileMissing: return "未识别到侧栏账号按钮"
        case .profileAmbiguous: return "侧栏账号按钮不唯一"
        case .footerMissing: return "未识别到账号区上沿"
        case .navigationMissing: return "未识别到唯一的应用导航条"
        case .geometryBlocked: return "约定位置空间不足或与原生内容重叠"
        case .sidebarTooNarrow: return "当前侧栏宽度无法容纳确认尺寸及边距，已停止显示"
        case .positionOccupied: return "约定位置与原生内容重叠，已停止显示"
        case .windowListUnavailable: return "未取得可见窗口列表"
        case .windowMismatch: return "窗口边界匹配未通过"
        case .occluded: return "约定位置被其他窗口遮挡"
        case .windowChanged: return "识别期间窗口发生变化，等待下一次检查"
        case .componentUnavailable: return "胶囊页面尚未准备完成"
        case .appearanceUnavailable: return "暂时无法确认宿主外观，已暂停显示"
        }
    }
}

// Find sidebar identifiers without querying frames of unrelated conversation nodes.
// Then inspect only the exact sidebar subtree. Both phases share one bounded budget.
enum SidebarAnchorScanner {
    static func scan<Handle>(root: Handle, children: (Handle) -> [Handle], identifier: (Handle) -> String,
                             snapshot: (Handle, Int?) -> SidebarAnchorNode,
                             now: () -> TimeInterval, budget: TimeInterval = 1.5,
                             limit: Int = 1800) -> Result<[SidebarAnchorNode], SidebarQuotaFailure> {
        let deadline = now() + budget
        var visited = 0
        func check() -> SidebarQuotaFailure? {
            if now() >= deadline { return .scanTimeout }
            if visited >= limit { return .scanLimit }
            visited += 1
            return nil
        }
        var pending = [root], roots: [Handle] = []
        while let element = pending.popLast() {
            if let failure = check() { return .failure(failure) }
            if identifier(element) == "app-shell-sidebar" { roots.append(element); continue }
            let next = children(element)
            guard pending.count + next.count + visited <= limit else { return .failure(.scanLimit) }
            pending.append(contentsOf: next.reversed())
        }
        guard !roots.isEmpty else { return .failure(.sidebarMissing) }
        guard roots.count == 1, let sidebar = roots.first else { return .failure(.sidebarAmbiguous) }
        var nodes: [SidebarAnchorNode] = [], subtree: [(Handle, Int?)] = [(sidebar, nil)]
        while let (element, parent) = subtree.popLast() {
            if let failure = check() { return .failure(failure) }
            let index = nodes.count
            nodes.append(snapshot(element, parent))
            let next = children(element)
            guard subtree.count + next.count + visited <= limit else { return .failure(.scanLimit) }
            subtree.append(contentsOf: next.reversed().map { ($0, index) })
        }
        guard now() < deadline else { return .failure(.scanTimeout) }
        return .success(nodes)
    }
}

enum SidebarQuotaGeometry {
    static let size = CGSize(width: 32, height: 116)
    static let gap: CGFloat = 12
    static let padding: CGFloat = 4
    static let backgroundOutset: CGFloat = 2
    static let hitInset = CGSize(width: 2, height: 10)
    static func background(_ capsule: CGRect) -> CGRect { capsule.insetBy(dx: -backgroundOutset, dy: 0) }
    static func canvas(_ capsule: CGRect) -> CGRect { background(capsule).insetBy(dx: -padding, dy: -padding) }
    static func hit(_ capsule: CGRect) -> CGRect { capsule.insetBy(dx: hitInset.width, dy: hitInset.height) }
    static func allowsForeground(_ front: pid_t, target: pid_t, own: pid_t) -> Bool {
        // Closing our detail window leaves the accessory app active on macOS.
        // Keep the capsule eligible; real window occlusion is checked separately.
        front == target || front == own
    }
    static func valid(_ r: CGRect) -> Bool {
        [r.minX, r.minY, r.width, r.height].allSatisfy { $0.isFinite } && r.width > 0 && r.height > 0
    }
    static func movingSnapshot(reference: [SidebarAnchorNode], observed: [SidebarAnchorNode],
                               from: CGRect, to: CGRect) -> [SidebarAnchorNode]? {
        guard valid(from), valid(to), from.size == to.size, reference.count == observed.count,
              zip(reference, observed).allSatisfy({ $0.0.frame?.size == $0.1.frame?.size }) else { return nil }
        return reference.map { n in
            .init(parent: n.parent, role: n.role, domID: n.domID,
                  frame: n.frame?.offsetBy(dx: to.minX - from.minX, dy: to.minY - from.minY),
                  profile: n.profile, subrole: n.subrole)
        }
    }
    static func frame(window: CGRect, sidebar: CGRect, navigation: CGRect, account: CGRect, controls: [CGRect]) -> CGRect? {
        guard valid(window), valid(sidebar), valid(navigation), valid(account),
              window.insetBy(dx: -1, dy: -1).contains(sidebar),
              sidebar.insetBy(dx: -1, dy: -1).contains(navigation),
              navigation.insetBy(dx: -1, dy: -1).contains(account),
              abs(navigation.minX - sidebar.minX) <= 1,
              abs(navigation.maxY - sidebar.maxY) <= 1,
              account.height < navigation.height / 3,
              navigation.maxY - account.maxY >= -1,
              navigation.maxY - account.maxY <= 12 else { return nil }
        let result = CGRect(x: navigation.midX - size.width / 2, y: account.minY - gap - size.height,
                            width: size.width, height: size.height)
        let canvas = Self.canvas(result)
        guard navigation.insetBy(dx: -0.5, dy: -0.5).contains(canvas),
              !controls.contains(where: { valid($0) && $0.intersection(canvas).width > 0.5 && $0.intersection(canvas).height > 0.5 })
        else { return nil }
        return result
    }
    static func resolve(window: CGRect, nodes: [SidebarAnchorNode]) -> CGRect? {
        try? resolution(window: window, nodes: nodes).get()
    }
    static func resolution(window: CGRect, nodes: [SidebarAnchorNode]) -> Result<CGRect, SidebarQuotaFailure> {
        let roots = nodes.indices.filter { nodes[$0].domID == "app-shell-sidebar" }
        guard !roots.isEmpty else { return .failure(.sidebarMissing) }
        guard roots.count == 1, let root = roots.first else { return .failure(.sidebarAmbiguous) }
        guard let sidebar = nodes[root].frame, valid(sidebar) else { return .failure(.geometryBlocked) }
        func under(_ index: Int, ancestor: Int) -> Bool {
            var cursor: Int? = index
            var visited = Set<Int>()
            while let i = cursor, nodes.indices.contains(i), visited.insert(i).inserted {
                if i == ancestor { return true }
                cursor = nodes[i].parent
            }
            return false
        }
        let profiles = nodes.indices.filter { nodes[$0].profile && under($0, ancestor: root) }
        guard !profiles.isEmpty else { return .failure(.profileMissing) }
        guard profiles.count == 1, let profile = profiles.first else { return .failure(.profileAmbiguous) }
        // Verified Children chain: sidebar -> navigation landmark -> account wrapper -> profile.
        // The wrapper is 36x36, inset 8 from the left and 4 from the bottom; it is not a footer.
        let navigationCandidates = nodes.indices.filter {
            nodes[$0].subrole == "AXLandmarkNavigation" && under($0, ancestor: root) && under(profile, ancestor: $0)
        }
        guard navigationCandidates.count == 1, let nav = navigationCandidates.first,
              let navigation = nodes[nav].frame, valid(navigation) else { return .failure(.navigationMissing) }
        guard navigation.width >= gap + size.width + backgroundOutset + padding - 0.5 else { return .failure(.sidebarTooNarrow) }
        guard let wrapper = nodes[profile].parent, nodes.indices.contains(wrapper),
              nodes[wrapper].parent == nav, nodes[wrapper].role == "AXGroup",
              nodes.indices.filter({ nodes[$0].parent == wrapper }) == [profile],
              let account = nodes[wrapper].frame, valid(account),
              let button = nodes[profile].frame, valid(button),
              account.insetBy(dx: -1, dy: -1).contains(button),
              abs(account.minX - button.minX) <= 1, abs(account.minY - button.minY) <= 1,
              abs(account.width - button.width) <= 1, abs(account.height - button.height) <= 1
        else { return .failure(.footerMissing) }
        let roles: Set<String> = ["AXButton", "AXLink", "AXTextField", "AXTextArea", "AXRow", "AXSlider", "AXCheckBox", "AXPopUpButton", "AXStaticText", "AXImage"]
        let controls = nodes.indices.compactMap { i -> CGRect? in
            guard under(i, ancestor: root), !under(i, ancestor: wrapper),
                  roles.contains(nodes[i].role), let r = nodes[i].frame else { return nil }
            return r
        }
        guard let frame = frame(window: window, sidebar: sidebar, navigation: navigation, account: account, controls: []) else {
            return .failure(.geometryBlocked)
        }
        guard Self.frame(window: window, sidebar: sidebar, navigation: navigation, account: account, controls: controls) != nil else {
            return .failure(.positionOccupied)
        }
        return .success(frame)
    }
    static func cocoa(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

struct SidebarQuotaAttachment {
    let frame: CGRect // Quartz global top-left coordinates.
    let windowID: Int
    let pid: pid_t
}

enum SidebarQuotaOcclusion {
    static func blocks(layer: Int, owner: pid_t, own: pid_t) -> Bool {
        // Preserve normal-window occlusion and don't cover this app's pinned detail
        // or utility panels. The host's oversized transparent pet canvas is unrelated.
        layer == 0 || (owner == own && layer >= NSWindow.Level.floating.rawValue)
    }
}

// Product-side read-only adapter. Never invoked by fixture self-tests.
// Uses public AX reads only; no presses, focus writes, permissions prompts, or pet state.
final class SidebarQuotaAnchorReader {
    private struct AnchorCache {
        let window: AXUIElement
        let bounds: CGRect
        let entries: [(AXUIElement, SidebarAnchorNode)]
        let edges: [(AXUIElement, [AXUIElement])]
    }
    private var cache: AnchorCache?
    private var cachedWindowID: Int?
    private func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
        return value
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
        guard (attribute(element, "AXHidden" as CFString) as? Bool) != true else { return nil }
        guard let p = attribute(element, kAXPositionAttribute as CFString),
              let s = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        let r = CGRect(origin: point, size: size)
        return SidebarQuotaGeometry.valid(r) ? r : nil
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }
    private func cachedNodes(window: AXUIElement) -> [SidebarAnchorNode]? {
        guard let cache, CFEqual(cache.window, window) else { return nil }
        // Revalidate the real navigation Children chain on every fast follow tick.
        // Only this subtree can intersect a canvas that must remain entirely inside the rail.
        for (element, expected) in cache.edges {
            let current = children(element)
            guard current.count == expected.count,
                  zip(current, expected).allSatisfy({ CFEqual($0.0, $0.1) }) else { return nil }
        }
        for (element, node) in cache.entries {
            if node.domID == "app-shell-sidebar",
               attribute(element, "AXDOMIdentifier" as CFString) as? String != node.domID { return nil }
            if node.subrole == "AXLandmarkNavigation",
               attribute(element, kAXSubroleAttribute as CFString) as? String != node.subrole { return nil }
            if node.profile {
                let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
                guard SidebarQuotaAccountButton.matches(role: role, attribute: { self.attribute(element, $0 as CFString) as? String }) else { return nil }
            }
        }
        return cache.entries.map { element, node in
            .init(parent: node.parent, role: node.role, domID: node.domID,
                  frame: rect(element), profile: node.profile, subrole: node.subrole)
        }
    }
    private func remember(window: AXUIElement, bounds: CGRect, handles: [AXUIElement], nodes: [SidebarAnchorNode]) {
        guard let root = nodes.indices.first(where: { nodes[$0].domID == "app-shell-sidebar" }),
              let profile = nodes.indices.first(where: { nodes[$0].profile }),
              let wrapper = nodes[profile].parent, nodes.indices.contains(wrapper),
              let nav = nodes[wrapper].parent, nodes.indices.contains(nav),
              nodes[nav].subrole == "AXLandmarkNavigation"
        else { cache = nil; return }
        func belowNav(_ i: Int) -> Bool {
            var cursor: Int? = i, seen = Set<Int>()
            while let n = cursor, nodes.indices.contains(n), seen.insert(n).inserted {
                if n == nav { return true }; cursor = nodes[n].parent
            }
            return false
        }
        let keep = nodes.indices.filter { $0 == root || belowNav($0) }
        let map = Dictionary(uniqueKeysWithValues: keep.enumerated().map { ($0.element, $0.offset) })
        let entries: [(AXUIElement, SidebarAnchorNode)] = keep.map { i in
            let n = nodes[i]
            return (handles[i], .init(parent: n.parent.flatMap { map[$0] }, role: n.role, domID: n.domID,
                                     frame: n.frame, profile: n.profile, subrole: n.subrole))
        }
        cache = AnchorCache(window: window, bounds: bounds, entries: entries, edges: keep.map { (handles[$0], children(handles[$0])) })
    }
    func read(pid: pid_t, excluding ownWindows: Set<Int>) -> Result<SidebarQuotaAttachment, SidebarQuotaFailure> {
        guard AXIsProcessTrusted() else { return .failure(.permission) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        guard let raw = attribute(app, kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .failure(.windowUnavailable) }
        let window = raw as! AXUIElement
        guard let bounds = rect(window) else { return .failure(.windowUnavailable) }
        guard (attribute(window, kAXMinimizedAttribute as CFString) as? Bool) != true else { return .failure(.minimized) }
        var handles: [AXUIElement] = []
        let scan: Result<[SidebarAnchorNode], SidebarQuotaFailure>
        if let cached = cachedNodes(window: window) {
            scan = .success(cached)
        } else {
        cache = nil
        cachedWindowID = nil
            scan = SidebarAnchorScanner.scan(root: window, children: { element in
                self.children(element)
            }, identifier: { element in
                self.attribute(element, "AXDOMIdentifier" as CFString) as? String ?? ""
            }, snapshot: { element, parent in
                handles.append(element)
                let role = self.attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
                let domID = self.attribute(element, "AXDOMIdentifier" as CFString) as? String ?? ""
                // Only classify the known account button; never query AXValue or conversation text.
                let profile = SidebarQuotaAccountButton.matches(role: role) { key in
                    self.attribute(element, key as CFString) as? String
                }
                return .init(parent: parent, role: role, domID: domID, frame: self.rect(element), profile: profile,
                             subrole: self.attribute(element, kAXSubroleAttribute as CFString) as? String ?? "")
            }, now: { ProcessInfo.processInfo.systemUptime })
        }
        var nodes: [SidebarAnchorNode]
        switch scan {
        case .failure(let failure): return .failure(failure)
        case .success(let result): nodes = result
        }
        guard let currentBounds = rect(window),
              let focused = attribute(app, kAXFocusedWindowAttribute as CFString), CFEqual(focused, window)
        else { return .failure(.windowChanged) }
        if currentBounds != bounds {
            // A pure move preserves the previously verified relative layout. Recheck sizes and
            // Children before translating it, instead of hiding on every mouse-drag frame.
            guard let cache, CFEqual(cache.window, window),
                  let moved = SidebarQuotaGeometry.movingSnapshot(reference: cache.entries.map { $0.1 },
                                                                 observed: nodes, from: cache.bounds, to: currentBounds)
            else { return .failure(.windowChanged) }
            nodes = moved
        }
        var frame: CGRect
        switch SidebarQuotaGeometry.resolution(window: currentBounds, nodes: nodes) {
        case .failure(let failure): cache = nil; return .failure(failure)
        case .success(let result): frame = result
        }
        if !handles.isEmpty {
            remember(window: window, bounds: currentBounds, handles: handles, nodes: nodes)
        } else if let previous = cache {
            cache = AnchorCache(window: window, bounds: currentBounds,
                                entries: zip(previous.entries, nodes).map { ($0.0.0, $0.1) }, edges: previous.edges)
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return .failure(.windowListUnavailable) }
        let candidates = list.enumerated().filter { _, row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = row[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
            if let cachedWindowID, let cache, CFEqual(cache.window, window),
               (row[kCGWindowNumber as String] as? NSNumber)?.intValue == cachedWindowID {
                return abs(r.width - currentBounds.width) <= 1 && abs(r.height - currentBounds.height) <= 1
            }
            return abs(r.minX - currentBounds.minX) <= 1 && abs(r.minY - currentBounds.minY) <= 1 &&
                abs(r.width - currentBounds.width) <= 1 && abs(r.height - currentBounds.height) <= 1
        }
        guard candidates.count == 1, let target = candidates.first,
              let id = (target.element[kCGWindowNumber as String] as? NSNumber)?.intValue else { return .failure(.windowMismatch) }
        if let dictionary = target.element[kCGWindowBounds as String] as? [String: Any],
           let latest = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
            frame = frame.offsetBy(dx: latest.minX - currentBounds.minX, dy: latest.minY - currentBounds.minY)
        }
        cachedWindowID = id
        let canvas = SidebarQuotaGeometry.canvas(frame)
        for row in list.prefix(target.offset) {
            guard let n = (row[kCGWindowNumber as String] as? NSNumber)?.intValue, !ownWindows.contains(n),
                  let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  SidebarQuotaOcclusion.blocks(layer: layer, owner: (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1, own: getpid()),
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let dictionary = row[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { continue }
            if r.intersects(canvas) { return .failure(.occluded) }
        }
        return .success(.init(frame: frame, windowID: id, pid: pid))
    }
}

private final class SidebarQuotaClipView: NSView {
    override var isFlipped: Bool { true }
}

final class SidebarQuotaPanel: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let panel: NSPanel
    private let inputPanel: NSPanel
    private let webView: WKWebView
    private let inputWebView: WKWebView
    private let entry: URL?
    private var loaded = Set<ObjectIdentifier>()
    private var ready: Bool { loaded.count == 2 }
    private var value: [String: Any] = [:]
    private var attachedWindowID: Int?
    private var orderingPasses = 0
    private var frameChanges = 0
    private var hidePasses = 0
    var onOpen: (() -> Void)?
    var number: Int { panel.windowNumber }
    var numbers: Set<Int> { [panel.windowNumber, inputPanel.windowNumber] }
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let inputConfig = WKWebViewConfiguration()
        inputConfig.websiteDataStore = .nonPersistent()
        inputConfig.userContentController.addUserScript(WKUserScript(source: "window.__rootnoteInputOnly=true", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let canvas = CGRect(x: 0, y: 0, width: 44, height: 124)
        webView = WKWebView(frame: canvas, configuration: config)
        inputWebView = WKWebView(frame: CGRect(x: -8, y: -14, width: 44, height: 124), configuration: inputConfig)
        panel = NSPanel(contentRect: canvas,
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        inputPanel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 28, height: 96),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        entry = RootnotePanelPaths.resources?.appendingPathComponent("guard/sidebar-quota.html")
        super.init()
        panel.title = "Rootnote 周额度"
        inputPanel.title = "Rootnote 周额度点击区"
        for window in [panel, inputPanel] {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            // A foreign application's normal window is raised on every click. Keep
            // this scoped overlay above that level instead of repairing it a tick later.
            // Foreground, occlusion, Space and sleep checks still govern visibility.
            window.level = .floating
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = true
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        }
        // AppKit window-level pass-through, not CSS transparency or a racing hover toggle.
        panel.ignoresMouseEvents = true
        inputPanel.ignoresMouseEvents = false
        panel.contentView = webView
        let clip = SidebarQuotaClipView(frame: CGRect(x: 0, y: 0, width: 28, height: 96))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.addSubview(inputWebView)
        inputPanel.contentView = clip
        for view in [webView, inputWebView] {
            view.setValue(false, forKey: "drawsBackground")
            view.navigationDelegate = self
        }
        inputConfig.userContentController.add(self, name: "sidebarQuota")
        if let entry {
            webView.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
            inputWebView.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
        }
    }
    func hide() {
        guard panel.isVisible || inputPanel.isVisible else { return }
        hidePasses += 1
        inputPanel.orderOut(nil); panel.orderOut(nil)
        webView.evaluateJavaScript("window.SidebarQuota.focus(false)")
        attachedWindowID = nil
    }
    private func orderingIsValid(relativeTo host: Int) -> Bool {
        guard panel.isVisible, inputPanel.isVisible, attachedWindowID == host,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let numbers = list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
        guard let input = numbers.firstIndex(of: inputPanel.windowNumber),
              let display = numbers.firstIndex(of: panel.windowNumber),
              let host = numbers.firstIndex(of: host) else { return false }
        return input < display && display < host
    }
    @discardableResult func present(_ attachment: SidebarQuotaAttachment, primaryTop: CGFloat) -> Bool {
        guard ready else { hide(); return false }
        let frame = SidebarQuotaGeometry.cocoa(SidebarQuotaGeometry.canvas(attachment.frame), primaryTop: primaryTop)
        let inputFrame = SidebarQuotaGeometry.cocoa(SidebarQuotaGeometry.hit(attachment.frame), primaryTop: primaryTop)
        if panel.frame != frame { frameChanges += 1; panel.setFrame(frame, display: false) }
        if inputPanel.frame != inputFrame { frameChanges += 1; inputPanel.setFrame(inputFrame, display: false) }
        // A successful anchor read is not a request to reinsert two visible windows.
        // Repair ordering only when the host or the actual window stack changed.
        if !orderingIsValid(relativeTo: attachment.windowID) {
            orderingPasses += 1
            panel.order(.above, relativeTo: attachment.windowID)
            inputPanel.order(.above, relativeTo: panel.windowNumber)
            attachedWindowID = attachment.windowID
        }
        return panel.isVisible && inputPanel.isVisible
    }
    func update(_ value: SidebarQuotaValue) {
        let next = value.payload
        guard !(self.value as NSDictionary).isEqual(to: next) else { return }
        self.value = next
        push()
    }
    private func push() {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return }
        for view in [webView, inputWebView] { view.evaluateJavaScript("window.SidebarQuota.update(\(json))") }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.insert(ObjectIdentifier(webView))
        push()
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .other && action.request.url?.standardizedFileURL == entry?.standardizedFileURL ? .allow : .cancel)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard ready, message.webView === inputWebView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == entry?.standardizedFileURL,
              let body = message.body as? [String: Any] else { return }
        if body["action"] as? String == "openQuota" { onOpen?() }
        else if body["action"] as? String == "focus", let focused = body["focused"] as? Bool {
            webView.evaluateJavaScript("window.SidebarQuota.focus(\(focused ? "true" : "false"))")
        }
    }
}

final class SidebarQuotaCoordinator {
    private let panel: SidebarQuotaPanel
    private let reader = SidebarQuotaAnchorReader()
    private let appearanceReader = SidebarHostAppearanceReader()
    private var appearance: String?
    private let queue = DispatchQueue(label: "rootnote.sidebar-anchor", qos: .utility)
    private var timer: Timer?
    private var busy = false
    private var generation = 0
    private var account: [String: Any] = [:]
    private var observers: [NSObjectProtocol] = []
    private var suspensions = Set<String>()
    init(panel: SidebarQuotaPanel = SidebarQuotaPanel()) { self.panel = panel }
    fileprivate func prepareForActivation(front: pid_t?, target: pid_t?) {
        generation += 1
        if let front, let target,
           SidebarQuotaGeometry.allowsForeground(front, target: target, own: getpid()) { return }
        panel.hide()
    }
    var onDiagnostic: ((SidebarQuotaFailure?) -> Void)?
    // Manual acceptance preserves the last target attempt when its own control window is opened.
    var checkOnlyWhenTargetActive = false
    var onOpen: (() -> Void)? {
        didSet { panel.onOpen = { [weak self] in self?.onOpen?() } }
    }
    func update(account: [String: Any]) {
        self.account = account
        panel.update(currentValue)
    }
    var currentValue: SidebarQuotaValue {
        .read(account, now: Date().timeIntervalSince1970, appearance: appearance ?? "dark",
              reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let front = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ??
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            let targets = Self.targets()
            self.prepareForActivation(front: front, target: targets.count == 1 ? targets.first?.processIdentifier : nil)
            self.tick()
        })
        for (name, key, suspended) in [
            (NSWorkspace.willSleepNotification, "system", true),
            (NSWorkspace.screensDidSleepNotification, "display", true),
            (NSWorkspace.didWakeNotification, "system", false),
            (NSWorkspace.screensDidWakeNotification, "display", false)
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if suspended { self.suspensions.insert(key) } else { self.suspensions.remove(key) }
                self.generation += 1
                self.panel.hide()
                if !suspended { self.tick() }
            })
        }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }
    func stop() {
        generation += 1
        timer?.invalidate(); timer = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        panel.hide()
    }
    private static func targets() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").filter {
            ["/Applications/ChatGPT.app", "/Applications/Codex.app"].contains($0.bundleURL?.path ?? "")
        }
    }
    private func tick() {
        guard timer != nil, suspensions.isEmpty else { panel.hide(); return }
        appearance = appearanceReader.appearance(now: Date().timeIntervalSince1970,
            systemDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        guard appearance != nil else { panel.hide(); onDiagnostic?(.appearanceUnavailable); return }
        panel.update(currentValue)
        let matches = Self.targets()
        guard matches.count == 1, let target = matches.first else { panel.hide(); onDiagnostic?(.targetMissing); return }
        guard !target.isHidden else { panel.hide(); onDiagnostic?(.targetHidden); return }
        guard AXIsProcessTrusted() else { panel.hide(); onDiagnostic?(.permission); return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              SidebarQuotaGeometry.allowsForeground(front.processIdentifier, target: target.processIdentifier, own: ProcessInfo.processInfo.processIdentifier),
              !checkOnlyWhenTargetActive || front.processIdentifier == target.processIdentifier
        else { panel.hide(); return }
        // An in-flight lookup is not a failed lookup and must not hide a valid panel.
        guard !busy else { return }
        busy = true
        let expected = generation, pid = target.processIdentifier, numbers = panel.numbers
        let began = Date()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.reader.read(pid: pid, excluding: numbers)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                // Activation/stop already applied the new visibility policy. A superseded
                // read must never hide a still-valid presentation owned by that policy.
                guard self.timer != nil, self.generation == expected else { return }
                guard let current = NSWorkspace.shared.frontmostApplication,
                      SidebarQuotaGeometry.allowsForeground(current.processIdentifier, target: pid, own: ProcessInfo.processInfo.processIdentifier),
                      !self.checkOnlyWhenTargetActive || current.processIdentifier == pid
                else { self.panel.hide(); return }
                guard Date().timeIntervalSince(began) < 2, let primary = NSScreen.screens.first else {
                    self.panel.hide(); self.onDiagnostic?(.windowChanged); return
                }
                switch result {
                case .failure(let failure): self.panel.hide(); self.onDiagnostic?(failure)
                case .success(let attachment):
                    let submitted = self.panel.present(attachment, primaryTop: primary.frame.maxY)
                    self.onDiagnostic?(submitted ? nil : .componentUnavailable)
                }
            }
        }
    }
}


func runSidebarQuotaComponentSelfTest() -> Int32 {
    guard RootnoteRuntimePaths.isCandidate else { return 2 }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let panel = SidebarQuotaPanel()
    let checks = panel.componentChecks()
    let report: [String: Any] = ["ok": checks.values.allSatisfy { $0 }, "checks": checks,
        "scope": "own_webkit_and_native_overlay_windows_only", "liveCodexInspected": false, "realAccountRead": false]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data); print("")
    }
    return checks.values.allSatisfy { $0 } ? 0 : 1
}

extension SidebarQuotaPanel {
    fileprivate func componentChecks() -> [String: Bool] {
        func wait(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(6)
            while !condition(), Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }
        func evaluate(_ expression: String, input: Bool = false) -> Any? {
            var done = false
            var result: Any?
            (input ? inputWebView : webView).evaluateJavaScript(expression) { value, _ in result = value; done = true }
            _ = wait { done }
            return result
        }
        var checks: [String: Bool] = [:]
        checks["own_page_ready"] = wait { ready }
        update(.init(remaining: 69, appearance: "dark"))
        let r = evaluate("(()=>{let r=document.getElementById('quota').getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()") as? [Double]
        checks["native_webkit_exact_36_116_and_padding_4"] = r == [4, 4, 36, 116]
        checks["both_windows_use_identical_component"] = evaluate("document.getElementById('quota').getBoundingClientRect().width", input: true) as? Double == 36
        checks["ring_and_text_stay_aligned_to_unchanged_input"] = evaluate("(()=>{let r=document.querySelector('.quota-ring').getBoundingClientRect(),p=document.querySelector('.quota-percent').getBoundingClientRect();return r.x-8===2&&p.x-8===0})()", input: true) as? Bool == true
        checks["single_95_percent_background_no_border"] = evaluate("(()=>{let s=getComputedStyle(document.getElementById('quota'));return s.borderTopWidth==='0px'&&s.backgroundColor==='rgba(22, 25, 24, 0.95)'&&s.opacity==='1'})()") as? Bool == true
        checks["input_layer_draws_no_surface_shadow_or_content"] = evaluate("(()=>{let e=document.getElementById('quota'),s=getComputedStyle(e);return s.backgroundColor==='rgba(0, 0, 0, 0)'&&s.boxShadow==='none'&&s.outlineStyle==='none'&&[...e.children].every(c=>getComputedStyle(c).visibility==='hidden')})()", input: true) as? Bool == true
        update(.init(remaining: 69, appearance: "light", reduceTransparency: true))
        checks["accessibility_opaque_display_only"] = evaluate("getComputedStyle(document.getElementById('quota')).backgroundColor") as? String == "rgb(240, 242, 241)" && evaluate("getComputedStyle(document.getElementById('quota')).backgroundColor", input: true) as? String == "rgba(0, 0, 0, 0)"
        _ = evaluate("window.webkit.messageHandlers.sidebarQuota.postMessage({action:'focus',focused:true})", input: true)
        checks["keyboard_focus_mirrored_to_display"] = wait { evaluate("document.documentElement.classList.contains('keyboard-focus')") as? Bool == true }
        _ = evaluate("window.webkit.messageHandlers.sidebarQuota.postMessage({action:'focus',focused:false})", input: true)
        checks["keyboard_focus_can_clear"] = wait { evaluate("document.documentElement.classList.contains('keyboard-focus')") as? Bool == false }
        update(.init(remaining: 69, appearance: "dark"))
        checks["native_webkit_real_payload"] = evaluate("document.querySelector('.quota-percent').textContent") as? String == "69%"
        update(.init(remaining: 8, appearance: "light"))
        checks["native_light_low_state"] = evaluate("document.getElementById('quota').classList.contains('light') && document.getElementById('quota').classList.contains('low')") as? Bool == true
        update(.init(remaining: nil, appearance: "dark"))
        checks["native_unknown_not_zero"] = evaluate("document.querySelector('.quota-percent').textContent") as? String == "—"
        var opens = 0
        onOpen = { opens += 1 }
        _ = evaluate("document.getElementById('quota').click();document.getElementById('quota').click()", input: true)
        checks["native_bridge_repeat_open_only"] = wait { opens == 2 }
        checks["does_not_activate_or_present_itself"] = !panel.isVisible && !inputPanel.isVisible
        checks["scoped_overlay_stays_above_normal_host_level"] = panel.level == .floating && inputPanel.level == .floating
        update(.init(remaining: 100, appearance: "dark"))
        checks["hundred_percent_fits_in_28"] = evaluate("(()=>{let e=document.querySelector('.quota-percent'),r=document.createRange();r.selectNodeContents(e);return r.getBoundingClientRect().width<=28})()") as? Bool == true
        checks["display_ignores_mouse_input_window_accepts"] = panel.ignoresMouseEvents && !inputPanel.ignoresMouseEvents
        checks["input_crop_exactly_inside_capsule"] = inputWebView.frame == CGRect(x: -8, y: -14, width: 44, height: 124) && inputPanel.frame.size == CGSize(width: 28, height: 96)
        // Own isolated windows only. No target reader, account reader, or pet lifecycle exists here.
        let host = NSWindow(contentRect: CGRect(x: 300, y: 200, width: 360, height: 320),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.title = "Rootnote 胶囊隔离验证"
        host.isReleasedWhenClosed = false
        host.center(); host.orderFrontRegardless()
        if let primary = NSScreen.screens.first {
            let top = primary.frame.maxY
            func attach() -> SidebarQuotaAttachment {
                let cocoa = CGRect(x: host.frame.minX + 26 - SidebarQuotaGeometry.size.width / 2,
                                   y: host.frame.minY + 52, width: 32, height: 116)
                return .init(frame: SidebarQuotaGeometry.cocoa(cocoa, primaryTop: top), windowID: host.windowNumber, pid: getpid())
            }
            var fixture = attach()
            checks["two_native_windows_present_on_own_host"] = present(fixture, primaryTop: top)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let canvas = panel.frame, hit = inputPanel.frame
            checks["native_display_and_hit_center_on_52_rail"] = canvas.midX == host.frame.minX + 26 && hit.midX == canvas.midX
            let stableOrders = orderingPasses, stableFrames = frameChanges, stableHides = hidePasses
            for _ in 0..<200 { _ = present(fixture, primaryTop: top) }
            checks["stationary_200_refreshes_do_not_reorder_or_hide"] = orderingPasses == stableOrders && hidePasses == stableHides
            checks["stationary_200_refreshes_do_not_change_frames"] = frameChanges == stableFrames && panel.frame == canvas && inputPanel.frame == hit
            let coordinator = SidebarQuotaCoordinator(panel: self)
            let targetPID = getpid() + 1
            for _ in 0..<20 {
                coordinator.prepareForActivation(front: targetPID, target: targetPID)
                coordinator.prepareForActivation(front: getpid(), target: targetPID)
            }
            checks["host_rootnote_activation_keeps_overlay_visible"] = panel.isVisible && inputPanel.isVisible && hidePasses == stableHides
            for _ in 0..<10 {
                host.orderFrontRegardless()
                _ = present(fixture, primaryTop: top)
            }
            checks["host_raise_repairs_order_without_hiding_or_moving"] = panel.isVisible && inputPanel.isVisible &&
                hidePasses == stableHides && frameChanges == stableFrames && orderingIsValid(relativeTo: host.windowNumber)
            let repairedOrders = orderingPasses
            for _ in 0..<20 { _ = present(fixture, primaryTop: top) }
            checks["repaired_order_stays_stable"] = orderingPasses == repairedOrders
            coordinator.prepareForActivation(front: targetPID + 1, target: targetPID)
            checks["unrelated_application_still_hides_both_windows"] = !panel.isVisible && !inputPanel.isVisible
            _ = present(fixture, primaryTop: top)
            coordinator.prepareForActivation(front: nil, target: targetPID)
            checks["unknown_foreground_still_hides_fail_closed"] = !panel.isVisible && !inputPanel.isVisible
            _ = present(fixture, primaryTop: top)
            func windowAt(_ point: CGPoint) -> Int { NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) }
            checks["native_center_hits_only_input_window"] = windowAt(CGPoint(x: hit.midX, y: hit.midY)) == inputPanel.windowNumber
            checks["native_transparent_left_passes_to_host"] = windowAt(CGPoint(x: canvas.minX + 1, y: canvas.midY)) == host.windowNumber
            checks["native_transparent_corner_passes_to_host"] = windowAt(CGPoint(x: canvas.minX + 1, y: canvas.maxY - 1)) == host.windowNumber
            checks["native_capsule_top_decoration_passes_to_host"] = windowAt(CGPoint(x: canvas.midX, y: canvas.maxY - 6)) == host.windowNumber
            host.setFrameOrigin(CGPoint(x: host.frame.minX + 80, y: host.frame.minY - 50))
            fixture = attach(); _ = present(fixture, primaryTop: top)
            checks["both_windows_follow_own_host_translation"] = panel.frame == canvas.offsetBy(dx: 80, dy: -50) && inputPanel.frame == hit.offsetBy(dx: 80, dy: -50)
            host.setContentSize(CGSize(width: 420, height: 380))
            fixture = attach(); _ = present(fixture, primaryTop: top)
            checks["both_windows_match_after_host_resize"] = panel.frame == SidebarQuotaGeometry.cocoa(SidebarQuotaGeometry.canvas(fixture.frame), primaryTop: top) && inputPanel.frame == SidebarQuotaGeometry.cocoa(SidebarQuotaGeometry.hit(fixture.frame), primaryTop: top)
        }
        hide()
        checks["both_windows_hide_together"] = !panel.isVisible && !inputPanel.isVisible
        host.close()
        onOpen = nil
        hide()
        return checks
    }
}

// Pure, offline regression. Does not construct a panel, query AX/CGWindow, or read accounts.
func runSidebarQuotaSelfTest() -> Int32 {
    var checks: [String: Bool] = [:]
    let w = CGRect(x: 0, y: 33, width: 1470, height: 923)
    let s = CGRect(x: 0, y: 77, width: 340, height: 875)
    let nav = CGRect(x: 0, y: 77, width: 52, height: 875)
    let account = CGRect(x: 8, y: 912, width: 36, height: 36)
    let expected = CGRect(x: 10, y: 784, width: 32, height: 116)
    let nodes: [SidebarAnchorNode] = [
        .init(parent: nil, role: "AXWindow", domID: "", frame: w, profile: false),
        .init(parent: 0, role: "AXGroup", domID: "app-shell-sidebar", frame: s, profile: false),
        .init(parent: 1, role: "AXGroup", domID: "", frame: nav, profile: false, subrole: "AXLandmarkNavigation"),
        .init(parent: 2, role: "AXGroup", domID: "", frame: account, profile: false),
        .init(parent: 3, role: "AXPopUpButton", domID: "", frame: account, profile: true)]
    func failure<T>(_ result: Result<T, SidebarQuotaFailure>) -> SidebarQuotaFailure? {
        if case .failure(let value) = result { return value }; return nil
    }
    checks["user_measured_chain_resolves_original_anchor"] = SidebarQuotaGeometry.resolve(window: w, nodes: nodes) == expected
    checks["background_only_widens_4_around_centered_anchor"] = SidebarQuotaGeometry.background(expected) == CGRect(x: 8, y: 784, width: 36, height: 116)
    checks["canvas_exact_44_124_inside_52_rail"] = SidebarQuotaGeometry.canvas(expected) == CGRect(x: 4, y: 780, width: 44, height: 124)
    checks["hit_exact_28_96"] = SidebarQuotaGeometry.hit(expected) == CGRect(x: 12, y: 794, width: 28, height: 96)
    checks["background_hit_and_canvas_center_on_navigation_and_avatar"] = [expected, SidebarQuotaGeometry.background(expected), SidebarQuotaGeometry.canvas(expected), SidebarQuotaGeometry.hit(expected)].allSatisfy { $0.midX == nav.midX && $0.midX == account.midX }
    checks["canvas_clear_of_project_region"] = SidebarQuotaGeometry.canvas(expected).maxX == nav.maxX - 4
    checks["old_alignment_rejected_observed_wrapper"] = abs(account.minX - s.minX) > 1 && abs(account.maxY - s.maxY) > 1
    let movingWindow = w.offsetBy(dx: 75, dy: 50)
    let moving = SidebarQuotaGeometry.movingSnapshot(reference: nodes, observed: nodes, from: w, to: movingWindow)
    checks["in_flight_move_keeps_verified_relative_layout"] = moving.flatMap { SidebarQuotaGeometry.resolve(window: movingWindow, nodes: $0) } == expected.offsetBy(dx: 75, dy: 50)
    checks["moving_cache_never_guesses_resize"] = SidebarQuotaGeometry.movingSnapshot(reference: nodes, observed: nodes, from: w, to: CGRect(x: 75, y: 50, width: 1000, height: 700)) == nil
    var changedSizes = nodes
    changedSizes[2] = .init(parent: 1, role: "AXGroup", domID: "", frame: CGRect(x: 0, y: 77, width: 44, height: 875), profile: false, subrole: "AXLandmarkNavigation")
    checks["moving_cache_revalidates_navigation_size"] = SidebarQuotaGeometry.movingSnapshot(reference: nodes, observed: changedSizes, from: w, to: movingWindow) == nil
    checks["collision_never_repositions"] = SidebarQuotaGeometry.frame(window: w, sidebar: s, navigation: nav, account: account, controls: [expected]) == nil
    let adjacent = SidebarAnchorNode(parent: 1, role: "AXStaticText", domID: "", frame: CGRect(x: 68, y: 819, width: 60, height: 20), profile: false)
    checks["project_and_recent_labels_do_not_collide"] = SidebarQuotaGeometry.resolve(window: w, nodes: nodes + [adjacent]) == expected
    checks["occupied_native_control_rejected"] = failure(SidebarQuotaGeometry.resolution(window: w, nodes: nodes + [.init(parent: 2, role: "AXButton", domID: "", frame: expected, profile: false)])) == .positionOccupied
    checks["closing_detail_keeps_eligible_capsule"] = SidebarQuotaGeometry.allowsForeground(2, target: 1, own: 2)
    checks["foreign_foreground_not_overlaid"] = !SidebarQuotaGeometry.allowsForeground(3, target: 1, own: 2)
    checks["normal_window_occlusion_preserved"] = SidebarQuotaOcclusion.blocks(layer: 0, owner: 3, own: 2)
    checks["pinned_rootnote_detail_still_occludes_capsule"] = SidebarQuotaOcclusion.blocks(layer: NSWindow.Level.floating.rawValue, owner: 2, own: 2)
    checks["rootnote_utility_window_still_occludes_capsule"] = SidebarQuotaOcclusion.blocks(layer: NSWindow.Level.modalPanel.rawValue, owner: 2, own: 2)
    checks["host_transparent_pet_canvas_not_a_sidebar_occluder"] = !SidebarQuotaOcclusion.blocks(layer: 3, owner: 1, own: 2)
    checks["coordinate_conversion"] = SidebarQuotaGeometry.cocoa(expected, primaryTop: 956) == CGRect(x: 10, y: 56, width: 32, height: 116)
    for (dx, dy) in [(-1400.0, -600.0), (1450.0, 200.0), (50.0, 75.0)] {
        let moved = nodes.map { SidebarAnchorNode(parent: $0.parent, role: $0.role, domID: $0.domID, frame: $0.frame?.offsetBy(dx: dx, dy: dy), profile: $0.profile, subrole: $0.subrole) }
        checks["move_tracks_\(dx)_\(dy)"] = SidebarQuotaGeometry.resolve(window: w.offsetBy(dx: dx, dy: dy), nodes: moved) == expected.offsetBy(dx: dx, dy: dy)
    }
    var resized = nodes
    resized[0] = .init(parent: nil, role: "AXWindow", domID: "", frame: CGRect(x: 0, y: 33, width: 1200, height: 723), profile: false)
    resized[1] = .init(parent: 0, role: "AXGroup", domID: "app-shell-sidebar", frame: CGRect(x: 0, y: 77, width: 340, height: 675), profile: false)
    resized[2] = .init(parent: 1, role: "AXGroup", domID: "", frame: CGRect(x: 0, y: 77, width: 52, height: 675), profile: false, subrole: "AXLandmarkNavigation")
    resized[3] = .init(parent: 2, role: "AXGroup", domID: "", frame: account.offsetBy(dx: 0, dy: -200), profile: false)
    resized[4] = .init(parent: 3, role: "AXPopUpButton", domID: "", frame: account.offsetBy(dx: 0, dy: -200), profile: true)
    checks["resize_uses_live_account_top"] = SidebarQuotaGeometry.resolve(window: resized[0].frame!, nodes: resized) == expected.offsetBy(dx: 0, dy: -200)
    checks["missing_profile_diagnostic"] = failure(SidebarQuotaGeometry.resolution(window: w, nodes: Array(nodes.dropLast()))) == .profileMissing
    checks["ambiguous_profile_diagnostic"] = failure(SidebarQuotaGeometry.resolution(window: w, nodes: nodes + [nodes[4]])) == .profileAmbiguous
    var bad = nodes
    bad[3] = .init(parent: 2, role: "AXGroup", domID: "", frame: nil, profile: false)
    checks["missing_wrapper_not_guessed"] = failure(SidebarQuotaGeometry.resolution(window: w, nodes: bad)) == .footerMissing
    bad = nodes; bad[4] = .init(parent: 2, role: "AXPopUpButton", domID: "", frame: account, profile: true)
    checks["button_alone_never_substituted"] = failure(SidebarQuotaGeometry.resolution(window: w, nodes: bad)) == .footerMissing
    bad = nodes; bad[2].subrole = ""
    checks["navigation_landmark_required"] = failure(SidebarQuotaGeometry.resolution(window: w, nodes: bad)) == .navigationMissing
    bad = nodes; bad[2] = .init(parent: 1, role: "AXGroup", domID: "", frame: CGRect(x: 0, y: 77, width: 44, height: 875), profile: false, subrole: "AXLandmarkNavigation")
    checks["narrow_rail_never_repositions"] = failure(SidebarQuotaGeometry.resolution(window: w, nodes: bad)) == .sidebarTooNarrow
    checks["wrapper_must_have_only_profile_child"] = failure(SidebarQuotaGeometry.resolution(window: w, nodes: nodes + [.init(parent: 3, role: "AXButton", domID: "", frame: account, profile: false)])) == .footerMissing
    checks["account_not_at_bottom_rejected"] = SidebarQuotaGeometry.frame(window: w, sidebar: s, navigation: nav, account: account.offsetBy(dx: 0, dy: -40), controls: []) == nil
    checks["account_button_description_compatible"] = SidebarQuotaAccountButton.matches(role: "AXButton") { $0 == "AXDescription" ? "打开个人资料菜单" : nil }
    checks["account_button_title_only_supported"] = SidebarQuotaAccountButton.matches(role: "AXPopUpButton") { $0 == "AXTitle" ? "打开个人资料菜单" : nil }
    checks["account_initials_never_used"] = !SidebarQuotaAccountButton.matches(role: "AXButton") { _ in "CV" }
    var labelReads = 0
    let invalidRole = SidebarQuotaAccountButton.matches(role: "AXStaticText") { _ in labelReads += 1; return "Open profile menu" }
    checks["nonbutton_never_reads_text"] = !invalidRole && labelReads == 0
    // Fake adapter reproduces a search taking >100ms without inspecting a live app.
    let tree = [0: [1, 10], 1: [2], 2: [3], 3: [4], 10: Array(11...310)]
    var clock: TimeInterval = 0, snapshotIDs: [Int] = []
    func scan(_ budget: TimeInterval = 1.5, limit: Int = 1800, roots: Set<Int> = [1]) -> Result<[SidebarAnchorNode], SidebarQuotaFailure> {
        clock = 0; snapshotIDs = []
        return SidebarAnchorScanner.scan(root: 0, children: { tree[$0] ?? [] }, identifier: {
            clock += 0.001
            return roots.contains($0) ? "app-shell-sidebar" : ""
        }, snapshot: { id, parent in
            snapshotIDs.append(id); clock += 0.001
            let source = nodes[id]
            return .init(parent: parent, role: source.role, domID: source.domID, frame: source.frame, profile: source.profile, subrole: source.subrole)
        }, now: { clock }, budget: budget, limit: limit)
    }
    let scanned = scan()
    checks["bounded_scan_allows_over_100ms"] = (try? scanned.get()) != nil && clock > 0.1
    checks["no_unrelated_frame_queries"] = snapshotIDs == [1, 2, 3, 4]
    checks["staged_scan_preserves_exact_position"] = (try? scanned.get()).flatMap { SidebarQuotaGeometry.resolve(window: w, nodes: $0) } == expected
    checks["timeout_has_explicit_reason"] = failure(scan(0.1)) == .scanTimeout
    checks["node_limit_has_explicit_reason"] = failure(scan(limit: 20)) == .scanLimit
    checks["missing_sidebar_no_position_fallback"] = failure(scan(roots: [])) == .sidebarMissing
    checks["duplicate_sidebar_rejected"] = failure(scan(roots: [1, 10])) == .sidebarAmbiguous
    var expiryClock: TimeInterval = 0
    let expired = SidebarAnchorScanner.scan(root: 1, children: { _ in [] }, identifier: { _ in "app-shell-sidebar" }, snapshot: { _, _ in
        expiryClock = 2
        return nodes[1]
    }, now: { expiryClock })
    checks["last_read_over_budget_rejected"] = failure(expired) == .scanTimeout
    func payload(used: Any = 31, minutes: Any = 10080, updated: Double = 900, id: String = "codex", reset: Double = 2000) -> [String: Any] {
        ["currentAccount": "one", "accounts": [["id": "one", "updatedAt": updated, "buckets": [["id": id, "windows": [["minutes": minutes, "usedPercent": used, "resetsAt": reset]]]]]], "settings": ["appearance": "dark"]]
    }
    checks["real_contract_remaining_69"] = SidebarQuotaValue.read(payload(), now: 1000).remaining == 69
    checks["wrong_period_not_week"] = SidebarQuotaValue.read(payload(minutes: 300), now: 1000).remaining == nil
    checks["wrong_bucket_not_core"] = SidebarQuotaValue.read(payload(id: "other"), now: 1000).remaining == nil
    checks["stale_not_live"] = SidebarQuotaValue.read(payload(updated: 600), now: 1000).remaining == nil
    checks["future_timestamp_rejected"] = SidebarQuotaValue.read(payload(updated: 1100), now: 1000).remaining == nil
    checks["reset_time_requires_sync"] = SidebarQuotaValue.read(payload(reset: 999), now: 1000).remaining == nil
    checks["boolean_not_percent"] = SidebarQuotaValue.read(payload(used: true), now: 1000).remaining == nil
    checks["range_not_clamped_to_valid"] = SidebarQuotaValue.read(payload(used: 101), now: 1000).remaining == nil
    checks["zero_remaining_valid"] = SidebarQuotaValue.read(payload(used: 100), now: 1000).remaining == 0
    checks["boolean_period_rejected"] = SidebarQuotaValue.read(payload(minutes: true), now: 1000).remaining == nil
    checks["sub_one_not_zero"] = SidebarQuotaValue.read(payload(used: 99.5), now: 1000).text == "<1%"
    var other = payload()
    other["currentAccount"] = "two"
    checks["account_mismatch_no_history_fallback"] = SidebarQuotaValue.read(other, now: 1000).remaining == nil
    var failure = payload()
    failure["error"] = "同步失败"
    checks["failed_sync_does_not_show_old_percentage"] = SidebarQuotaValue.read(failure, now: 1000).remaining == nil
    var syncing = payload(); syncing["syncing"] = true
    checks["inflight_identity_is_not_presented_as_current"] = SidebarQuotaValue.read(syncing, now: 1000).remaining == nil
    var emptyIdentity = payload(); emptyIdentity["currentAccount"] = ""
    checks["empty_current_identity_rejected"] = SidebarQuotaValue.read(emptyIdentity, now: 1000).remaining == nil
    let modeFixtures: [(String, String, String?)] = [
        ("default_system", "", "system"),
        ("canonical_dark", "[desktop]\nappearanceTheme = \"dark\"", "dark"),
        ("literal_light", "['desktop']\n'appearanceTheme' = 'light' # comment", "light"),
        ("quoted_header", "[\"desktop\"]\n\"appearanceTheme\"=\"system\"", "system"),
        ("dotted_root", "desktop.appearanceTheme = \"dark\"", "dark"),
        ("other_section_ignored", "[other]\nappearanceTheme = 'dark'", "system"),
        ("nested_theme_ignored", "[desktop.appearanceDarkChromeTheme]\nappearanceTheme = 'light'", "system"),
        ("comment_ignored", "# [desktop]\n# appearanceTheme='dark'", "system"),
        ("multiline_fake_key_ignored", "prompt='''\n[desktop]\nappearanceTheme='dark'\n'''", "system"),
        ("array_fake_key_ignored", "prompts=[\n'[desktop]',\n\"appearanceTheme='dark'\"\n]", "system"),
        ("invalid_mode_rejected", "[desktop]\nappearanceTheme='blue'", nil),
        ("duplicate_rejected", "[desktop]\nappearanceTheme='dark'\nappearanceTheme='light'", nil),
        ("inline_desktop_table", "desktop={appearanceTheme='dark'}", "dark"),
        ("unterminated_rejected", "[desktop]\nappearanceTheme='dark", nil),
        ("array_table_ignored", "[[desktop]]\nappearanceTheme='dark'", "system")
    ]
    for (name, source, expected) in modeFixtures { checks["host_mode_" + name] = SidebarHostAppearance.mode(source) == expected }
    checks["forced_host_dark_overrides_light_system"] = SidebarHostAppearance.resolve(mode: "dark", systemDark: false) == "dark"
    checks["forced_host_light_overrides_dark_system"] = SidebarHostAppearance.resolve(mode: "light", systemDark: true) == "light"
    checks["host_system_follows_os"] = SidebarHostAppearance.resolve(mode: "system", systemDark: true) == "dark" && SidebarHostAppearance.resolve(mode: "system", systemDark: false) == "light"
    let themeFixtures: [(String, String, Bool, String?)] = [
        ("system_light_custom_dark", "[desktop]\nappearanceTheme='system'\nappearanceLightChromeTheme={surface='#111111', fonts={ui='System',code='Mono'}, accent='#339cff'}", false, "dark"),
        ("system_dark_custom_light", "[desktop]\nappearanceTheme='system'\nappearanceDarkChromeTheme={surface='#ffffff'}", true, "light"),
        ("forced_light_custom_dark", "[desktop]\nappearanceTheme='light'\n[desktop.appearanceLightChromeTheme]\nsurface='#111111'", true, "dark"),
        ("forced_dark_ignores_inactive_light", "[desktop]\nappearanceTheme='dark'\nappearanceLightChromeTheme={surface='#ffffff'}\nappearanceDarkChromeTheme={surface='#222222'}", false, "dark"),
        ("surface_dotted_path", "desktop.appearanceTheme='system'\ndesktop.appearanceLightChromeTheme.surface='#111111'", false, "dark"),
        ("nested_inline_desktop", "desktop={appearanceTheme='system',appearanceLightChromeTheme={surface='#111111',fonts={ui='a,b',code='x=y'}}}", false, "dark"),
        ("quoted_surface_key", "[desktop.\"appearanceLightChromeTheme\"]\n\"surface\"='#F0F2F1'", false, "light"),
        ("fake_multiline_surface_ignored", "prompt=\"\"\"\n[desktop.appearanceLightChromeTheme]\nsurface='#111111'\n\"\"\"", false, "light"),
        ("invalid_surface_fails_closed", "[desktop.appearanceLightChromeTheme]\nsurface='blue'", false, nil),
        ("duplicate_surface_fails_closed", "[desktop.appearanceLightChromeTheme]\nsurface='#111111'\nsurface='#ffffff'", false, nil)
    ]
    for (name, source, systemDark, expected) in themeFixtures {
        checks["custom_theme_" + name] = SidebarHostAppearance.settings(source)?.appearance(systemDark: systemDark) == expected
    }
    var panelAppearance = payload()
    panelAppearance["settings"] = ["appearance": "light"]
    checks["panel_light_does_not_override_host_dark"] = SidebarQuotaValue.read(panelAppearance, now: 1000, appearance: "dark").appearance == "dark"
    panelAppearance["settings"] = ["appearance": "dark"]
    checks["panel_dark_does_not_override_host_light"] = SidebarQuotaValue.read(panelAppearance, now: 1000, appearance: "light").appearance == "light"
    var fixtureText = "[desktop]\nappearanceTheme='dark'", reads = 0
    let appearanceReader = SidebarHostAppearanceReader(url: URL(fileURLWithPath: "/fixture-only/config.toml"), read: { _ in reads += 1; return fixtureText })
    checks["appearance_reader_initial_fixture"] = appearanceReader.appearance(now: 100, systemDark: false) == "dark"
    fixtureText = "[desktop]\nappearanceTheme='light'"
    checks["appearance_reader_caches_bounded_reads"] = appearanceReader.appearance(now: 100.1, systemDark: false) == "dark" && reads == 1
    checks["appearance_refresh_independent_of_account_sync"] = appearanceReader.appearance(now: 100.6, systemDark: true) == "light" && reads == 2
    fixtureText = "[desktop]\nappearanceTheme='future-mode'"
    checks["unsupported_host_mode_fails_closed"] = appearanceReader.appearance(now: 101.2, systemDark: true) == nil
    let missingReader = SidebarHostAppearanceReader(url: URL(fileURLWithPath: "/fixture-only/missing"), read: { _ in throw CocoaError(.fileReadNoSuchFile) })
    checks["missing_config_uses_hosts_system_default"] = missingReader.appearance(now: 1, systemDark: true) == "dark"
    let deniedReader = SidebarHostAppearanceReader(url: URL(fileURLWithPath: "/fixture-only/denied"), read: { _ in throw CocoaError(.fileReadNoPermission) })
    checks["unreadable_config_never_uses_panel_theme"] = deniedReader.appearance(now: 1, systemDark: true) == nil
    let ok = checks.values.allSatisfy { $0 }
    let report: [String: Any] = ["ok": ok, "checks": checks, "liveAttachmentVerified": false, "accountRead": false, "petControlCalls": 0]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data); print("")
    }
    return ok ? 0 : 1
}
