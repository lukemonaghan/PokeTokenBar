import AppKit
import SwiftUI

/// 데스크톱 위에 떠 있는 컴패니언 포켓몬 오버레이(옵트인, 설정 → 플로팅 펫).
/// - 드래그: 커스텀 `mouseDragged` (클릭과 충돌하지 않음).
/// - 클릭 → 팝오버, 우클릭 → 메뉴, 호버 → 오늘 사용량 콜아웃.
/// - Limit-alert speech bubbles grow the panel; persisted origin is the *pet*, not the panel.
/// - 에너지: 숨김·슬립 시 호스팅 트리 해제.
@MainActor
final class FloatingPetController: NSObject, NSWindowDelegate {
    private let store: UsageStore
    private let companion: CompanionStore
    private let defaults: UserDefaults
    /// One panel per floating mon, keyed by `MonState.id` — multiple can be up at once.
    private var panels: [String: NSPanel] = [:]
    private var builtAnimated: [String: Bool] = [:]
    private var hoverPanel: NSPanel?
    /// Which pet the hover callout is currently anchored to — lets `windowDidMove` reposition it
    /// only when the panel that actually moved is the one being hovered.
    private weak var hoveredPanel: NSPanel?
    private var displayAwake = true
    private var powerObserver: NSObjectProtocol?
    /// Edge-detects `store.floatingPetEnabled` going false→true, the only moment `sync()` seeds a
    /// default floating mon (the training one) if nothing is explicitly flagged yet — see sync().
    private var previousEnabled = false

    /// Squared movement (pt²) below which a mouse-up counts as a click, not a drag.
    static let clickThresholdSquared: CGFloat = 16  // ~4pt

    /// Vertical space above the sprite for the bubble + VStack spacing (pt).
    /// Sized for two wrapped body lines + title + padding + tail (ja strings).
    static let bubbleHeadroom: CGFloat = 72
    /// Minimum panel width while a bubble is showing.
    static let bubbleMinWidth: CGFloat = 180
    /// Horizontal padding inside the bubble chrome (each side). Content + 2× this = `bubbleMinWidth`.
    static let bubbleHorizontalPadding: CGFloat = 8
    /// Fixed text column — wraps instead of growing past the panel (`bubbleMinWidth` − 16).
    static let bubbleContentWidth: CGFloat = bubbleMinWidth - (bubbleHorizontalPadding * 2)
    /// `SpeechBubbleView` body `.lineLimit`. Measure and view must share this — a
    /// headroom-only guard stays green for 3-line copy that still fits 70pt (#167).
    static let bubbleBodyLineLimit = 2

    /// Chrome size plus the signals the view actually fails on: wrap count vs
    /// `bubbleBodyLineLimit`, and single-line width vs the content column.
    struct SpeechBubbleLayout: Equatable {
        var size: NSSize
        var bodyLineCount: Int
        var unclampedTitleWidth: CGFloat
        var unclampedBodyWidth: CGFloat
        var wouldTruncate: Bool
    }

    /// Same for every pet — opens the same popover regardless of which one was clicked.
    private var onOpenPopover: (() -> Void)?

    init(store: UsageStore, companion: CompanionStore, defaults: UserDefaults = .standard,
         onOpenPopover: (() -> Void)? = nil) {
        self.store = store
        self.companion = companion
        self.defaults = defaults
        self.onOpenPopover = onOpenPopover
        super.init()
        observeSettings()
        observePowerState()
        sync()
    }

    static func isClick(from start: NSPoint, to end: NSPoint,
                        thresholdSquared: CGFloat = clickThresholdSquared) -> Bool {
        let dx = end.x - start.x, dy = end.y - start.y
        return dx * dx + dy * dy < thresholdSquared
    }

