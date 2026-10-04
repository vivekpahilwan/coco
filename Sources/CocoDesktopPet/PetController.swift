import AppKit
import QuartzCore

/// A floating panel that never takes focus, so clicking Coco doesn't steal keystrokes
/// from whatever you're typing in.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Decides what Coco does: mirrors your activity (typing → working, a pause after a
/// long burst → thinking, moving the mouse → watching the cursor, away → waiting),
/// and handles clicks, drags and wandering.
@MainActor
final class PetController: NSObject {
    private enum Defaults {
        static let followsActivity = "followsActivity"
        static let origin = "petOrigin"
        static let scale = "petScale"
    }

    /// Look-around poses indexed by 22.5° sector, clockwise from straight up.
    /// The source art has no up-left poses, so that sector reuses "left" and "up".
    private static let lookFrames = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 12, 0, 0]

    /// Sizes are relative to the artwork's original on-screen size.
    private static let scaleRange: ClosedRange<CGFloat> = 0.5...1.5
    private static let sizePresets: [(String, CGFloat)] = [
        ("Small", 0.6), ("Medium", 0.8), ("Large", 1.0), ("Extra Large", 1.2),
    ]

    /// Side margins and headroom leave space for leaning and hopping; the transparent
    /// area around Coco is click-through.
    private static func layout(for scale: CGFloat) -> (spriteRect: NSRect, size: NSSize) {
        let spriteRect = NSRect(x: 50 * scale, y: 4, width: 232 * scale, height: 252 * scale)
        return (spriteRect, NSSize(width: spriteRect.maxX + 50 * scale, height: spriteRect.maxY + 80 * scale))
    }

    let panel: PetPanel
    let sprite: SpriteView

    private(set) var followsActivity: Bool {
        didSet { UserDefaults.standard.set(followsActivity, forKey: Defaults.followsActivity) }
    }

    private(set) var scale: CGFloat
    private var scrollScaleDelta: CGFloat = 0
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var pollElapsed: TimeInterval = 0

    private var baseAnimation: PetAnimation = .idle
    private var baseChangedAt: TimeInterval = 0
    private var oneShotActive = false

    private var lastMouse = NSEvent.mouseLocation
    private var lastMouseMove: TimeInterval = -.infinity
    private var lastUserActive = CACurrentMediaTime()
    private var typingSince: TimeInterval?
    private var thinkUntil: TimeInterval = 0
    private var wasHovering = false
    private var lastHoverWave: TimeInterval = -.infinity
    private var lookSector = 0

    private var walkTarget: CGFloat?
    private var walkStartedAt: TimeInterval = 0
    private var nextWanderAt = CACurrentMediaTime() + 20

    private var mouseIsDown = false
    private var isDragging = false
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var lastDragPoint = NSPoint.zero
    private var lastDragTime: TimeInterval = 0
    private var dragVelocity: CGFloat = 0

    override init() {
        UserDefaults.standard.register(defaults: [Defaults.followsActivity: true, Defaults.scale: 0.8])
        followsActivity = UserDefaults.standard.bool(forKey: Defaults.followsActivity)
        let savedScale = CGFloat(UserDefaults.standard.double(forKey: Defaults.scale))
        scale = min(max(savedScale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let (spriteRect, size) = Self.layout(for: scale)

        panel = PetPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        sprite = SpriteView(frame: NSRect(origin: .zero, size: size), spriteRect: spriteRect, scale: scale)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.contentView = sprite
        panel.setFrameOrigin(initialOrigin())
        wasHovering = spriteScreenRect.contains(NSEvent.mouseLocation)

        sprite.menuProvider = { [unowned self] in self.makeMenu(includeQuit: true) }
        sprite.onMouseDown = { [unowned self] in self.mouseDown(at: $0) }
        sprite.onMouseDragged = { [unowned self] in self.mouseDragged(to: $0) }
        sprite.onMouseUp = { [unowned self] _ in self.mouseUp() }
        sprite.onScroll = { [unowned self] in self.scrolled($0) }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes keep Coco moving while a menu is open or the window is dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observeScreenLock()
    }

    /// Stops the frame loop entirely while the screen is locked or the display is asleep.
    private func observeScreenLock() {
        let pause: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.timer?.fireDate = .distantFuture }
        }
        let resume: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastTick = CACurrentMediaTime()
                self?.timer?.fireDate = Date()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: pause)
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: resume)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: pause)
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: resume)
    }

    // MARK: Showing

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    // MARK: Frame loop

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)   // a stall shouldn't teleport anything
        lastTick = now
        guard panel.isVisible else { return }

        pollElapsed += dt
        if pollElapsed >= 0.12 {
            pollElapsed = 0
            poll(now)
        }

        if isDragging && now - lastDragTime > 0.05 {
            dragVelocity *= 0.85
            sprite.leanTarget = lean(for: dragVelocity)
        }
        updateWalk(dt, now)
        if sprite.animation == .look { updateLook() }
        sprite.tick(dt)
    }

    private func poll(_ now: TimeInterval) {
        let keyIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mouse = NSEvent.mouseLocation
        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 1.5 { lastMouseMove = now }
        lastMouse = mouse
        let mouseIdle = now - lastMouseMove
        // Any input at all (clicks, scrolling, keys) counts as you being here.
        let anyIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let userIdle = min(anyIdle, mouseIdle)
        let asleep = baseAnimation == .sleep

        if userIdle < 0.5 {
            if now - lastUserActive > 90 && panel.isVisible && !isBusy && !asleep {
                playOneShot(.waving)   // welcome back
            }
            lastUserActive = now
        }

        let hovering = spriteScreenRect.contains(mouse)
        if hovering && !wasHovering && !mouseIsDown && !isBusy && !asleep && now - lastHoverWave > 15 {
            lastHoverWave = now
            playOneShot(.waving)
        }
        wasHovering = hovering

        if keyIdle < 1.5 {
            if typingSince == nil { typingSince = now - keyIdle }
        } else if let start = typingSince {
            // After a solid stretch of typing, look thoughtful for a moment.
            if now - start > 3 { thinkUntil = now + 3.5 }
            typingSince = nil
        }

        guard followsActivity, !isBusy else { return }

        let desired: PetAnimation
        if keyIdle < 1.5 {
            desired = .work
        } else if now < thinkUntil {
            desired = .review
        } else if mouseIdle < 2.5 {
            desired = .look
        } else if userIdle > 30 {
            desired = .sleep
        } else if userIdle > 15 {
            desired = .waiting
        } else {
            desired = .idle
        }
        setBase(desired, now)

        if (desired == .idle || desired == .waiting) && userIdle > 8 && now > nextWanderAt {
            wander()
        }
    }

    private var isBusy: Bool { oneShotActive || isDragging || walkTarget != nil }

    private func setBase(_ desired: PetAnimation, _ now: TimeInterval) {
        guard desired != baseAnimation else { return }
        if baseAnimation == .sleep {
            wakeUp(to: desired)
            return
        }
        // A short dwell keeps Coco from flickering between moods; typing always wins.
        if desired != .work && now - baseChangedAt < 0.9 { return }
        baseAnimation = desired
        baseChangedAt = now
        playBase()
    }

    private func playBase() {
        if baseAnimation == .look {
            lookSector = sector(forAngle: cursorAngle() ?? 0)
            sprite.play(.look, startFrame: Self.lookFrames[lookSector])
            sprite.bump(0.06)   // settle as Coco sits down
        } else if baseAnimation == .sleep {
            sprite.play(.fallAsleep, fade: 0.4) { [weak self] in
                guard let self, self.baseAnimation == .sleep else { return }
                self.sprite.play(.sleep, fade: PetAnimation.sleep.frameFade)
            }
        } else {
            sprite.play(baseAnimation)
        }
    }

    private func wakeUp(to next: PetAnimation) {
        baseAnimation = next
        baseChangedAt = CACurrentMediaTime()
        playOneShot(.wakeUp)
    }

    private func playOneShot(_ anim: PetAnimation) {
        guard !isDragging else { return }
        walkTarget = nil
        if followsActivity && baseAnimation == .sleep && anim != .wakeUp {
            baseAnimation = .idle   // interacting with Coco wakes it up
        }
        oneShotActive = true
        sprite.play(anim, fade: 0.18) { [weak self] in
            guard let self else { return }
            self.oneShotActive = false
            self.baseChangedAt = CACurrentMediaTime()
            self.playBase()
        }
        if anim == .jumping { sprite.jump(height: 46 * scale) }
    }

    // MARK: Looking at the cursor

    private var headPoint: NSPoint {
        let frame = panel.frame
        let rect = sprite.spriteRect
        return NSPoint(x: frame.minX + rect.midX, y: frame.minY + rect.minY + rect.height * 0.55)
    }

    private var spriteScreenRect: NSRect {
        sprite.spriteRect.insetBy(dx: 30 * scale, dy: 10 * scale).offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// Degrees clockwise from straight up, or nil when the cursor is right on Coco's head.
    private func cursorAngle() -> Double? {
        let mouse = NSEvent.mouseLocation
        let head = headPoint
        let dx = Double(mouse.x - head.x)
        let dy = Double(mouse.y - head.y)
        guard hypot(dx, dy) > 30 else { return nil }
        let degrees = atan2(dx, dy) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    private func sector(forAngle angle: Double) -> Int {
        Int((angle + 11.25) / 22.5) % 16
    }

    private func updateLook() {
        guard let angle = cursorAngle() else { return }
        let candidate = sector(forAngle: angle)
        guard candidate != lookSector else { return }
        // Hysteresis: only turn once the cursor is clearly past the sector boundary.
        let center = Double(lookSector) * 22.5
        var distance = abs(angle - center)
        if distance > 180 { distance = 360 - distance }
        guard distance > 11.25 + 5 else { return }
        lookSector = candidate
        sprite.setLookFrame(Self.lookFrames[lookSector])
    }

    // MARK: Walking

    private func wander() {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let rect = sprite.spriteRect
        let minX = visible.minX - rect.minX + 4
        let maxX = visible.maxX - rect.maxX - 4
        guard maxX > minX else { return }

        let x = panel.frame.minX
        let distance = CGFloat.random(in: 120...320) * (Bool.random() ? 1 : -1)
        var target = min(max(x + distance, minX), maxX)
        if abs(target - x) < 60 { target = min(max(x - distance, minX), maxX) }
        nextWanderAt = CACurrentMediaTime() + .random(in: 25...70)
        guard abs(target - x) >= 60 else { return }

        oneShotActive = false
        walkTarget = target
        walkStartedAt = CACurrentMediaTime()
        sprite.play(target > x ? .walkRight : .walkLeft, fade: 0.15)
    }

    private func updateWalk(_ dt: TimeInterval, _ now: TimeInterval) {
        guard let target = walkTarget else { return }
        var origin = panel.frame.origin
        let remaining = target - origin.x
        // Ease in over the first few steps and ease out on arrival.
        let easeIn = min(1, CGFloat(now - walkStartedAt) / 0.35)
        let easeOut = min(1, abs(remaining) / 50)
        let speed = max(18, 85 * easeIn * easeOut) * scale
        let step = min(abs(remaining), speed * CGFloat(dt))
        origin.x += remaining > 0 ? step : -step
        panel.setFrameOrigin(origin)

        if abs(remaining) - step < 0.5 {
            walkTarget = nil
            baseChangedAt = now
            saveOrigin()
            playBase()
        }
    }

    // MARK: Dragging and clicking

    private func mouseDown(at point: NSPoint) {
        mouseIsDown = true
        isDragging = false
        dragStartMouse = point
        dragStartOrigin = panel.frame.origin
        lastDragPoint = point
        lastDragTime = CACurrentMediaTime()
        dragVelocity = 0
    }

    private func mouseDragged(to point: NSPoint) {
        guard mouseIsDown else { return }
        let now = CACurrentMediaTime()
        if !isDragging {
            guard hypot(point.x - dragStartMouse.x, point.y - dragStartMouse.y) > 3 else { return }
            isDragging = true
            walkTarget = nil
            sprite.lifted = true
        }

        panel.setFrameOrigin(NSPoint(
            x: dragStartOrigin.x + point.x - dragStartMouse.x,
            y: dragStartOrigin.y + point.y - dragStartMouse.y
        ))
        let dt = max(now - lastDragTime, 1.0 / 120.0)
        dragVelocity = dragVelocity * 0.7 + (point.x - lastDragPoint.x) / CGFloat(dt) * 0.3
        sprite.leanTarget = lean(for: dragVelocity)
        lastDragPoint = point
        lastDragTime = now
    }

    private func mouseUp() {
        guard mouseIsDown else { return }
        mouseIsDown = false
        if isDragging {
            isDragging = false
            sprite.lifted = false
            sprite.leanTarget = 0
            sprite.bump(0.12)   // plop down
            keepOnScreen()
            saveOrigin()
            nextWanderAt = CACurrentMediaTime() + 20
            if oneShotActive == false { playBase() }
        } else if baseAnimation == .sleep && followsActivity {
            wakeUp(to: .idle)
        } else {
            playOneShot(.jumping)
        }
    }

    private func lean(for velocity: CGFloat) -> CGFloat {
        min(max(-velocity * 0.00035, -0.18), 0.18)
    }

    private func keepOnScreen() {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let rect = sprite.spriteRect
        var origin = panel.frame.origin
        origin.x = min(max(origin.x, visible.minX - rect.minX), visible.maxX - rect.maxX)
        origin.y = min(max(origin.y, visible.minY - rect.minY), visible.maxY - rect.maxY)
        panel.setFrameOrigin(origin)
    }

    // MARK: Size

    func setScale(_ newScale: CGFloat) {
        let clamped = min(max((newScale * 100).rounded() / 100, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        guard clamped != scale else { return }

        // Grow or shrink around Coco's feet so it stays where it's standing.
        let oldRect = sprite.spriteRect
        let feet = NSPoint(x: panel.frame.minX + oldRect.midX, y: panel.frame.minY + oldRect.minY)
        let (spriteRect, size) = Self.layout(for: clamped)
        scale = clamped
        walkTarget = nil

        panel.setFrame(NSRect(x: feet.x - spriteRect.midX, y: feet.y - spriteRect.minY,
                              width: size.width, height: size.height), display: false)
        sprite.frame = NSRect(origin: .zero, size: size)
        sprite.resize(spriteRect: spriteRect, scale: clamped)
        keepOnScreen()
        saveOrigin()
        UserDefaults.standard.set(Double(clamped), forKey: Defaults.scale)
    }

    /// Hold Option and scroll over Coco to resize it.
    private func scrolled(_ event: NSEvent) {
        guard event.modifierFlags.contains(.option) else { return }
        scrollScaleDelta += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.002 : 0.02)
        guard abs(scrollScaleDelta) >= 0.01 else { return }
        setScale(scale + scrollScaleDelta)
        scrollScaleDelta = 0
    }

    @objc func makeLarger() { setScale(((scale + 0.1) * 10).rounded() / 10) }
    @objc func makeSmaller() { setScale(((scale - 0.1) * 10).rounded() / 10) }

    @objc private func choosePresetSize(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? Double else { return }
        setScale(CGFloat(preset))
    }

    // MARK: Position

    private func initialOrigin() -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: Defaults.origin) {
            let origin = NSPointFromString(saved)
            let frame = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return origin }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = sprite.spriteRect
        return NSPoint(x: visible.maxX - rect.maxX - 22, y: visible.minY + 8 - rect.minY)
    }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Defaults.origin)
    }

    // MARK: Menu

    func makeMenu(includeQuit: Bool) -> NSMenu {
        let menu = NSMenu()
        let follow = item("Follow My Activity", #selector(toggleFollow))
        follow.state = followsActivity ? .on : .off
        menu.addItem(follow)
        menu.addItem(.separator())
        menu.addItem(item("Wave", #selector(playWave)))
        menu.addItem(item("Jump", #selector(playJump)))
        menu.addItem(item("Oops", #selector(playFailed)))
        menu.addItem(item("Go for a Walk", #selector(playWalk)))
        menu.addItem(.separator())

        let hold = NSMenuItem(title: "Stay…", action: nil, keyEquivalent: "")
        let holdMenu = NSMenu()
        for (title, anim) in [("Idle", PetAnimation.idle), ("Working", .work), ("Waiting", .waiting), ("Thinking", .review), ("Sleeping", .sleep)] {
            let entry = item(title, #selector(holdAnimation(_:)))
            entry.representedObject = anim.rawValue
            entry.state = !followsActivity && baseAnimation == anim ? .on : .off
            holdMenu.addItem(entry)
        }
        hold.submenu = holdMenu
        menu.addItem(hold)

        let size = NSMenuItem(title: "Size (\(Int((scale * 100).rounded()))%)", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        let larger = item("Larger", #selector(makeLarger))
        larger.isEnabled = scale < Self.scaleRange.upperBound
        let smaller = item("Smaller", #selector(makeSmaller))
        smaller.isEnabled = scale > Self.scaleRange.lowerBound
        sizeMenu.addItem(larger)
        sizeMenu.addItem(smaller)
        sizeMenu.addItem(.separator())
        for (title, preset) in Self.sizePresets {
            let entry = item("\(title) (\(Int(preset * 100))%)", #selector(choosePresetSize(_:)))
            entry.representedObject = Double(preset)
            entry.state = abs(scale - preset) < 0.001 ? .on : .off
            sizeMenu.addItem(entry)
        }
        sizeMenu.addItem(.separator())
        let tip = NSMenuItem(title: "Tip: hold ⌥ and scroll over Coco", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        sizeMenu.addItem(tip)
        size.submenu = sizeMenu
        menu.addItem(size)
        menu.addItem(.separator())
        menu.addItem(item(panel.isVisible ? "Hide Coco" : "Show Coco", #selector(toggleVisible)))
        if includeQuit {
            menu.addItem(item("Quit Coco", #selector(quit)))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func toggleFollow() {
        followsActivity.toggle()
        if followsActivity { baseChangedAt = 0 }
    }

    @objc private func playWave() { playOneShot(.waving) }
    @objc private func playJump() { playOneShot(.jumping) }
    @objc private func playFailed() { playOneShot(.failed) }

    @objc private func playWalk() {
        nextWanderAt = 0
        wander()
    }

    @objc private func holdAnimation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let anim = PetAnimation(rawValue: raw) else { return }
        followsActivity = false
        walkTarget = nil
        oneShotActive = false
        baseAnimation = anim
        playBase()
    }

    @objc func toggleVisible() { panel.isVisible ? hide() : show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
