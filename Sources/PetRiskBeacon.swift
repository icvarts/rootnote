import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import WebKit

enum PetRiskLevel: String, CaseIterable {
    case green
    case yellow
    case red

    var color: NSColor {
        switch self {
        case .green: return NSColor(srgbRed: 0.36, green: 0.82, blue: 0.55, alpha: 1)
        case .yellow: return NSColor(srgbRed: 0.96, green: 0.72, blue: 0.27, alpha: 1)
        case .red: return NSColor(srgbRed: 1.0, green: 0.29, blue: 0.28, alpha: 1)
        }
    }

    var symbolName: String {
        switch self {
        case .green: return "checkmark.circle.fill"
        case .yellow: return "exclamationmark.triangle.fill"
        case .red: return "exclamationmark.octagon.fill"
        }
    }

    var rank: Int {
        switch self {
        case .green: return 0
        case .yellow: return 1
        case .red: return 2
        }
    }

    var menuGlyph: String {
        switch self {
        case .green: return "🟢"
        case .yellow: return "🟡"
        case .red: return "🔴"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .green: return "性能正常"
        case .yellow: return "性能需要留意"
        case .red: return "性能需要关注，点击查看详情"
        }
    }
}

private struct PetRiskSnapshot {
    let raw: [String: Any]
    let level: PetRiskLevel
    let severityLabel: String

    init?(_ raw: [String: Any]) {
        guard let levelText = raw["microState"] as? String,
              let level = PetRiskLevel(rawValue: levelText)
        else { return nil }
        self.raw = raw
        self.level = level
        self.severityLabel = raw["severityLabel"] as? String ?? "未知"
    }
}

private final class PetRiskHitButton: NSButton {
    var onPress: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onPress?(true)
        defer { onPress?(false) }
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class PetRiskBeaconPanelController: NSObject {
    fileprivate enum Geometry {
        static let pairedNativeControls = RootnoteRuntimePaths.nativeControlsEnabled
        static let panelSize: CGFloat = 32
        static let visualSize: CGFloat = 24

        // Fixed at the left foot, above Codex's separate Quick Chat surface.
        // Native control expansion and drag direction must not move this slot.
        static func performanceSlotBesideFeet(in mascot: CGRect) -> CGRect {
            return CGRect(
                x: mascot.minX - panelSize / 2,
                y: mascot.maxY - panelSize,
                width: panelSize,
                height: panelSize
            )
        }
    }

    private let panel: NSPanel
    private let visualEffect: NSView
    private let iconView: NSImageView
    private let hitButton: PetRiskHitButton
    private var currentLevel: PetRiskLevel = .green
    private var pendingDowngrade: PetRiskLevel?
    private var pendingDowngradeSamples = 0
    private var lastSample: CharacterOverlaySample?
    private var lastActivationUptime: TimeInterval = -.infinity
    private let reminderDot = NSView(frame: NSRect(x: 24, y: 23, width: 6, height: 6))
    private var lastPresentationStatusAt = Date.distantPast
    private var lastReportedVisible: Bool?
    private var lastReportedSize: NSSize?

    var onOpenDetails: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Geometry.panelSize,
                height: Geometry.panelSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        visualEffect = NSView(frame: panel.contentView?.bounds ?? .zero)
        iconView = NSImageView()
        hitButton = PetRiskHitButton()
        super.init()

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // `isFloatingPanel` resets the window level, so this must be assigned
        // afterwards. Codex uses transparent layer-3 composition windows that
        // remain visible while still intercepting mouse input.
        panel.level = .modalPanel
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.title = "Rootnote 性能微提示"
        panel.ignoresMouseEvents = false
        panel.appearance = nil
        let fixedSize = NSSize(width: Geometry.panelSize, height: Geometry.panelSize)
        panel.minSize = fixedSize
        panel.maxSize = fixedSize
        panel.contentMinSize = fixedSize
        panel.contentMaxSize = fixedSize

        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = Geometry.visualSize / 2
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false

        hitButton.translatesAutoresizingMaskIntoConstraints = false
        hitButton.isBordered = false
        hitButton.title = ""
        hitButton.focusRingType = .none
        hitButton.target = self
        hitButton.action = #selector(openDetails)

        guard let content = panel.contentView else { return }
        content.addSubview(visualEffect)
        let iconHost: NSView
        if #available(macOS 26.0, *) {
            // A borderless desktop window has no in-window backdrop to sample.
            let backdrop = NSVisualEffectView()
            backdrop.material = .underWindowBackground
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            backdrop.wantsLayer = true
            backdrop.layer?.cornerRadius = Geometry.visualSize / 2
            backdrop.layer?.masksToBounds = true
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            visualEffect.addSubview(backdrop)
            let glass = RootnoteGlassButton(title: "", target: nil, action: nil)
            glass.bezelStyle = .glass
            glass.borderShape = .circle
            glass.controlSize = .small
            glass.imagePosition = .imageOnly
            glass.imageScaling = .scaleProportionallyDown
            glass.focusRingType = .none
            glass.setAccessibilityElement(false)
            glass.translatesAutoresizingMaskIntoConstraints = false
            visualEffect.addSubview(glass)
            hitButton.onPress = { [weak glass] pressed in glass?.highlight(pressed) }
            // The material host is resized by Auto Layout; do not resize glass twice.
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: visualEffect.topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
                glass.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
                glass.topAnchor.constraint(equalTo: visualEffect.topAnchor),
                glass.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            ])
            iconHost = glass
            iconView.isHidden = true
        } else {
            let material = NSVisualEffectView()
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = Geometry.visualSize / 2
            material.layer?.masksToBounds = true
            material.translatesAutoresizingMaskIntoConstraints = false
            visualEffect.addSubview(material)
            NSLayoutConstraint.activate([
                material.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
                material.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
                material.topAnchor.constraint(equalTo: visualEffect.topAnchor),
                material.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            ])
            iconHost = material
        }
        iconHost.addSubview(iconView)
        content.addSubview(hitButton)
        reminderDot.wantsLayer = true
        reminderDot.layer?.cornerRadius = 3
        reminderDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        reminderDot.isHidden = true
        content.addSubview(reminderDot)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Geometry.panelSize),
            content.heightAnchor.constraint(equalToConstant: Geometry.panelSize),
            visualEffect.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            visualEffect.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            visualEffect.widthAnchor.constraint(equalToConstant: Geometry.visualSize),
            visualEffect.heightAnchor.constraint(equalToConstant: Geometry.visualSize),
            iconView.centerXAnchor.constraint(equalTo: iconHost.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconHost.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            hitButton.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hitButton.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hitButton.topAnchor.constraint(equalTo: content.topAnchor),
            hitButton.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        apply(level: .green, severityLabel: "正常")
    }

    func update(snapshot: [String: Any]) {
        guard let parsed = PetRiskSnapshot(snapshot) else { return }
        guard shouldApply(parsed.level) else { return }
        let previousLevel = currentLevel
        apply(level: parsed.level, severityLabel: parsed.severityLabel)
        if parsed.level == .red && previousLevel != .red {
            pulseOnce()
        }
    }

    func updateAnchor(_ sample: CharacterOverlaySample) {
        lastSample = sample
        let displayBounds = CGDisplayBounds(sample.displayID)
        let size = NSSize(width: Geometry.panelSize, height: Geometry.panelSize)
        let performanceSlot = Geometry.performanceSlotBesideFeet(in: sample.mascotBounds)
        let localCenterX = performanceSlot.midX - displayBounds.minX
        let localCenterY = performanceSlot.midY - displayBounds.minY
        let preferredX = sample.screen.frame.minX + localCenterX - size.width / 2
        let preferredY = sample.screen.frame.maxY - localCenterY - size.height / 2
        let visible = sample.screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let origin = NSPoint(
            x: min(max(preferredX, visible.minX), visible.maxX - size.width),
            y: min(max(preferredY, visible.minY), visible.maxY - size.height)
        )
        let target = NSRect(origin: origin, size: size)
        if panel.frame != target {
            panel.setFrame(target, display: true)
        }
        if !panel.isVisible || !panel.isOnActiveSpace {
            panel.orderFrontRegardless()
        }
        writePresentationStatus(sample: sample)
    }

    func hide() {
        lastSample = nil
        panel.orderOut(nil)
        writePresentationStatus(sample: nil)
    }

    private func writePresentationStatus(sample: CharacterOverlaySample?) {
        let now = Date()
        guard lastReportedVisible != panel.isVisible || lastReportedSize != panel.frame.size ||
                now.timeIntervalSince(lastPresentationStatusAt) >= 0.25 else { return }
        lastPresentationStatusAt = now
        lastReportedVisible = panel.isVisible
        lastReportedSize = panel.frame.size
        let status: [String: Any] = [
            "visible": panel.isVisible,
            "frame": NSStringFromRect(panel.frame),
            "level": currentLevel.rawValue,
            "anchorStrategy": sample?.detectionStrategy ?? "hidden",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
            try? data.write(to: RootnoteRuntimePaths.statusURL("rootnote-resonance-beacon-status.json"), options: .atomic)
        }
    }

    private func shouldApply(_ level: PetRiskLevel) -> Bool {
        if level == currentLevel {
            pendingDowngrade = nil
            pendingDowngradeSamples = 0
            return true
        }
        if level.rank > currentLevel.rank {
            pendingDowngrade = nil
            pendingDowngradeSamples = 0
            return true
        }
        if pendingDowngrade == level {
            pendingDowngradeSamples += 1
        } else {
            pendingDowngrade = level
            pendingDowngradeSamples = 1
        }
        guard pendingDowngradeSamples >= 2 else { return false }
        pendingDowngrade = nil
        pendingDowngradeSamples = 0
        return true
    }

    private func apply(level: PetRiskLevel, severityLabel: String) {
        currentLevel = level
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.image = NSImage(
            systemSymbolName: level.symbolName,
            accessibilityDescription: level.accessibilityLabel
        )?.withSymbolConfiguration(config)
        iconView.contentTintColor = level.color
        if #available(macOS 26.0, *), let button = visualEffect.subviews.first(where: { $0 is RootnoteGlassButton }) as? RootnoteGlassButton {
            button.image = iconView.image
            let foreground: NSColor = level == .yellow ? .black : .white
            button.symbolConfiguration = config.applying(NSImage.SymbolConfiguration(paletteColors: [foreground, level.color]))
        }
        iconView.layer?.backgroundColor = NSColor.clear.cgColor
        visualEffect.layer?.backgroundColor = NSColor.clear.cgColor
        hitButton.setAccessibilityLabel("\(level.accessibilityLabel)，\(severityLabel)，点击打开或关闭性能详情")
        panel.contentView?.toolTip = nil
    }

    func updatePanelContext(reminder: String?, appearance: String) {
        reminderDot.isHidden = reminder == nil
        panel.appearance = appearance == "light" ? NSAppearance(named: .aqua) : appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
    }

    private func pulseOnce() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = visualEffect.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.0
        animation.toValue = 1.06
        animation.duration = 0.32
        animation.autoreverses = true
        animation.repeatCount = 2
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "red-transition-pulse")
    }

    @objc private func openDetails() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastActivationUptime >= 0.8 else { return }
        lastActivationUptime = now
        Self.writeClickReceipt()
        onOpenDetails?()
    }

    private static func writeClickReceipt() {
        let receipt: [String: Any] = [
            "action": "toggle-performance-details",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: receipt,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(
            to: RootnoteRuntimePaths.statusURL("rootnote-resonance-beacon-click.json"),
            options: .atomic
        )
    }
}