    func setDisplayAwake(_ awake: Bool) {
        displayAwake = awake
        sync()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = store.floatingPetEnabled
            _ = store.floatingPetSize
            _ = store.currentBubbleAlert
            _ = store.todayTotalTokens
            _ = store.highestLimitUtilization
            _ = store.limitDisplayMode   // hover 툴팁 %가 파생되는 값 — 수동 관찰 표면은 파생 원천을 직접 추적(defect-log §표시·UI)
            _ = companion.language
            _ = companion.floatingMons   // 개별 플로팅 지정 변경(PC 상세 화면) 반영
            _ = companion.trainingMon?.id   // 기본값 로직(sync 참고)이 훈련 대상 변경도 봐야 한다
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sync()
                self.observeSettings()
            }
        }
    }

    private func observePowerState() {
        powerObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    static func shouldAnimate(lowPower: Bool) -> Bool { !lowPower }

    /// Panel size for a given pet size and bubble visibility. Pure — tested without AppKit layout.
    static func panelSize(petSize: CGFloat, showingBubble: Bool) -> NSSize {
        if showingBubble {
            return NSSize(width: max(petSize, bubbleMinWidth),
                          height: petSize + bubbleHeadroom)
        }
        return NSSize(width: petSize, height: petSize)
    }

    static func panelOrigin(petOrigin: NSPoint, petSize: CGFloat, panelSize: NSSize) -> NSPoint {
        let xInset = max(0, (panelSize.width - petSize) / 2)
        return NSPoint(x: petOrigin.x - xInset, y: petOrigin.y)
    }

    static func petOrigin(panelOrigin: NSPoint, petSize: CGFloat, panelSize: NSSize) -> NSPoint {
        let xInset = max(0, (panelSize.width - petSize) / 2)
        return NSPoint(x: panelOrigin.x + xInset, y: panelOrigin.y)
    }

    /// Measure speech-bubble chrome for a title/body at the fixed content width (wrapping).
    /// Pure AppKit typography — keeps the layout test free of SwiftUI hosting.
    static func measureSpeechBubble(title: String, body: String,
                                    contentWidth: CGFloat = bubbleContentWidth) -> NSSize {
        measureSpeechBubbleLayout(title: title, body: body, contentWidth: contentWidth).size
    }

    /// Layout the view draws: unconstrained chrome (`size`) plus wrap count and
    /// single-line widths. `size.width` is clamped to the column (cannot fail a
    /// `≤ panel.width` assert); `unclamped*Width` is the check that can.
    static func measureSpeechBubbleLayout(title: String, body: String,
                                          contentWidth: CGFloat = bubbleContentWidth) -> SpeechBubbleLayout {
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let bodyFont = NSFont.systemFont(ofSize: 10)
        let wrap = NSSize(width: contentWidth, height: 10_000)
        let unclamped = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 10_000)
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let titleRect = (title as NSString).boundingRect(
            with: wrap, options: opts, attributes: [.font: titleFont])
        let bodyRect = (body as NSString).boundingRect(
            with: wrap, options: opts, attributes: [.font: bodyFont])
        let unclampedTitle = (title as NSString).boundingRect(
            with: unclamped, options: opts, attributes: [.font: titleFont])
        let unclampedBody = (body as NSString).boundingRect(
            with: unclamped, options: opts, attributes: [.font: bodyFont])
        let textWidth = min(contentWidth, max(titleRect.width, bodyRect.width))
        let textHeight = ceil(titleRect.height) + 2 + ceil(bodyRect.height)
        // Match SpeechBubbleView: horizontal padding ×2, vertical 6, bottom pad 6 for the tail.
        let hPad = bubbleHorizontalPadding * 2
        let bodyLineCount = wrappedLineCount(body, font: bodyFont, width: contentWidth)
        return SpeechBubbleLayout(
            size: NSSize(width: textWidth + hPad, height: textHeight + 12 + 6),
            bodyLineCount: bodyLineCount,
            unclampedTitleWidth: unclampedTitle.width,
            unclampedBodyWidth: unclampedBody.width,
            wouldTruncate: bodyLineCount > bubbleBodyLineLimit)
    }

    /// Wrap count at `width` using the same `boundingRect` path as `size`, so a
    /// height-jump fixture and `bodyLineCount` cannot disagree.
    private static func wrappedLineCount(_ string: String, font: NSFont, width: CGFloat) -> Int {
        guard !string.isEmpty else { return 0 }
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let wrapped = (string as NSString).boundingRect(
            with: NSSize(width: width, height: 10_000), options: opts, attributes: [.font: font])
        let single = ("Ay" as NSString).boundingRect(
            with: NSSize(width: 10_000, height: 10_000), options: opts, attributes: [.font: font])
        let unit = max(single.height, 1)
        return max(1, Int((wrapped.height / unit).rounded()))
    }

    private func sync() {
        let enabled = store.floatingPetEnabled
        defer { previousEnabled = enabled }
        guard enabled, displayAwake else { hideAll(); return }
        // Only at the moment the master toggle flips on, and only if nothing is explicitly flagged
        // yet, seed the training mon as the default floating pet. After that this never re-fires —
        // explicitly removing every floating pet must leave zero shown, not bounce back.
        if !previousEnabled, companion.floatingMons.isEmpty, let training = companion.trainingMon {
            companion.setFloating(true, for: training.id)
        }
        let targets = companion.floatingMons
        let targetIDs = Set(targets.map(\.id))
        for id in panels.keys where !targetIDs.contains(id) { removePanel(for: id) }
        for (index, mon) in targets.enumerated() { show(mon: mon, index: index) }
    }

    private func show(mon: MonState, index: Int) {
        let p = panels[mon.id] ?? makePanel()
        panels[mon.id] = p
        let wantAnimated = Self.shouldAnimate(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if p.contentView == nil || builtAnimated[mon.id] != wantAnimated {
            let hosting = PetHostingView(rootView: AnyView(
                FloatingPetView(monID: mon.id, animated: wantAnimated).environment(store).environment(companion)))
            hosting.onOpenPopover = onOpenPopover
            hosting.onHide = { [weak self] in self?.companion.setFloating(false, for: mon.id) }
            hosting.languageProvider = { [weak self] in self?.companion.language ?? .systemDefault }
            hosting.onHoverChange = { [weak self] hovering in
                if hovering { self?.showHoverCallout(for: p) } else { self?.hideHoverCallout() }
            }
            p.contentView = hosting
            builtAnimated[mon.id] = wantAnimated
        }
        if let hosting = p.contentView as? PetHostingView {
            hosting.toolTip = currentHoverText()
        }
        let petSize = CGFloat(store.floatingPetSize)
        p.setFrame(targetFrame(monID: mon.id, index: index, petSize: petSize,
                               showingBubble: store.currentBubbleAlert != nil), display: true)
        p.orderFrontRegardless()
        if hoveredPanel === p { showHoverCallout(for: p) }
    }

    private func hideAll() {
        hideHoverCallout()
        for p in panels.values { p.orderOut(nil); p.contentView = nil }
        panels.removeAll()
        builtAnimated.removeAll()
    }

    private func removePanel(for monID: String) {
        guard let p = panels.removeValue(forKey: monID) else { return }
        if hoveredPanel === p { hideHoverCallout() }
        p.orderOut(nil)
        p.contentView = nil
        builtAnimated.removeValue(forKey: monID)
    }

    private func currentHoverText() -> String {
        FloatingPetView.hoverTooltip(
            todayTokens: store.todayTotalTokens,
            limitUtilization: store.highestLimitUtilization,
            mode: store.limitDisplayMode,
            l: L(companion.language))
    }

    private func showHoverCallout(for pet: NSPanel) {
        guard pet.isVisible else { return }
        // Don't cover an active limit bubble — the speech bubble is the priority surface.
        if store.currentBubbleAlert != nil { hideHoverCallout(); return }
        let text = currentHoverText()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.sizeToFit()

        let pad: CGFloat = 8
        let size = NSSize(width: label.bounds.width + pad * 2,
                          height: label.bounds.height + pad * 2)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        label.frame.origin = NSPoint(x: pad, y: pad)
        container.addSubview(label)

        let hp = hoverPanel ?? makeHoverPanel()
        hoverPanel = hp
        hp.contentView = container
        hp.setContentSize(size)
        let petFrame = pet.frame
        hp.setFrameOrigin(NSPoint(x: petFrame.midX - size.width / 2, y: petFrame.maxY + 6))
        hp.orderFrontRegardless()
        hoveredPanel = pet
    }

    private func hideHoverCallout() {
        hoverPanel?.orderOut(nil)
        hoverPanel?.contentView = nil
        hoveredPanel = nil
    }

    private func makeHoverPanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        return p
    }

    private static func originKey(_ monID: String, _ axis: String) -> String {
        "floatingPetOrigin\(axis)_\(monID)"
    }

    private func targetFrame(monID: String, index: Int, petSize: CGFloat, showingBubble: Bool) -> NSRect {
        let size = Self.panelSize(petSize: petSize, showingBubble: showingBubble)
        let petOrigin: NSPoint
        if let x = defaults.object(forKey: Self.originKey(monID, "X")) as? Double,
           let y = defaults.object(forKey: Self.originKey(monID, "Y")) as? Double {
            petOrigin = NSPoint(x: x, y: y)
        } else {
            petOrigin = Self.defaultPetOrigin(petSize: petSize, index: index)
        }
        var frame = NSRect(origin: Self.panelOrigin(petOrigin: petOrigin, petSize: petSize, panelSize: size),
                           size: size)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            let fallbackPet = Self.defaultPetOrigin(petSize: petSize, index: index)
            frame.origin = Self.panelOrigin(petOrigin: fallbackPet, petSize: petSize, panelSize: size)
        }
        return frame
    }

    /// First-time (no saved drag position yet) placement — lines pets up along the bottom-right so
    /// several at once don't stack on top of each other. Each one keeps its own dragged position
    /// afterward regardless of how `index` shifts as others are added/removed.
    private static func defaultPetOrigin(petSize: CGFloat, index: Int) -> NSPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return NSPoint(x: 120, y: 120) }
        let stride = petSize + 16
        return NSPoint(x: visible.maxX - petSize - 24 - CGFloat(index) * stride, y: visible.minY + 24)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.allowsToolTipsWhenApplicationIsInactive = true
        p.animationBehavior = .none
        p.delegate = self
        return p
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSPanel, window.isVisible,
              let monID = panels.first(where: { $0.value === window })?.key else { return }
        let petSize = CGFloat(store.floatingPetSize)
        let size = Self.panelSize(petSize: petSize, showingBubble: store.currentBubbleAlert != nil)
        let pet = Self.petOrigin(panelOrigin: window.frame.origin, petSize: petSize, panelSize: size)
        defaults.set(Double(pet.x), forKey: Self.originKey(monID, "X"))
        defaults.set(Double(pet.y), forKey: Self.originKey(monID, "Y"))
        if hoveredPanel === window { showHoverCallout(for: window) }
    }
}

