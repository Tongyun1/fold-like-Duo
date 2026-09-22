import AppKit
import Foundation

struct EffectParameters: Equatable {
    var triggerAngle: Double = 92
    var fullAngle: Double = 8
    var topNarrowing: Double = 0.30
    var blurRadius: Double = 88
    var blurFalloff: Double = 1.35
    var darkening: Double = 0.12
    var frost: Double = 0.10
    var reducedMotion = false

    func progress(for angle: Double) -> Double {
        guard angle.isFinite, triggerAngle > fullAngle else { return 0 }
        let linear = min(max((triggerAngle - angle) / (triggerAngle - fullAngle), 0), 1)
        return pow(linear, 1.08)
    }

    func topScale(for progress: Double) -> Double {
        1.0 / (1.0 + max(topNarrowing, 0) * min(max(progress, 0), 1))
    }
}

/// Arms only after real closing motion. Once armed, the effect remains mapped
/// to the current angle until the lid reopens past the trigger angle.
struct MotionGate {
    private(set) var waitingForClosing = true
    private var restAngle: Double?

    mutating func reset(at angle: Double? = nil) {
        waitingForClosing = true
        restAngle = angle
    }

    mutating func permits(angle: Double?, triggerAngle: Double, now _: Double) -> Bool {
        guard let angle, angle.isFinite, (0...180).contains(angle) else {
            reset()
            return false
        }
        if angle >= triggerAngle {
            reset(at: angle)
            return false
        }
        if waitingForClosing {
            guard let restAngle else {
                self.restAngle = angle
                return false
            }
            if angle >= restAngle {
                self.restAngle = angle
                return false
            }
            guard restAngle - angle >= 0.65 else { return false }
            waitingForClosing = false
            self.restAngle = nil
        }
        return true
    }
}

struct CriticallyDampedMotion {
    var value: Double = 0
    var velocity: Double = 0

    mutating func reset(to value: Double = 0) {
        self.value = value
        velocity = 0
    }

    mutating func step(target: Double, dt: Double, reducedMotion: Bool) -> Double {
        guard target.isFinite, dt.isFinite, dt > 0 else { return value }
        let time = min(dt, 0.05)
        let omega = reducedMotion ? 70.0 : 42.0
        let displacement = value - target
        let c = velocity + omega * displacement
        let decay = exp(-omega * time)
        value = target + (displacement + c * time) * decay
        velocity = (velocity - omega * c * time) * decay
        value = min(max(value, 0), 1)
        if abs(value - target) < 0.00002, abs(velocity) < 0.001 {
            value = target
            velocity = 0
        }
        return value
    }
}

/// Uses cumulative movement so slow closing still wakes the fast path, while
/// a stationary lid can keep its live effect with much less capture work.
struct LidActivity {
    static let movingFrameRate = 60
    static let restingFrameRate = 5
    private var referenceAngle: Double?
    private var lastMovementAt: Double?

    mutating func observe(_ angle: Double, now: Double) {
        if let referenceAngle, abs(angle - referenceAngle) < 0.25 { return }
        referenceAngle = angle
        lastMovementAt = now
    }

    func isMoving(at now: Double) -> Bool {
        lastMovementAt.map { now - $0 < 0.75 } ?? false
    }

    func captureFrameRate(at now: Double) -> Int {
        isMoving(at: now) ? Self.movingFrameRate : Self.restingFrameRate
    }
}

enum SelfCheck {
    static func run() throws {
        let parameters = EffectParameters()
        guard parameters.progress(for: 100) == 0 else { throw Failure("open angle must be clear") }
        guard parameters.progress(for: 8) == 1 else { throw Failure("full angle must reach one") }
        let midpoint = parameters.progress(for: 50)
        guard midpoint > 0, midpoint < 1 else { throw Failure("midpoint must be interpolated") }
        guard parameters.topScale(for: 0) == 1 else { throw Failure("idle geometry must be identity") }
        guard parameters.topScale(for: 1) < 1 else { throw Failure("folded top must narrow") }

        var gate = MotionGate()
        guard !gate.permits(angle: 80, triggerAngle: 92, now: 0) else { throw Failure("resting lid must not arm") }
        guard gate.permits(angle: 78.8, triggerAngle: 92, now: 0.02) else { throw Failure("closing motion must arm") }
        guard gate.permits(angle: 78.8, triggerAngle: 92, now: 30) else { throw Failure("holding must remain armed") }
        guard gate.permits(angle: 79.8, triggerAngle: 92, now: 31) else { throw Failure("opening below the trigger must unwind") }
        guard !gate.permits(angle: 92, triggerAngle: 92, now: 32) else { throw Failure("reopening past the trigger must clear") }

        var motion = CriticallyDampedMotion()
        for _ in 0..<30 { _ = motion.step(target: 1, dt: 1.0 / 60.0, reducedMotion: false) }
        guard motion.value > 0.98, motion.value <= 1 else { throw Failure("motion must converge") }

        var activity = LidActivity()
        activity.observe(60, now: 0)
        guard activity.captureFrameRate(at: 0) == 60 else { throw Failure("movement must use live capture") }
        for tick in 1...600 {
            let now = Double(tick) / 60
            activity.observe(60, now: now)
            if now >= 0.75 {
                guard activity.captureFrameRate(at: now) == 5 else {
                    throw Failure("holding the lid must not prolong full-rate capture")
                }
            }
        }
        activity.observe(60.1, now: 10.1)
        activity.observe(59.9, now: 10.2)
        guard !activity.isMoving(at: 10.2) else { throw Failure("small jitter must remain at rest") }
        activity.observe(59.8, now: 10.3)
        activity.observe(59.7, now: 10.4)
        guard activity.isMoving(at: 10.4) else { throw Failure("cumulative slow motion must resume fast capture") }
        activity.observe(61, now: 11.5)
        guard activity.isMoving(at: 11.5) else { throw Failure("opening must also resume fast capture") }
        guard !activity.isMoving(at: 12.3) else { throw Failure("capture must settle again after opening") }
        print("fold-like-Duo self-check passed")
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