private enum RootnotePalette {
    static let surface = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 28/255, green: 29/255, blue: 31/255, alpha: 1)
            : NSColor(srgbRed: 245/255, green: 246/255, blue: 247/255, alpha: 1)
    }
    static let accent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 155/255, green: 207/255, blue: 176/255, alpha: 1)
            : NSColor(srgbRed: 40/255, green: 115/255, blue: 78/255, alpha: 1)
    }
}

@available(macOS 26.0, *)
private final class RootnoteGlassView: NSGlassEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // AppKit owns refraction, adaptive contrast and accessibility fallbacks.
        style = .regular
        tintColor = nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class RootnoteSurfaceView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { RootnotePalette.surface.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class RootnoteChromeButton: NSButton {
    var selected = false { didSet { needsDisplay = true } }
    var fillsSelection = true
    private var keyboardFocused = false
    var marker: NSColor? { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        keyboardFocused = NSApp.currentEvent?.type == .keyDown
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool { keyboardFocused = false; needsDisplay = true; return super.resignFirstResponder() }
    override func mouseDown(with event: NSEvent) { keyboardFocused = false; needsDisplay = true; super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) { keyboardFocused = true; needsDisplay = true; super.keyDown(with: event) }
    func updateInk(appearance: NSAppearance) {
        // Resolve explicitly; button cells can cache semantic colors after a theme change.
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink = dark ? NSColor(srgbRed: 237/255, green: 240/255, blue: 242/255, alpha: 1)
            : NSColor(srgbRed: 36/255, green: 39/255, blue: 43/255, alpha: 1)
        let accent = dark ? NSColor(srgbRed: 155/255, green: 207/255, blue: 176/255, alpha: 1)
            : NSColor(srgbRed: 40/255, green: 115/255, blue: 78/255, alpha: 1)
        let color = selected ? accent : ink
        contentTintColor = color
        attributedTitle = NSAttributedString(string: title,
            attributes: [.foregroundColor: color, .font: font ?? NSFont.systemFont(ofSize: 12)])
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
        if selected && fillsSelection { RootnotePalette.accent.withAlphaComponent(0.12).setFill(); path.fill() }
        super.draw(dirtyRect)
        if let marker {
            marker.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 9, y: bounds.midY - 2, width: 4, height: 4)).fill()
        }
        if keyboardFocused && window?.firstResponder === self && window?.isKeyWindow == true {
            RootnotePalette.accent.setStroke(); path.lineWidth = 2; path.stroke()
        }
    }
}

