import AppKit
import ImageIO
import QuartzCore

enum PetAnimation: String, CaseIterable {
    case idle
    case look
    case waving
    case jumping
    case walkRight = "running-right"
    case walkLeft = "running-left"
    case work = "typing"
    case waiting
    case review
    case failed
    case fallAsleep = "fall-asleep"
    case sleep
    case wakeUp = "wake-up"

    /// Folder under Frames/. The sleep animations reuse the droopy "Oops" poses.
    var folder: String {
        switch self {
        case .fallAsleep, .sleep, .wakeUp: return PetAnimation.failed.rawValue
        default: return rawValue
        }
    }

    /// Fixed frame order for animations that use only part of their folder.
    var sequence: [Int]? {
        switch self {
        case .fallAsleep: return [2, 3, 4]   // eyes close, lie down, settle
        case .sleep: return [4]
        case .wakeUp: return [3, 5]          // lift head, sit up
        default: return nil
        }
    }

    var loops: Bool {
        switch self {
        case .waving, .jumping, .failed, .fallAsleep, .wakeUp: return false
        default: return true
        }
    }

    /// Number of times a one-shot plays before it finishes.
    var cycles: Int { self == .waving ? 2 : 1 }

    var isWalk: Bool { self == .walkLeft || self == .walkRight }

    /// Crossfade between consecutive frames. The frames are separate poses rather than
    /// true in-betweens, so dissolving between them is what makes motion read as smooth.
    var frameFade: TimeInterval {
        switch self {
        case .idle: return 0.35
        case .look: return 0.14
        case .waiting: return 0.3
        case .review: return 0.25
        case .work: return 0.2
        case .walkRight, .walkLeft: return 0.045
        case .waving, .failed: return 0.07
        case .jumping: return 0.05
        case .fallAsleep: return 0.45
        case .sleep: return 0.7
        case .wakeUp: return 0.22
        }
    }

    func hold() -> TimeInterval {
        switch self {
        case .idle, .look: return .random(in: 1.2...2.4)
        case .waiting: return .random(in: 0.7...1.3)
        case .review: return .random(in: 0.45...0.9)
        case .work: return .random(in: 0.9...1.8)
        case .walkRight, .walkLeft: return 0.09
        case .waving: return 0.16
        case .jumping: return 0.12
        case .failed: return 0.15
        case .fallAsleep: return 0.7
        case .sleep: return .random(in: 5...9)
        case .wakeUp: return 0.32
        }
    }
}

/// Renders Coco with two crossfading layers inside a body layer that carries
/// procedural motion (breathing, hops, squash and stretch, leaning), all driven by `tick`.
@MainActor
final class SpriteView: NSView {
    private struct Step {
        let frame: Int
        let hold: TimeInterval
        let fade: TimeInterval
    }

    private struct FloatingZ {
        let layer: CATextLayer
        var age: TimeInterval
        let drift: Double
    }

    static let frameSize = CGSize(width: 192, height: 208)
    private static let noActions: [String: CAAction] = [
        "contents": NSNull(), "opacity": NSNull(), "transform": NSNull(),
        "position": NSNull(), "bounds": NSNull(),
    ]

    private(set) var spriteRect: NSRect
    private(set) var scale: CGFloat
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var menuProvider: (() -> NSMenu)?

    /// Target lean in radians (negative tilts clockwise); springs toward it.
    var leanTarget: CGFloat = 0
    /// Stretches Coco slightly, as if picked up by the scruff.
    var lifted = false

    private(set) var animation: PetAnimation = .idle
    private var frames: [PetAnimation: [CGImage]] = [:]
    private let body = CALayer()
    private let front = CALayer()
    private let back = CALayer()

    private var frameIndex = 0
    private var sequencePosition = 0
    private var holdRemaining: TimeInterval = 0
    private var cyclesPlayed = 0
    private var completion: (() -> Void)?
    private var fadeProgress: Double = 1
    private var fadeDuration: TimeInterval = 0.2

