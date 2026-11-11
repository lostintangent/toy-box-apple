import ChannelKit
import Foundation

/// One viewer's pointer in control, which turns mouse and touch events into the host's pointer
/// input, as the browser pane does. A viewer starts a fresh one whenever it takes control, and sends
/// what each event returns.
///
/// A mouse presses at once. A touch waits for lift, 10 points of movement or 150 ms before it presses,
/// so a tap clicks where it lifts and a drag presses where it began. A second finger before then makes
/// the gesture local, a pinch or pan of the viewer, until every finger lifts. Positions are fractions
/// of the frame, nil off it, and anything off the frame sends nothing.
public struct ScreenPointer: Sendable {
    /// What the pointer is doing. A viewer lets its own pinch and pan begin unless it's pressing.
    public enum Phase: Equatable, Sendable { case idle, waiting, pressing, local }

    private enum Gesture: Sendable {
        case idle
        case waiting(Touch)
        case pressing(Screen.Input.Button, touch: ObjectIdentifier?)
        case local(Set<ObjectIdentifier>)
    }

    /// A touch that hasn't shown yet whether it presses the host or pinches the viewer.
    private struct Touch: Sendable {
        var id: ObjectIdentifier
        var point: CGPoint
        var position: CGPoint?
        var deadline: ContinuousClock.Instant
    }

    /// How far a waiting touch moves to drag, in points.
    static let dragDistance = 10.0
    /// How long a still, waiting touch holds before it presses.
    static let hold = Duration.milliseconds(150)

    private var gesture = Gesture.idle
    /// Where the host's pointer last was, so a press that ends off the frame releases there.
    private var hostPosition = CGPoint(x: 0.5, y: 0.5)

    public init() {}

    public var phase: Phase {
        switch gesture {
        case .idle: .idle
        case .waiting: .waiting
        case .pressing: .pressing
        case .local: .local
        }
    }

    /// When a waiting touch presses unless something happens first. Call `holdElapsed(at:)` then.
    public var deadline: ContinuousClock.Instant? {
        if case .waiting(let touch) = gesture { touch.deadline } else { nil }
    }

    // MARK: The mouse

    /// A mouse button went down. A press while another button is down is ignored.
    public mutating func press(_ button: Screen.Input.Button, at position: CGPoint?) -> [Screen.Input] {
        guard case .idle = gesture else { return [] }
        return press(button, at: position, touch: nil)
    }

    /// The mouse moved, hovering or dragging.
    public mutating func move(to position: CGPoint?) -> [Screen.Input] {
        switch gesture {
        case .idle, .pressing(_, touch: nil): moveHost(to: position)
        case .waiting, .pressing, .local: []
        }
    }

    /// A mouse button went up. Only the pressed button releases, where it lifted, or else where the
    /// host's pointer last was.
    public mutating func release(_ button: Screen.Input.Button, at position: CGPoint?) -> [Screen.Input] {
        guard case .pressing(button, touch: nil) = gesture else { return [] }
        return release(at: position)
    }

    // MARK: Touches

    /// A finger touched down, at `point` in a space that doesn't zoom, like the window's.
    public mutating func touchBegan(_ touch: ObjectIdentifier, at point: CGPoint, position: CGPoint?,
                                    time: ContinuousClock.Instant) -> [Screen.Input] {
        switch gesture {
        case .idle:
            gesture = .waiting(Touch(id: touch, point: point, position: position, deadline: time + Self.hold))
        case .waiting(let waiting):
            gesture = .local([waiting.id, touch])
        case .local(var touches):
            touches.insert(touch)
            gesture = .local(touches)
        case .pressing:
            break
        }
        return []
    }

    /// A finger moved. A waiting touch that moves far enough presses where it began, then follows.
    public mutating func touchMoved(_ touch: ObjectIdentifier, at point: CGPoint, position: CGPoint?) -> [Screen.Input] {
        switch gesture {
        case .waiting(let waiting) where waiting.id == touch:
            let distance = hypot(point.x - waiting.point.x, point.y - waiting.point.y)
            guard distance >= Self.dragDistance else { return [] }
            let pressed = press(.primary, at: waiting.position, touch: touch)
            return pressed + (pressed.isEmpty ? [] : moveHost(to: position))
        case .pressing(_, let pressed) where pressed == touch:
            return moveHost(to: position)
        default:
            return []
        }
    }

    /// A finger lifted. A waiting touch taps where it lifted, and a pressing one releases.
    public mutating func touchEnded(_ touch: ObjectIdentifier, position: CGPoint?) -> [Screen.Input] {
        switch gesture {
        case .waiting(let waiting) where waiting.id == touch:
            gesture = .idle
            return press(.primary, at: position, touch: touch) + release(at: position)
        case .pressing(_, let pressed) where pressed == touch:
            return release(at: position)
        case .local:
            return end(touch)
        default:
            return []
        }
    }

    /// The system took a finger away. A waiting touch sends nothing, and a pressing one releases
    /// where the host's pointer last was.
    public mutating func touchCancelled(_ touch: ObjectIdentifier) -> [Screen.Input] {
        switch gesture {
        case .waiting(let waiting) where waiting.id == touch:
            gesture = .idle
            return []
        case .pressing(_, let pressed) where pressed == touch:
            return release(at: nil)
        case .local:
            return end(touch)
        default:
            return []
        }
    }

    /// Presses where a still, waiting touch began once its deadline has passed.
    public mutating func holdElapsed(at now: ContinuousClock.Instant) -> [Screen.Input] {
        guard case .waiting(let waiting) = gesture, now >= waiting.deadline else { return [] }
        return press(.primary, at: waiting.position, touch: waiting.id)
    }

    // MARK: The host

    /// Presses where the pointer is, unless that's off the frame, which leaves it idle.
    private mutating func press(_ button: Screen.Input.Button, at position: CGPoint?,
                                touch: ObjectIdentifier?) -> [Screen.Input] {
        guard let position else {
            gesture = .idle
            return []
        }
        gesture = .pressing(button, touch: touch)
        hostPosition = position
        return [.pointer(.down, at: position, button: button)]
    }

    private mutating func moveHost(to position: CGPoint?) -> [Screen.Input] {
        guard let position else { return [] }
        hostPosition = position
        return [.pointer(.move, at: position)]
    }

    private mutating func release(at position: CGPoint?) -> [Screen.Input] {
        guard case .pressing(let button, _) = gesture else { return [] }
        gesture = .idle
        hostPosition = position ?? hostPosition
        return [.pointer(.up, at: hostPosition, button: button)]
    }

    private mutating func end(_ touch: ObjectIdentifier) -> [Screen.Input] {
        guard case .local(var touches) = gesture else { return [] }
        touches.remove(touch)
        gesture = touches.isEmpty ? .idle : .local(touches)
        return []
    }
}