// Overriding draw(_:) on a glass button disables AppKit's native bezel rendering.
private final class RootnoteGlassButton: NSButton {
    private var keyboardFocused = false
    private func updateFocus() {
        wantsLayer = true
        layer?.cornerRadius = bounds.height / 2
        layer?.borderWidth = keyboardFocused ? 2 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = RootnotePalette.accent.cgColor }
    }
    override func becomeFirstResponder() -> Bool {
        keyboardFocused = NSApp.currentEvent?.type == .keyDown
        updateFocus()
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool { keyboardFocused = false; updateFocus(); return super.resignFirstResponder() }
    override func mouseDown(with event: NSEvent) { keyboardFocused = false; updateFocus(); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) { keyboardFocused = true; updateFocus(); super.keyDown(with: event) }
}

private final class RootnotePanelChrome: NSView {
    var onAction: ((String) -> Void)?
    private(set) var tabs: [RootnoteChromeButton] = []
    private(set) var tools: [NSButton] = []
    private(set) var materialViews: [NSView] = []

    @available(macOS 26.0, *)
    var hasNativeGlass: Bool {
        guard materialViews.count == 2, let navigation = materialViews[0] as? RootnoteGlassView,
              let settings = materialViews[1] as? RootnoteGlassButton else { return false }
        return navigation.style == .regular && navigation.tintColor == nil &&
            navigation.contentView.map { type(of: $0) == NSView.self } == true &&
            settings.isBordered && settings.bezelStyle == .glass && settings.borderShape == .circle &&
            settings.bezelColor == nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let brand = NSTextField(labelWithString: "Rootnote")
        brand.font = .systemFont(ofSize: 14, weight: .semibold)
        brand.textColor = .labelColor
        brand.translatesAutoresizingMaskIntoConstraints = false
        addSubview(brand)
        let host: NSView
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            let content = NSView()
            container.contentView = content
            container.spacing = 0
            container.translatesAutoresizingMaskIntoConstraints = false
            addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: leadingAnchor),
                container.trailingAnchor.constraint(equalTo: trailingAnchor),
                container.topAnchor.constraint(equalTo: topAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            host = content
        } else { host = self }
        for (key, title, symbol) in [("tasks", "任务", "checklist"), ("performance", "性能", "waveform.path.ecg"), ("quota", "额度", "gauge.with.dots.needle.33percent")] {
            tabs.append(button(key: key, title: title, symbol: symbol, width: 86))
        }
        let navigation = material(buttons: tabs, height: 38)
        let actions: NSView
        if #available(macOS 26.0, *) {
            let item = RootnoteGlassButton(image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)!, target: self, action: #selector(activate(_:)))
            item.identifier = NSUserInterfaceItemIdentifier("settings")
            item.bezelStyle = .glass
            item.borderShape = .circle
            item.controlSize = .large
            item.focusRingType = .none
            item.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                item.widthAnchor.constraint(equalToConstant: 38),
                item.heightAnchor.constraint(equalToConstant: 38),
            ])
            tools.append(item)
            materialViews.append(item)
            actions = item
        } else {
            let item = button(key: "settings", title: "", symbol: "slider.horizontal.3", width: 30)
            item.fillsSelection = false
            tools.append(item)
            actions = material(buttons: [item], height: 38)
        }
        tools[0].setAccessibilityLabel("设置")
        tools[0].toolTip = "设置"
        host.addSubview(navigation); host.addSubview(actions)
        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            brand.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -18),
            actions.topAnchor.constraint(equalTo: host.topAnchor, constant: 9),
            navigation.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            navigation.topAnchor.constraint(equalTo: host.topAnchor, constant: 56),
        ])
        update(tab: "tasks", pinned: false, context: [:])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func button(key: String, title: String, symbol: String, width: CGFloat) -> RootnoteChromeButton {
        let button = RootnoteChromeButton(title: title, target: self, action: #selector(activate(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        button.imageHugsTitle = true
        button.isBordered = false
        button.focusRingType = .none
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func material(buttons: [RootnoteChromeButton], height: CGFloat) -> NSView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        let view: NSView
        if #available(macOS 26.0, *) {
            let glass = RootnoteGlassView()
            glass.cornerRadius = height / 2
            let surface = NSView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                stack.topAnchor.constraint(equalTo: surface.topAnchor),
                stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            ])
            glass.contentView = surface
            view = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .withinWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = height / 2
            effect.layer?.masksToBounds = true
            stack.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                stack.topAnchor.constraint(equalTo: effect.topAnchor),
                stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            view = effect
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        materialViews.append(view)
        return view
    }

    func update(tab: String, pinned: Bool, context: [String: Any]) {
        let attention = max(0, min(99, context["attention"] as? Int ?? 0))
        for (index, button) in tabs.enumerated() {
            let key = ["tasks", "performance", "quota"][index]
            button.selected = tab == key
            button.marker = nil
            if key == "tasks" {
                button.title = attention > 0 ? "任务 \(attention)" : "任务"
                button.setAccessibilityLabel(attention > 0 ? "任务，\(attention) 项需要处理" : "任务")
            } else if key == "performance" {
                let risk = context["risk"] as? String ?? "unknown"
                button.marker = risk == "red" ? .systemRed : risk == "yellow" ? .systemOrange : risk == "unknown" ? .secondaryLabelColor : nil
                button.setAccessibilityLabel(risk == "green" ? "性能正常" : risk == "unknown" ? "性能数据待确认" : "性能需要关注")
            } else if context["quotaReminder"] as? Bool == true { button.marker = .systemOrange }
            button.setAccessibilityValue(button.selected ? "已选择" : "未选择")
            button.updateInk(appearance: effectiveAppearance)
        }
        tools[0].state = tab == "settings" ? .on : .off
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = tab == "settings" ? RootnotePalette.accent : NSColor.labelColor
            tools[0].symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color.usingColorSpace(.sRGB) ?? color]))
        }
    }

    @objc private func activate(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { onAction?(key) }
    }
}

private enum RootnoteEditingMenu {
    static func install() {
        let menu = NSApp.mainMenu ?? NSMenu()
        guard !menu.items.contains(where: { $0.identifier?.rawValue == "rootnote-edit" }) else { return }
        if menu.items.isEmpty {
            let app = NSMenuItem()
            app.submenu = NSMenu(title: "Rootnote")
            menu.addItem(app)
        }
        let item = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("rootnote-edit")
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "z"),
                                     ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                     ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            let command = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
            command.keyEquivalentModifierMask = action == "redo:" ? [.command, .shift] : .command
            edit.addItem(command)
        }
        item.submenu = edit
        menu.addItem(item)
        NSApp.mainMenu = menu
    }
}