    private var time: TimeInterval = 0
    private var hopY: CGFloat = 0
    private var hopVelocity: CGFloat = 0
    private var pendingLaunch: (delay: TimeInterval, velocity: CGFloat)?
    private var squash: CGFloat = 0
    private var squashVelocity: CGFloat = 0
    private var lean: CGFloat = 0
    private var leanVelocity: CGFloat = 0
    private let gravity: CGFloat = 2000
    private var breathPhase: Double = 0
    private var breathAmount: CGFloat = 0
    private var floatingZs: [FloatingZ] = []
    private var zCountdown: TimeInterval = 1

    init(frame frameRect: NSRect, spriteRect: NSRect, scale: CGFloat) {
        self.spriteRect = spriteRect
        self.scale = scale
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        loadFrames()
        setUpLayers()
        play(.idle, fade: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var hasFrames: Bool { !(frames[.idle]?.isEmpty ?? true) }

    func resize(spriteRect: NSRect, scale: CGFloat) {
        self.spriteRect = spriteRect
        self.scale = scale
        layoutBody()
    }

    // MARK: Playback

    func play(_ anim: PetAnimation, startFrame: Int = 0, fade: TimeInterval = 0.25, completion: (() -> Void)? = nil) {
        guard let list = frames[anim], !list.isEmpty else {
            completion?()
            return
        }
        self.completion = completion
        guard anim != animation || !anim.loops || fade == 0 else { return }

        animation = anim
        cyclesPlayed = 0
        sequencePosition = 0
        frameIndex = min(max(anim.sequence?.first ?? startFrame, 0), list.count - 1)
        holdRemaining = anim.hold()
        show(list[frameIndex], fade: fade)
    }

    /// Selects one of the look-around poses directly; used while Coco watches the cursor.
    func setLookFrame(_ index: Int) {
        guard animation == .look, index != frameIndex, let list = frames[.look], index < list.count else { return }
        frameIndex = index
        show(list[index], fade: PetAnimation.look.frameFade)
    }

    func jump(height: CGFloat) {
        guard hopY == 0, pendingLaunch == nil else { return }
        squashVelocity += 2.2
        pendingLaunch = (0.09, sqrt(2 * gravity * height))
    }

    func bump(_ amount: CGFloat) {
        squashVelocity += amount * 25
    }

    private func nextStep() -> Step? {
        let count = frames[animation]?.count ?? 0
        guard count > 0 else { return nil }

        switch animation {
        case .look:
            return nil
        case .sleep:
            // Shift slowly between the two lying-down poses.
            if frameIndex == 4 { return Step(frame: 3, hold: .random(in: 2...3), fade: animation.frameFade) }
            return Step(frame: 4, hold: animation.hold(), fade: animation.frameFade)
        case .work where count >= 5:
            // Mostly type with a focused face; now and then grin or give a little fist pump.
            if frameIndex == 2 || frameIndex == 4 { return Step(frame: [0, 1].randomElement()!, hold: animation.hold(), fade: animation.frameFade) }
            let roll = Double.random(in: 0..<1)
            if roll < 0.6 { return Step(frame: frameIndex == 0 ? 1 : 0, hold: animation.hold(), fade: animation.frameFade) }
            if roll < 0.8 { return Step(frame: 3, hold: .random(in: 0.6...1.0), fade: animation.frameFade) }
            if roll < 0.92 { return Step(frame: 2, hold: .random(in: 0.5...0.8), fade: animation.frameFade) }
            return Step(frame: 4, hold: .random(in: 0.5...0.8), fade: 0.15)
        case .idle where count >= 6:
            // Mostly hold the neutral pose; occasionally blink or tilt the head.
            if frameIndex == 2 { return Step(frame: 0, hold: .random(in: 1.4...2.8), fade: 0.06) }
            if frameIndex != 0 { return Step(frame: 0, hold: .random(in: 1.2...2.6), fade: 0.35) }
            let roll = Double.random(in: 0..<1)
            if roll < 0.45 { return Step(frame: 2, hold: 0.13, fade: 0.06) }
            if roll < 0.75 { return Step(frame: [1, 4].randomElement()!, hold: .random(in: 1.0...1.8), fade: 0.4) }
            return Step(frame: [3, 5].randomElement()!, hold: .random(in: 0.8...1.4), fade: 0.35)
        default:
            if let sequence = animation.sequence {
                sequencePosition += 1
                guard sequencePosition < sequence.count, sequence[sequencePosition] < count else { return nil }
                var hold = animation.hold()
                if sequencePosition == sequence.count - 1 { hold += 0.2 }
                return Step(frame: sequence[sequencePosition], hold: hold, fade: animation.frameFade)
            }
            var next = frameIndex + 1
            if next >= count {
                cyclesPlayed += 1
                if !animation.loops && cyclesPlayed >= animation.cycles { return nil }
                next = 0
            }
            var hold = animation.hold()
            if !animation.loops && next == count - 1 && cyclesPlayed == animation.cycles - 1 {
                hold += 0.35   // settle on the final pose before handing back
            }
            return Step(frame: next, hold: hold, fade: animation.frameFade)
        }
    }

    private func show(_ image: CGImage, fade: TimeInterval) {
        if fade <= 0 {
            back.contents = nil
            front.contents = image
            fadeProgress = 1
        } else {
            back.contents = front.contents
            front.contents = image
            fadeDuration = fade
            fadeProgress = 0
        }
        applyFade()
    }

    private func applyFade() {
        let t = fadeProgress * fadeProgress * (3 - 2 * fadeProgress)
        // Eased so the overlap never looks see-through mid-dissolve.
        front.opacity = Float(1 - (1 - t) * (1 - t))
        back.opacity = Float(1 - t * t)
    }

    // MARK: Frame loop

    func tick(_ dt: TimeInterval) {
        time += dt

        if animation != .look {
            holdRemaining -= dt
            while holdRemaining <= 0 {
                guard let step = nextStep(), let list = frames[animation] else {
                    holdRemaining = .infinity
                    let done = completion
                    completion = nil
                    done?()
                    break
                }
                frameIndex = step.frame
                holdRemaining += step.hold
                show(list[frameIndex], fade: step.fade)
            }
        }

        if fadeProgress < 1 {
            fadeProgress = min(1, fadeProgress + dt / fadeDuration)
            applyFade()
        }

        updatePhysics(dt)

        // Breathing eases between rates so switching animations never pops.
        let asleep = animation == .sleep || animation == .fallAsleep
        let breathTarget: CGFloat = animation.isWalk || animation == .jumping ? 0 : (asleep ? 0.025 : 0.012)
        breathAmount += (breathTarget - breathAmount) * CGFloat(min(1, dt * 2))
        breathPhase += dt * 2 * .pi / (asleep ? 4.4 : 3.4)
        let breath = CGFloat(sin(breathPhase)) * breathAmount
        let bob: CGFloat
        if animation.isWalk {
            bob = abs(CGFloat(sin(time * 2 * .pi / 0.36))) * 2.5 * scale
        } else if animation == .work {
            // A light, uneven tapping rhythm while typing on the laptop.
            bob = abs(CGFloat(sin(time * 2 * .pi / 0.26) * sin(time * 2 * .pi / 1.7))) * 0.9 * scale
        } else {
            bob = 0
        }
        let scaleY = 1 + breath - squash
        let scaleX = 1 - breath * 0.5 + squash * 0.7

        var transform = CATransform3DMakeTranslation(0, hopY + bob, 0)
        transform = CATransform3DRotate(transform, lean, 0, 0, 1)
        transform = CATransform3DScale(transform, scaleX, scaleY, 1)
        body.transform = transform

        updateFloatingZs(dt)
    }

    private func updateFloatingZs(_ dt: TimeInterval) {
        if animation == .sleep {
            zCountdown -= dt
            if zCountdown <= 0 {
                spawnZ()
                zCountdown = 1.4
            }
        } else {
            zCountdown = 1
        }

        let start = CGPoint(x: spriteRect.minX + spriteRect.width * 0.72, y: spriteRect.minY + spriteRect.height * 0.55)
        var alive: [FloatingZ] = []
        for var z in floatingZs {
            z.age += dt
            let t = z.age / 2.8
            guard t < 1 else {
                z.layer.removeFromSuperlayer()
                continue
            }
            let sway = CGFloat(sin(z.age * 2.4 + z.drift)) * 5 * scale
            z.layer.position = CGPoint(x: start.x + CGFloat(z.age) * 9 * scale + sway,
                                       y: start.y + CGFloat(z.age) * 20 * scale)
            z.layer.opacity = Float(t < 0.15 ? t / 0.15 : (1 - t) / 0.85)
            let grow = 0.6 + 0.7 * t
            z.layer.transform = CATransform3DMakeScale(grow, grow, 1)
            alive.append(z)
        }
        floatingZs = alive
    }

    private func spawnZ() {
        let z = CATextLayer()
        z.actions = Self.noActions
        z.string = "z"
        z.font = NSFont.systemFont(ofSize: 22, weight: .heavy)
        z.fontSize = 22 * scale
        z.foregroundColor = NSColor(calibratedRed: 0.78, green: 0.84, blue: 1, alpha: 1).cgColor
        z.alignmentMode = .center
        z.contentsScale = window?.backingScaleFactor ?? 2
        z.bounds = CGRect(x: 0, y: 0, width: 30 * scale, height: 30 * scale)
        z.shadowColor = NSColor.black.cgColor
        z.shadowOpacity = 0.8
        z.shadowRadius = 2
        z.shadowOffset = .zero
        z.opacity = 0
        layer?.addSublayer(z)
        floatingZs.append(FloatingZ(layer: z, age: 0, drift: .random(in: 0...(2 * .pi))))
    }

    private func updatePhysics(_ dt: TimeInterval) {
        let dt = CGFloat(dt)

        if let launch = pendingLaunch {
            let remaining = launch.delay - Double(dt)
            if remaining <= 0 {
                hopVelocity = launch.velocity
                squashVelocity -= 3.5   // stretch on take-off
                pendingLaunch = nil
            } else {
                pendingLaunch = (remaining, launch.velocity)
            }
        }

        if hopY > 0 || hopVelocity > 0 {
            hopVelocity -= gravity * dt
            hopY += hopVelocity * dt
            if hopY <= 0 {
                hopY = 0
                squashVelocity += min(4, -hopVelocity / 200)
                hopVelocity = 0
            }
        }

        let squashTarget: CGFloat = lifted ? -0.05 : 0
        squashVelocity += (-180 * (squash - squashTarget) - 14 * squashVelocity) * dt
        squash += squashVelocity * dt

        leanVelocity += (-120 * (lean - leanTarget) - 12 * leanVelocity) * dt
        lean += leanVelocity * dt
    }

    // MARK: Setup

    private func loadFrames() {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Frames", isDirectory: true) else { return }
        var byFolder: [String: [CGImage]] = [:]
        for anim in PetAnimation.allCases {
            if let cached = byFolder[anim.folder] {
                frames[anim] = cached
                continue
            }
            let folder = root.appendingPathComponent(anim.folder, isDirectory: true)
            var loaded: [CGImage] = []
            while true {
                let file = folder.appendingPathComponent(String(format: "%02d.png", loaded.count))
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { break }
                loaded.append(image)
            }
            byFolder[anim.folder] = loaded
            frames[anim] = loaded
        }
    }

    private func setUpLayers() {
        let noActions = Self.noActions
        body.actions = noActions
        body.anchorPoint = CGPoint(x: 0.5, y: 0)

        for sprite in [back, front] {
            sprite.actions = noActions
            sprite.contentsGravity = .resizeAspect
            sprite.magnificationFilter = .linear
            sprite.minificationFilter = .trilinear
            body.addSublayer(sprite)
        }
        layer?.addSublayer(body)
        layoutBody()
    }

    private func layoutBody() {
        body.bounds = CGRect(origin: .zero, size: spriteRect.size)
        body.position = CGPoint(x: spriteRect.midX, y: spriteRect.minY)
        for sprite in [back, front] { sprite.frame = body.bounds }
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return body.frame.insetBy(dx: 18 * scale, dy: 6 * scale).contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(NSEvent.mouseLocation) }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