final class PetHostingView: NSHostingView<AnyView> {
    var onOpenPopover: (() -> Void)?
    var onHide: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var languageProvider: () -> AppLanguage = { .systemDefault }

    private var mouseDownScreen: NSPoint?
    private var originAtDown: NSPoint?
    private var didDrag = false

    override var mouseDownCanMoveWindow: Bool { false }

    static func isClick(from start: NSPoint, to end: NSPoint,
                        thresholdSquared: CGFloat = FloatingPetController.clickThresholdSquared) -> Bool {
        FloatingPetController.isClick(from: start, to: end, thresholdSquared: thresholdSquared)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(event)
            return
        }
        mouseDownScreen = NSEvent.mouseLocation
        originAtDown = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = mouseDownScreen, let origin = originAtDown else { return }
        let now = NSEvent.mouseLocation
        if !Self.isClick(from: start, to: now) { didDrag = true }
        window.setFrameOrigin(NSPoint(x: origin.x + (now.x - start.x),
                                      y: origin.y + (now.y - start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownScreen = nil
            originAtDown = nil
            didDrag = false
        }
        guard !didDrag, let start = mouseDownScreen else { return }
        if Self.isClick(from: start, to: NSEvent.mouseLocation) {
            onOpenPopover?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(event)
    }

    private func showContextMenu(_ event: NSEvent) {
        onHoverChange?(false)
        NSApp.activate(ignoringOtherApps: true)
        let l = L(languageProvider())
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        let open = menu.addItem(withTitle: l.floatingPetMenuOpen,
                                action: #selector(handleOpen(_:)), keyEquivalent: "")
        open.target = self
        open.isEnabled = true
        let hide = menu.addItem(withTitle: l.floatingPetMenuHide,
                                action: #selector(handleHide(_:)), keyEquivalent: "")
        hide.target = self
        hide.isEnabled = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func handleOpen(_ sender: Any?) { onOpenPopover?() }
    @objc func handleHide(_ sender: Any?) { onHide?() }
}

struct FloatingPetView: View {
    static let frameFloor: TimeInterval = 0.4
    /// Which party member this window shows — looked up live from `companion` each render (via
    /// environment, like the rest of this file) so it stays current if that mon evolves.
    let monID: MonState.ID
    var animated: Bool = true
    @Environment(UsageStore.self) private var store
    @Environment(CompanionStore.self) private var companion

    private var mon: MonState? { companion.party.first { $0.id == monID } }

    var body: some View {
        let size = CGFloat(store.floatingPetSize)
        VStack(spacing: 8) {
            if let alert = store.currentBubbleAlert {
                SpeechBubbleView(alert: alert, l: L(companion.language))
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }

            SpriteView(speciesID: mon?.currentID, size: size, animated: animated,
                       shiny: mon?.isShiny ?? false, minFrameDelay: Self.frameFloor)
                .frame(width: size, height: size)
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(animated ? .spring(response: 0.3, dampingFraction: 0.7) : nil,
                   value: store.currentBubbleAlert)
    }

    static func hoverTooltip(todayTokens: Int, limitUtilization: Double?,
                             mode: UsageStore.LimitDisplayMode, l: L) -> String {
        let usage = TokenFormatter.grouped(todayTokens)
        if let pct = limitUtilization {
            let text = TokenFormatter.percent(UsageStore.displayPercent(pct, mode: mode))
            return l.floatingPetHoverWithLimit(usage, mode == .remaining ? l.percentRemaining(text) : text)
        }
        return l.floatingPetHoverTokensOnly(usage)
    }
}

/// Transient limit-alert bubble. Width is capped so copy wraps instead of clipping the panel.
private struct SpeechBubbleView: View {
    let alert: UsageStore.LimitAlert
    let l: L

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(alert.isCritical ? l.notifCritical : l.notifWarning)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(alert.isCritical ? .red : .primary)
            Text(l.notifBody(alert.window, TokenFormatter.percent(alert.utilization)))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(FloatingPetController.bubbleBodyLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: FloatingPetController.bubbleContentWidth, alignment: .leading)
        .padding(.horizontal, FloatingPetController.bubbleHorizontalPadding)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        )
        .overlay(
            Path { path in
                path.move(to: CGPoint(x: 10, y: 0))
                path.addLine(to: CGPoint(x: 20, y: 0))
                path.addLine(to: CGPoint(x: 15, y: 6))
                path.closeSubpath()
            }
            .fill(Color(nsColor: .windowBackgroundColor))
            .offset(y: 5),
            alignment: .bottom
        )
        .padding(.bottom, 6)
    }
}