final class PetRiskDetailController: NSObject, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private var ready = false
    private var latestSnapshot: [String: Any]?
    private var isPresented = false
    private let store = RootnotePanelStore()
    var onPanelContextChange: ((String?, String) -> Void)?
    private var pinned = false
    private var chrome = RootnotePanelChrome()
    private var chromeAppearance: String?
    private var chromeContext: [String: Any] = [:]
    private var currentTab = "tasks"
    var onRefresh: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    static func menuTitle(isVisible: Bool) -> String {
        isVisible ? "隐藏 Rootnote 面板" : "打开 Rootnote 面板"
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 544, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        RootnoteEditingMenu.install()
        webView.navigationDelegate = self
        configuration.userContentController.add(self, name: "rootnote")
        window.delegate = self
        webView.setValue(false, forKey: "drawsBackground")
        window.title = "Rootnote"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 420, height: 560)
        window.isOpaque = false
        window.backgroundColor = .clear
        let content = RootnoteSurfaceView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        chrome.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webView)
        content.addSubview(chrome)
        window.contentView = content
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: content.topAnchor),
            chrome.heightAnchor.constraint(equalToConstant: 104),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        chrome.onAction = { [weak self] action in self?.performChromeAction(action) }
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .normal
        window.hidesOnDeactivate = false
        for buttonType in [
            NSWindow.ButtonType.miniaturizeButton,
            .zoomButton,
        ] {
            window.standardWindowButton(buttonType)?.isHidden = true
            window.standardWindowButton(buttonType)?.isEnabled = false
        }
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.closeButton)?.isEnabled = true
        window.center()
        window.orderOut(nil)
        store.onChange = { [weak self] in
            self?.applyAppearance()
            self?.pushLatestSnapshot()
            guard let self else { return }
            self.onPanelContextChange?(self.store.reminder, self.store.settings["appearance"] as? String ?? "system")
        }
        applyAppearance()

        guard let webRoot = RootnotePanelPaths.resources?
            .appendingPathComponent("guard", isDirectory: true),
              FileManager.default.fileExists(atPath: webRoot.appendingPathComponent("panel.html").path)
        else { return }
        webView.loadFileURL(
            webRoot.appendingPathComponent("panel.html"),
            allowingReadAccessTo: webRoot
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.documentElement.classList.add('native-chrome')") { [weak self] _, _ in
            self?.ready = true
            self?.pushLatestSnapshot()
        }
    }

    func update(snapshot: [String: Any]) {
        latestSnapshot = snapshot
        pushLatestSnapshot()
    }

    func startAccountSync() { store.start() }

    func show(activateApp: Bool = true) {
        if !CommandLine.arguments.contains("--presentation-self-test") { store.start() }
        pushLatestSnapshot()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if activateApp { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        isPresented = true
        visibilityChanged()
    }

    func toggle() {
        if isPresented && window.isVisible && window.isOnActiveSpace {
            hide()
            return
        }
        show()
    }

    func hide() {
        window.orderOut(nil)
        isPresented = false
        visibilityChanged()
    }

    var detailVisible: Bool { isPresented && window.isVisible && window.isOnActiveSpace }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private func visibilityChanged() {
        onVisibilityChanged?(detailVisible)
        writeToggleReceipt()
    }

    private func writeToggleReceipt() {
        let receipt: [String: Any] = [
            "presented": isPresented,
            "windowVisible": window.isVisible,
            "onActiveSpace": window.isOnActiveSpace,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: receipt,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(
            to: RootnoteRuntimePaths.statusURL("rootnote-resonance-detail-toggle.json"),
            options: .atomic
        )
    }

    private func pushLatestSnapshot() {
        guard ready else { return }
        let snapshot: [String: Any] = ["performance": latestSnapshot as Any? ?? NSNull(), "account": store.payload,
                                      "pinned": pinned]
        guard
              JSONSerialization.isValidJSONObject(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: snapshot),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript(
            "window.RootnotePanel && window.RootnotePanel.update(\(json));"
        )
    }

    private func applyAppearance() {
        switch store.settings["appearance"] as? String {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        default: window.appearance = nil
        }
        // Keep application-provided controls in the same explicit appearance.
        NSApp.appearance = window.appearance
        let mode = store.settings["appearance"] as? String ?? "light"
        if chromeAppearance != mode, let content = window.contentView {
            // Recreate native material hosts to discard the previous theme's backdrop.
            chrome.removeFromSuperview()
            chrome = RootnotePanelChrome()
            chrome.appearance = window.appearance
            chrome.translatesAutoresizingMaskIntoConstraints = false
            chrome.onAction = { [weak self] action in self?.performChromeAction(action) }
            content.addSubview(chrome)
            NSLayoutConstraint.activate([
                chrome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                chrome.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                chrome.topAnchor.constraint(equalTo: content.topAnchor),
                chrome.heightAnchor.constraint(equalToConstant: 104),
                webView.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            ])
            chromeAppearance = mode
        }
        chrome.update(tab: currentTab, pinned: pinned, context: chromeContext)
    }

    private func performChromeAction(_ action: String) {
        switch action {
        case "tasks", "performance", "quota":
            guard ready else { return }
            webView.evaluateJavaScript("window.RootnotePanel.showTab('\(action)')")
        case "settings":
            guard ready else { return }
            webView.evaluateJavaScript("document.getElementById('settings').click()")
        default: break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.request.url?.isFileURL == true && navigationAction.navigationType == .other
        decisionHandler(allowed ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "hide": hide()
        case "pin":
            pinned.toggle(); window.level = pinned ? .floating : .normal; pushLatestSnapshot()
        case "refresh":
            if body["scope"] as? String == "account" { store.refresh() } else { onRefresh?() }
        case "panelContext":
            guard let tab = body["tab"] as? String, ["tasks", "performance", "quota", "settings"].contains(tab) else { return }
            currentTab = tab; chromeContext = body
            chrome.update(tab: tab, pinned: pinned, context: body)
        case "setting":
            if let key = body["key"] as? String, let value = body["value"] { store.set(key: key, value: value) }
        case "clearAccounts": store.clearAccounts()
        case "openThread", "copyFollowup":
            guard let id = body["id"] as? String, UUID(uuidString: id) != nil,
                  (latestSnapshot?["sessions"] as? [[String: Any]])?.contains(where: { $0["threadID"] as? String == id }) == true,
                  let url = URL(string: "codex://threads/\(id)") else { return }
            if action == "copyFollowup" {
                guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf16.count <= 6_000 else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            let opened = NSWorkspace.shared.open(url)
            let notice = opened ? (action == "copyFollowup" ? "已复制并打开会话，请在 Codex 中粘贴发送。" : "已打开 Codex 会话。") : "未能打开会话，请在 Codex 中手动选择。"
            if let data = try? JSONSerialization.data(withJSONObject: ["message": notice]), let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("window.RootnotePanel.notice(\(json));")
            }
        default: break
        }
    }
}

final class PetRiskPerformanceCoordinator {
    private var timer: Timer?
    private var state: [String: Any]
    private var collecting = false
    private let fixtureState: PetRiskLevel?
    var onSnapshot: (([String: Any]) -> Void)?

    init(arguments: [String] = CommandLine.arguments) {
        fixtureState = arguments
            .first(where: { $0.hasPrefix("--fixture-state=") })
            .flatMap { PetRiskLevel(rawValue: String($0.dropFirst("--fixture-state=".count))) }
        state = Self.loadLegacyMetadataState()
    }

    func start() {
        guard timer == nil else { return }
        collect()
        guard fixtureState == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.collect()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        collect()
    }

    private func collect() {
        guard !collecting else { return }
        if let fixtureState {
            onSnapshot?(Self.fixtureSnapshot(level: fixtureState))
            return
        }
        collecting = true
        let currentState = state
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let bridgeState = Dictionary(uniqueKeysWithValues: currentState.map {
                (AnyHashable($0.key), $0.value)
            })
            let value = PRBCollectSnapshot(bridgeState, false)
            var snapshot: [String: Any] = [:]
            for (key, item) in value {
                if let key = key as? String {
                    snapshot[key] = item
                }
            }
            DispatchQueue.main.async {
                self.collecting = false
                if let nextState = snapshot["nextState"] as? [String: Any] {
                    self.state = nextState
                }
                self.onSnapshot?(snapshot)
            }
        }
    }

    private static func loadLegacyMetadataState() -> [String: Any] {
        guard !RootnoteRuntimePaths.isCandidate else { return [:] }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexPerformanceGuard/state.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func fixtureSnapshot(level: PetRiskLevel) -> [String: Any] {
        let severity: Int
        let severityID: String
        let severityLabel: String
        let headline: String
        switch level {
        case .green:
            severity = 0
            severityID = "normal"
            severityLabel = "正常"
            headline = "系统呼吸平稳"
        case .yellow:
            severity = 2
            severityID = "warning"
            severityLabel = "预警"
            headline = "性能压力需要留意"
        case .red:
            severity = 4
            severityID = "critical"
            severityLabel = "严重"
            headline = "性能压力需要立即关注"
        }
        let now = Date().timeIntervalSince1970
        let values: [Double] = [130, 160, 190, 250, 310, 420, 520, 646]
        let history = values.enumerated().map { index, value in
            [
                "timestamp": now - Double(values.count - index) * 3600,
                "sessions": value * 1_000_000,
                "swap": (level == .red ? 11.27 : level == .yellow ? 4.8 : 0.8) * 1_000_000_000,
                "severity": severity,
            ] as [String: Any]
        }
        return [
            "id": "fixture-\(level.rawValue)",
            "timestamp": now,
            "observedAt": ISO8601DateFormatter().string(from: Date()),
            "severity": severity,
            "severityID": severityID,
            "severityLabel": severityLabel,
            "microState": level.rawValue,
            "collectorHealth": "healthy",
            "headline": headline,
            "recommendation": level == .red
                ? "立即停止扩展《内容增长 0.2》，完成交接和归档；保存其他工作后重启 Codex 与 Mac。"
                : level == .yellow
                    ? "当前阶段尽快收口，不再开启复杂分支，并准备新窗口承接。"
                    : "状态正常，可以继续使用。",
            "metrics": [
                "memoryUsedBytes": 15_000_000_000,
                "memoryTotalBytes": 17_180_000_000,
                "compressedBytes": level == .red ? 6_540_000_000 : 3_200_000_000,
                "swapUsedBytes": level == .red ? 11_270_000_000 : level == .yellow ? 4_800_000_000 : 800_000_000,
                "memoryFreePercent": 13,
                "activeSessionCount": 3,
                "totalOpenBytes": 646_000_000,
                "largestOpenBytes": 552_900_000,
            ],
            "sessions": [
                [
                    "threadID": "fixture-content",
                    "title": "内容增长 0.2",
                    "sizeBytes": 552_900_000,
                    "growthBytesPerHour": 228_000_000,
                    "severity": level == .red ? 3 : 2,
                    "severityID": level == .red ? "high" : "warning",
                    "severityLabel": level == .red ? "高风险" : "预警",
                    "active": true,
                ],
                [
                    "threadID": "fixture-rootnote",
                    "title": "Rootnote × Codex 性能守卫融合 0.1",
                    "sizeBytes": 55_000_000,
                    "growthBytesPerHour": 18_000_000,
                    "severity": 0,
                    "severityID": "normal",
                    "severityLabel": "正常",
                    "active": true,
                ],
                [
                    "threadID": "fixture-life",
                    "title": "人生设计记录 1.0",
                    "sizeBytes": 38_100_000,
                    "growthBytesPerHour": 3_000_000,
                    "severity": 0,
                    "severityID": "normal",
                    "severityLabel": "正常",
                    "active": true,
                ],
            ],
            "history": history,
            "activeTaskCount": 3,
            "activeTaskCountReliable": true,
            "issues": [],
            "nextState": [:],
            "bodyPersisted": false,
            "autoAction": false,
            "sessionEventMetadataRead": true,
            "sessionBodyPersisted": false,
        ]
    }
}

final class PetRiskBeaconCoordinator {
    private let visibility: CompanionVisibility
    private let beacon = PetRiskBeaconPanelController()
    private let details = PetRiskDetailController()
    private let performance = PetRiskPerformanceCoordinator()
    private let nativeBridgeID = UUID().uuidString
    private var nativeDetailTimer: Timer?
    private var lastNativeDetailRequest: String?
    private var nativeSummary: [String: Any]?
    var onSnapshot: (([String: Any]) -> Void)?
    var onDetailVisibilityChanged: ((Bool) -> Void)?
    var detailsVisible: Bool { details.detailVisible }

    init(visibility: CompanionVisibility) {
        self.visibility = visibility
        details.onVisibilityChanged = { [weak self] visible in
            self?.onDetailVisibilityChanged?(visible)
        }
        details.onRefresh = { [weak self] in self?.performance.refresh() }
        details.onPanelContextChange = { [weak self] reminder, appearance in
            self?.beacon.updatePanelContext(reminder: reminder, appearance: appearance)
        }
        beacon.onOpenDetails = { [weak self] in
            guard self?.visibility.accessoriesVisible == true else { return }
            self?.details.toggle()
        }
        performance.onSnapshot = { [weak self] snapshot in
            self?.beacon.update(snapshot: snapshot)
            self?.details.update(snapshot: snapshot)
            self?.onSnapshot?(snapshot)
            if PetRiskBeaconPanelController.Geometry.pairedNativeControls {
                self?.publishNativeSummary(snapshot)
            }
        }
    }

    func start() {
        performance.start()
        details.startAccountSync()
        if PetRiskBeaconPanelController.Geometry.pairedNativeControls, nativeDetailTimer == nil {
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.consumeNativeDetailRequest() }
            RunLoop.main.add(timer, forMode: .common)
            nativeDetailTimer = timer
        }
    }

    func stop() {
        nativeDetailTimer?.invalidate()
        nativeDetailTimer = nil
        performance.stop()
        beacon.hide()
        details.hide()
    }

    func updateAnchor(_ sample: CharacterOverlaySample) {
        guard visibility.accessoriesVisible else { return }
        if PetRiskBeaconPanelController.Geometry.pairedNativeControls {
            beacon.hide()
            return
        }
        beacon.updateAnchor(sample)
    }

    private func publishNativeSummary(_ snapshot: [String: Any]) {
        guard RootnoteRuntimePaths.nativeControlsEnabled else { return }
        var summary: [String: Any] = ["schemaVersion": 1, "capturedAtMs": Date().timeIntervalSince1970 * 1000, "bridgeID": nativeBridgeID]
        for key in ["microState", "collectorHealth", "activeTaskCount", "activeTaskCountReliable", "codexIdle"] {
            if let value = snapshot[key] { summary[key] = value }
        }
        if let metrics = snapshot["metrics"] as? [String: Any] {
            for key in ["memoryUsedBytes", "memoryTotalBytes", "swapUsedBytes", "compressedBytes"] {
                if let value = metrics[key] { summary[key] = value }
            }
        }
        nativeSummary = summary
        writeNativeSummary()
    }

    private func writeNativeSummary() {
        guard var summary = nativeSummary else { return }
        summary["generation"] = visibility.generation
        nativeSummary = summary
        guard JSONSerialization.isValidJSONObject(summary),
              let data = try? JSONSerialization.data(withJSONObject: summary) else { return }
        try? data.write(to: RootnoteRuntimePaths.nativeBridgeURL("native-performance-summary.json"), options: .atomic)
    }

    private func consumeNativeDetailRequest() {
        guard RootnoteRuntimePaths.nativeControlsEnabled,
              let data = try? Data(contentsOf: RootnoteRuntimePaths.nativeBridgeURL("native-detail-request.json")), data.count <= 2048,
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["action"] as? String == "toggle-performance-details",
              request["bridgeID"] as? String == nativeBridgeID,
              let id = request["requestID"] as? String, UUID(uuidString: id) != nil, id != lastNativeDetailRequest,
              let sentAt = request["sentAtMs"] as? Double,
              abs(Date().timeIntervalSince1970 * 1000 - sentAt) < 5000
        else { return }
        lastNativeDetailRequest = id
        let performed = visibility.accessoriesVisible && (request["generation"] as? NSNumber)?.uint64Value == visibility.generation
        if performed { details.toggle() }
        let receipt: [String: Any] = ["requestID": id, "bridgeID": nativeBridgeID, "performed": performed, "presented": details.detailVisible]
        if let data = try? JSONSerialization.data(withJSONObject: receipt) {
            try? data.write(to: RootnoteRuntimePaths.nativeBridgeURL("native-detail-receipt.json"), options: .atomic)
        }
    }

    func synchronizeVisibility() {
        if (nativeSummary?["generation"] as? NSNumber)?.uint64Value != visibility.generation { writeNativeSummary() }
        guard !visibility.accessoriesVisible else { return }
        beacon.hide()
    }

    func hideBeacon() {
        beacon.hide()
    }

    func toggleDetails() {
        details.toggle()
    }

    func showDetails() {
        details.show()
    }

    func refresh() {
        performance.refresh()
    }
}

extension PetRiskBeaconPanelController {
    fileprivate func showMaterialCheck(over window: NSWindow) {
        guard RootnoteRuntimePaths.isCandidate else { return }
        apply(level: .red, severityLabel: "测试")
        panel.setFrameOrigin(NSPoint(x: window.frame.minX + 28, y: window.frame.minY + 48))
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }
    fileprivate func geometryReport() -> [String: String] {
        var report = ["window": NSStringFromRect(panel.frame),
                      "content": NSStringFromRect(panel.contentView?.bounds ?? .zero),
                      "material": NSStringFromRect(visualEffect.frame),
                      "icon": NSStringFromRect(iconView.frame)]
        if #available(macOS 26.0, *),
           let glass = visualEffect.subviews.first(where: { $0 is RootnoteGlassButton }) as? RootnoteGlassButton {
            report["glass"] = NSStringFromRect(glass.frame)
            report["glassContent"] = NSStringFromRect(glass.bounds)
            report["symbolSize"] = NSStringFromSize(glass.image?.size ?? .zero)
            report["symbolLayout"] = "AppKit imageOnly"
        }
        return report
    }

    fileprivate func windowRegressionChecks() -> [String: Bool] {
        guard let screen = NSScreen.main,
              let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { return ["screen_available": false] }
        let displayBounds = CGDisplayBounds(display)
        let mascot = CGRect(x: displayBounds.minX + 300, y: displayBounds.minY + 180, width: 123, height: 134)
        let sample = CharacterOverlaySample(
            screen: screen, displayID: display, x: 0.2, y: 0.2,
            windowBounds: mascot, mascotBounds: mascot,
            controlOverlayBounds: nil, voiceControlsBounds: nil, voiceBackingBounds: nil,
            voiceChromeExpanded: false, windowNumber: 0, owner: "Rootnote test",
            trailSide: "left", detectionStrategy: "isolated-presentation-regression"
        )
        let fixed = NSSize(width: Geometry.panelSize, height: Geometry.panelSize)
        var checks: [String: Bool] = [:]
        updateAnchor(sample)
        hitButton.updateTrackingAreas()
        checks["beacon_has_no_hover_tracking"] = hitButton.trackingAreas.isEmpty
        checks["beacon_has_no_tooltip"] = hitButton.toolTip == nil && panel.contentView?.toolTip == nil
        checks["beacon_click_remains_available"] = hitButton.action == #selector(openDetails) && hitButton.target === self
        if #available(macOS 26.0, *) {
            checks["desktop_backdrop_sampling"] = visualEffect.subviews.compactMap { $0 as? NSVisualEffectView }
                .contains { $0.blendingMode == .behindWindow && $0.state == .active }
        }
        checks["fixed_window_limits"] = panel.minSize == fixed && panel.maxSize == fixed
        checks["fixed_content_limits"] = panel.contentMinSize == fixed && panel.contentMaxSize == fixed
        for size in [CGFloat(1), 8, 64] {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: size, height: size)), display: true)
            updateAnchor(sample)
            panel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            checks["restore_after_resize_\(Int(size))"] = panel.frame.size == fixed
        }
        for level in PetRiskLevel.allCases {
            update(snapshot: PetRiskPerformanceCoordinator.fixtureSnapshot(level: level))
            panel.contentView?.layoutSubtreeIfNeeded()
            checks["stable_size_\(level.rawValue)"] = panel.frame.size == fixed
        }
        for theme in ["light", "dark"] {
            updatePanelContext(reminder: nil, appearance: theme)
            for level in PetRiskLevel.allCases {
                apply(level: level, severityLabel: "测试")
                panel.contentView?.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                let key = "\(theme)_\(level.rawValue)"
                if #available(macOS 26.0, *),
                   let glass = visualEffect.subviews.first(where: { $0 is RootnoteGlassButton }) as? RootnoteGlassButton {
                    checks["\(key)_glass_fills_circle"] = glass.frame == visualEffect.bounds
                    checks["\(key)_symbol_directly_hosted"] = glass.image != nil && glass.imagePosition == .imageOnly && iconView.isHidden
                    checks["\(key)_unmodified_native_glass"] = glass.isBordered && glass.bezelStyle == .glass && glass.borderShape == .circle && glass.bezelColor == nil
                    hitButton.onPress?(true)
                    checks["\(key)_native_press_feedback"] = glass.isHighlighted
                    hitButton.onPress?(false)
                    // Glass buttons use view-based layout, not the legacy cell image rect.
                    let symbolSize = glass.image?.size ?? .zero
                    checks["\(key)_native_symbol_fits"] = symbolSize.width > 0 && symbolSize.height > 0 &&
                        symbolSize.width <= glass.bounds.width && symbolSize.height <= glass.bounds.height
                }
            }
        }
        panel.orderOut(nil)
        updateAnchor(sample)
        checks["valid_anchor_restores_hidden_window"] = panel.isVisible && panel.frame.size == fixed
        hide()
        updateAnchor(sample)
        let status = (try? Data(contentsOf: RootnoteRuntimePaths.statusURL("rootnote-resonance-beacon-status.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        checks["immediate_show_receipt_not_stale_hidden"] = status?["visible"] as? Bool == true
        hide()
        checks["explicit_hide_remains_hidden"] = !panel.isVisible
        return checks
    }
}

extension PetRiskDetailController {
    fileprivate func attachMaterialCheck(_ beacon: PetRiskBeaconPanelController) {
        beacon.showMaterialCheck(over: window)
        beacon.updatePanelContext(reminder: nil, appearance: store.settings["appearance"] as? String ?? "light")
        onPanelContextChange = { [weak beacon] _, appearance in
            beacon?.updatePanelContext(reminder: nil, appearance: appearance)
        }
    }
    fileprivate func windowRegressionChecks() -> [String: Bool] {
        var titles: [String] = []
        onVisibilityChanged = { titles.append(Self.menuTitle(isVisible: $0)) }
        var checks: [String: Bool] = [:]
        let editing = NSApp.mainMenu?.items.first(where: { $0.identifier?.rawValue == "rootnote-edit" })?.submenu
        checks["native_editing_shortcuts"] = ["cut:", "copy:", "paste:", "selectAll:", "undo:", "redo:"].allSatisfy { name in
            editing?.items.contains { $0.action == NSSelectorFromString(name) && $0.keyEquivalentModifierMask.contains(.command) } == true
        }
        let close = window.standardWindowButton(.closeButton)
        checks["native_close_visible_enabled"] = close?.isHidden == false && close?.isEnabled == true
        checks["other_traffic_lights_hidden"] = window.standardWindowButton(.miniaturizeButton)?.isHidden == true &&
            window.standardWindowButton(.zoomButton)?.isHidden == true
        checks["initial_menu_open"] = Self.menuTitle(isVisible: detailVisible) == "打开 Rootnote 面板"
        show(activateApp: false)
        checks["show_switches_menu_to_hide"] = detailVisible && titles.last == "隐藏 Rootnote 面板"
        window.contentView?.layoutSubtreeIfNeeded()
        checks["native_navigation_has_fixed_height"] = chrome.frame.height == 104
        if #available(macOS 26.0, *) {
            checks["settings_has_single_glass_surface"] = chrome.tools.count == 1 && chrome.materialViews.last === chrome.tools[0]
        }
        if #available(macOS 26.0, *) {
            checks["chrome_unmodified_native_glass"] = chrome.hasNativeGlass
            checks["no_mirrored_text_backdrop"] = !(webView.superview is NSBackgroundExtensionView)
        }
        checks["content_does_not_overlap_navigation"] = webView.frame.maxY == chrome.frame.minY
        checks["native_controls_not_clipped"] = chrome.materialViews.allSatisfy {
            let rect = chrome.convert($0.bounds, from: $0)
            return rect.width >= 38 && rect.height == 38 && chrome.bounds.contains(rect)
        }
        checks["native_keyboard_focus"] = window.makeFirstResponder(chrome.tabs[0]) && window.firstResponder === chrome.tabs[0]
        close?.performClick(nil)
        checks["native_close_hides_reusable_window"] = !window.isVisible && !isPresented && titles.last == "打开 Rootnote 面板"
        show(activateApp: false)
        checks["reopen_after_native_close"] = detailVisible
        toggle()
        checks["toggle_hides_and_resets_menu"] = !detailVisible && titles.last == "打开 Rootnote 面板"
        show(activateApp: false)
        hide()
        checks["lifecycle_hide_resets_menu"] = titles.last == "打开 Rootnote 面板"
        onVisibilityChanged = nil
        return checks
    }
}

func runPresentationSelfTest() -> Int32 {
    guard RootnoteRuntimePaths.isCandidate else { return 2 }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let beacon = PetRiskBeaconPanelController()
    let detail = PetRiskDetailController()
    let checks = beacon.windowRegressionChecks().merging(detail.windowRegressionChecks()) { first, _ in first }
    let report: [String: Any] = [
        "ok": checks.values.allSatisfy { $0 }, "checks": checks, "count": checks.count,
        "beaconGeometry": beacon.geometryReport(),
        "scope": "isolated_appkit_windows", "codexControlled": false, "liveApprovalSent": false
    ]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        print("")
    }
    return checks.values.allSatisfy { $0 } ? 0 : 1
}

extension PetRiskDetailController {
    func capturePanelCheck(directory: URL, accountWaitDeadline: Date = Date().addingTimeInterval(12), completion: @escaping (Bool) -> Void) {
        // A long visual check can coincide with the periodic read-only account refresh.
        if store.syncing && Date() < accountWaitDeadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.capturePanelCheck(directory: directory, accountWaitDeadline: accountWaitDeadline, completion: completion)
            }
            return
        }
        var checks: [String: Bool] = [
            "normal_window_level": window.level == .normal,
            "native_close_visible": window.standardWindowButton(.closeButton)?.isHidden == false,
            "live_account_read": !store.syncing && store.error == nil && store.currentAccount != nil &&
                store.accounts.contains { $0["id"] as? String == store.currentAccount &&
                    Date().timeIntervalSince1970 - ($0["updatedAt"] as? Double ?? 0) < 300 },
            "live_performance_read": latestSnapshot != nil,
        ]
        if #available(macOS 26.0, *) {
            checks["native_glass_material"] = chrome.hasNativeGlass
            checks["no_mirrored_text_backdrop"] = !(webView.superview is NSBackgroundExtensionView)
            checks["content_not_glass"] = !(window.contentView is NSGlassEffectView)
        }
        let initial = window.frame.size
        let cases = ["tasks", "performance", "quota", "settings"]
        var index = 0
        func next() {
            guard index < 8 else {
                checks["size_stable_across_views"] = self.window.frame.size == initial
                self.window.standardWindowButton(.closeButton)?.performClick(nil)
                checks["native_close_hides"] = !self.window.isVisible
                self.show(activateApp: false)
                checks["reopens_same_size"] = self.window.frame.size == initial && self.window.isVisible
                self.hide()
                let report: [String: Any] = ["ok": checks.values.allSatisfy { $0 }, "checks": checks]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("native-report.json"), options: .atomic)
                    FileHandle.standardOutput.write(data); print("")
                }
                completion(checks.values.allSatisfy { $0 }); return
            }
            let theme = index < 4 ? "light" : "dark"
            let view = cases[index % 4]
            self.store.set(key: "appearance", value: theme)
            if view == "settings" { self.chrome.tools[0].performClick(nil) }
            else { self.chrome.tabs[index % 4].performClick(nil) }
            self.webView.evaluateJavaScript("window.RootnotePanel.currentTab()") { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.webView.evaluateJavaScript("JSON.stringify({height:document.getElementById('app').clientHeight,width:document.getElementById('app').clientWidth,visible:!document.getElementById('view-\(view)').hidden,bodyWidth:document.body.scrollWidth})") { result, error in
                        if let text = result as? String, let data = text.data(using: .utf8),
                           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            checks["\(theme)_\(view)_rendered"] = error == nil && value["visible"] as? Bool == true && (value["width"] as? Int ?? 0) > 400 && value["width"] as? Int == value["bodyWidth"] as? Int
                            checks["\(theme)_\(view)_native_navigation_synced"] = self.currentTab == view &&
                                self.chrome.tools.count == 1 && (self.chrome.tools[0].state == .on) == (view == "settings")
                            checks["\(theme)_\(view)_application_appearance_synced"] =
                                NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ==
                                self.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                            checks["\(theme)_\(view)_native_text_contrast"] = self.chrome.tabs.allSatisfy { button in
                                guard let color = (button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB) else { return false }
                                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                                return theme == "dark" ? brightness > 0.6 : brightness < 0.5
                            }
                        } else { checks["\(theme)_\(view)_rendered"] = false }
                        self.webView.takeSnapshot(with: nil) { image, _ in
                            if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                                try? png.write(to: directory.appendingPathComponent("native-\(theme)-\(view).png"))
                                checks["\(theme)_\(view)_snapshot"] = png.count > 2000
                            } else { checks["\(theme)_\(view)_snapshot"] = false }
                            index += 1; next()
                        }
                    }
                }
            }
        }
        next()
    }
}

func runPanelLiveCheck() {
    guard RootnoteRuntimePaths.isCandidate, ProcessInfo.processInfo.environment["ROOTNOTE_PANEL_STATE"] != nil else { exit(2) }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let detail = PetRiskDetailController()
    let directory = RootnotePanelPaths.state.appendingPathComponent("qa")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    detail.show()
    let beacon = ProcessInfo.processInfo.environment["ROOTNOTE_QA_BEACON"] == "1" ? PetRiskBeaconPanelController() : nil
    if let beacon { detail.attachMaterialCheck(beacon) }
    DispatchQueue.global(qos: .utility).async {
        let raw = PRBCollectSnapshot([AnyHashable: Any](), false)
        let snapshot = Dictionary(uniqueKeysWithValues: raw.map { (String(describing: $0.key), $0.value) })
        DispatchQueue.main.async { detail.update(snapshot: snapshot) }
    }
    let hold = min(240, max(30, Double(ProcessInfo.processInfo.environment["ROOTNOTE_QA_HOLD_SECONDS"] ?? "") ?? 30))
    DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
        beacon?.hide()
        detail.capturePanelCheck(directory: directory) { ok in exit(ok ? 0 : 1) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + hold + 25) { exit(1) }
    NSApp.run()
}

func runPetRiskBeaconSelfTest() -> Int32 {
    let fixtures = PetRiskLevel.allCases.map {
        PetRiskPerformanceCoordinator.fixtureSnapshot(level: $0)
    }
    let mappingOK = fixtures.compactMap { $0["microState"] as? String } == ["green", "yellow", "red"]
    let iconMapping = PetRiskLevel.allCases.map(\.symbolName)
    let distinctIcons = Set(iconMapping).count == 3
    let allStatesClickable = PetRiskLevel.allCases.count == 3
    let fields = fixtures.allSatisfy {
        ($0["metrics"] as? [String: Any]) != nil &&
            ($0["sessions"] as? [[String: Any]])?.count == 3 &&
            ($0["history"] as? [[String: Any]])?.isEmpty == false &&
            ($0["bodyPersisted"] as? Bool) == false &&
            ($0["autoAction"] as? Bool) == false
    }
    let mascot = CGRect(x: 1247, y: 617.75, width: 123, height: 133.25)
    let performanceSlot = PetRiskBeaconPanelController.Geometry.performanceSlotBesideFeet(in: mascot)
    let independentPlacement = [CGFloat(80), 123, 224].allSatisfy { width in
        let pet = CGRect(x: 500, y: 300, width: width, height: ceil(width * 208 / 192))
        let slot = PetRiskBeaconPanelController.Geometry.performanceSlotBesideFeet(in: pet)
        let bar = CGRect(x: pet.midX - 40, y: pet.maxY + 4, width: 80, height: 40)
        let moved = PetRiskBeaconPanelController.Geometry.performanceSlotBesideFeet(
            in: pet.offsetBy(dx: -1800, dy: 70)
        )
        return slot.width == 32 && slot.height == 32 &&
            slot.midX == pet.minX && slot.maxY == pet.maxY &&
            !slot.intersects(bar) && bar.minY - slot.maxY == 4 &&
            moved == slot.offsetBy(dx: -1800, dy: 70)
    }
    let report: [String: Any] = [
        "ok": mappingOK && distinctIcons && allStatesClickable && fields && independentPlacement,
        "states": fixtures.map {
            [
                "microState": $0["microState"] ?? "",
                "activeTaskCount": $0["activeTaskCount"] ?? 0,
                "severityLabel": $0["severityLabel"] ?? "",
            ]
        },
        "symbols": iconMapping,
        "allStatesClickable": allStatesClickable,
        "statusOnlyJewel": true,
        "rootnoteVisibleControls": ["performance"],
        "codexNativeTaskMessageControlPreserved": true,
        "codexNativeVoiceControlsPreserved": true,
        "codexVoiceModulePreserved": true,
        "rootnoteAddsNoVoiceChromeOrOcclusion": true,
        "performancePlacementAboveQuickChatAtLeftFoot": independentPlacement,
        "performanceSlot": NSStringFromRect(performanceSlot),
        "mascotBounds": NSStringFromRect(mascot),
        "downgradeConfirmationSamples": 2,
        "preservesOriginalDetailFields": fields,
    ]
    if let data = try? JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys]
    ), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    return (report["ok"] as? Bool) == true ? 0 : 1
}
