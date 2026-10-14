// Compile with HandGesture.swift and HandCaptureBudget.swift using swiftc.
import Foundation
import CoreGraphics

@main
struct HandGestureTests {
    static func main() {
        classificationTests()
        frontalFistTests()
        gateTests()
        preparationTests()
        throttledRecognitionTests()
        videoFormatTests()
        print("HandGestureTests: all checks passed")
    }

    static func classificationTests() {
        let cases: [([Bool], HandGesture)] = [
            ([true, false, false, false], .voice),
            ([true, true, false, false], .photo),
            ([true, true, true, true], .video),
            ([false, false, false, false], .stop)
        ]
        for (extended, expected) in cases {
            for rotation in [0.0, Double.pi / 2, Double.pi, -Double.pi / 3] {
                for mirrored in [false, true] {
                    let pose = makePose(extended, rotation: rotation, mirrored: mirrored)
                    assert(pose.gesture() == expected, "Rotation/mirroring must preserve \(expected)")
                }
            }
        }
        assert(makePose([true, false, true, false]).gesture() == nil, "Unknown pose must stay neutral")
        assert(HandPose(wrist: .zero, fingers: []).gesture() == nil, "Missing joints must not trigger")
        let degenerate = HandPose.Finger(base: .zero, joint: .zero, tip: .zero)
        assert(HandPose(wrist: .zero, fingers: Array(repeating: degenerate, count: 4)).gesture() == nil)
    }

    static func frontalFistTests() {
        func frontFist(scale: Double = 1, rotation: Double = 0, mirrored: Bool = false) -> HandPose {
            func transform(_ point: CGPoint) -> CGPoint {
                let x = (mirrored ? -point.x : point.x) * scale, y = point.y * scale
                return CGPoint(x: x * cos(rotation) - y * sin(rotation) + 0.4,
                               y: x * sin(rotation) + y * cos(rotation) + 0.3)
            }
            let fingers = (0..<4).map { index in
                let x = (Double(index) - 1.5) * 0.07
                return HandPose.Finger(base: transform(CGPoint(x: x, y: 0.2)),
                                       joint: transform(CGPoint(x: x, y: 0.235)),
                                       tip: transform(CGPoint(x: x, y: 0.235)))
            }
            return HandPose(wrist: transform(.zero), fingers: fingers)
        }
        for scale in [0.5, 1.0, 2.0] {
            for rotation in [0.0, Double.pi / 2, -Double.pi / 3] {
                for mirrored in [false, true] {
                    assert(frontFist(scale: scale, rotation: rotation, mirrored: mirrored).gesture() == .stop,
                           "Overlapping PIP/tip in a frontal fist must work across scales and orientations")
                }
            }
        }
        let pose = frontFist()
        var fingers = pose.fingers
        fingers[3] = HandPose.Finger(base: fingers[3].base, joint: nil, tip: nil)
        let occluded = HandPose(wrist: pose.wrist, fingers: fingers)
        assert(occluded.gesture() == nil, "Idle recognition stays strict")
        assert(occluded.gesture(allowPartiallyOccludedFist: true) == .stop, "Three compact fingers can stop an active recording")
        fingers[0] = HandPose.Finger(base: fingers[0].base, joint: nil, tip: nil)
        assert(HandPose(wrist: pose.wrist, fingers: fingers).gesture(allowPartiallyOccludedFist: true) == nil,
               "Multiple missing fingers are not evidence of a fist")
        fingers = pose.fingers
        fingers[0] = HandPose.Finger(base: fingers[0].base, joint: nil, tip: nil)
        assert(HandPose(wrist: pose.wrist, fingers: fingers).gesture(allowPartiallyOccludedFist: true) == nil,
               "An occluded index in a voice gesture must not stop recording")
        fingers = pose.fingers
        let index = fingers[0]
        fingers[0] = HandPose.Finger(base: index.base, joint: index.joint,
                                    tip: CGPoint(x: index.base.x, y: index.base.y + 0.3), tipConfidence: 0.4)
        assert(HandPose(wrist: pose.wrist, fingers: fingers).gesture(allowPartiallyOccludedFist: true) == nil,
               "A visible extended finger must veto a fist even at moderate confidence")
        fingers = pose.fingers.map { HandPose.Finger(base: $0.base, joint: $0.joint, tip: $0.tip, baseConfidence: 0.2) }
        assert(HandPose(wrist: pose.wrist, fingers: fingers).gesture(allowPartiallyOccludedFist: true) == nil,
               "Weak palm anchors must not trigger")
        var gate = HandGestureGate()
        var fired: [HandGesture] = []
        for frame in 0...12 {
            let sample = frontFist(rotation: frame.isMultiple(of: 2) ? 0.02 : -0.02)
            if let action = gate.update(sample.gesture(), at: Double(frame) * 0.3).action { fired.append(action) }
        }
        assert(fired == [.stop], "Frontal fists must still require a hold and fire only once")
    }

    static func makePose(_ extended: [Bool], rotation: Double = 0, mirrored: Bool = false) -> HandPose {
        func transform(_ point: CGPoint) -> CGPoint {
            let x = mirrored ? -point.x : point.x
            return CGPoint(x: x * cos(rotation) - point.y * sin(rotation) + 0.3,
                           y: x * sin(rotation) + point.y * cos(rotation) + 0.2)
        }
        let fingers = extended.enumerated().map { index, isExtended in
            let x = Double(index - 2) * 0.07
            return HandPose.Finger(base: transform(CGPoint(x: x, y: 0.2)),
                                   joint: transform(CGPoint(x: x, y: 0.4)),
                                   tip: transform(CGPoint(x: x, y: isExtended ? 0.6 : 0.22)))
        }
        return HandPose(wrist: transform(.zero), fingers: fingers)
    }

    static func gateTests() {
        var gate = HandGestureGate()
        var actions: [HandGesture] = []
        for step in 0...40 {
            if let action = gate.update(.photo, at: Double(step) * 0.1).action { actions.append(action) }
        }
        assert(actions == [.photo], "A held pose must only fire once")
        for step in 41...44 { _ = gate.update(nil, at: Double(step) * 0.1) }
        assert(gate.update(.photo, at: 4.5).action == nil, "A short dropout must not rearm")
        for step in 46...53 { _ = gate.update(nil, at: Double(step) * 0.1) }
        for step in 54...66 {
            if let action = gate.update(.photo, at: Double(step) * 0.1).action { actions.append(action) }
        }
        assert(actions == [.photo, .photo], "Neutral release must allow a second capture")
        for step in 67...80 {
            if let action = gate.update(.stop, at: Double(step) * 0.1).action { actions.append(action) }
        }
        assert(actions.last == .stop, "Stop must work directly after a different gesture")

        var gap = HandGestureGate()
        _ = gap.update(.voice, at: 0)
        _ = gap.update(.voice, at: 0.3)
        assert(gap.update(.voice, at: 5).action == nil, "Suspended frames must not count toward hold")
        assert(gap.update(.voice, at: 5.1).progress < 0.2)

        var flicker = HandGestureGate()
        for step in 0...30 {
            assert(flicker.update(step.isMultiple(of: 2) ? .voice : .photo, at: Double(step) * 0.1).action == nil,
                   "Alternating poses must not fire")
        }
    }

    static func preparationTests() {
        var photo = HandCapturePreparation(kind: .photo)
        assert(!photo.canCapture(at: 1000), "Hidden preview must never trigger a photo")
        assert(photo.secondsRemaining(at: 1000) == nil, "Countdown must wait for the visible preview")
        photo.acknowledgePreview(id: UUID(), at: 1)
        assert(photo.previewVisibleAt == nil, "A stale preview callback must be ignored")

        photo.acknowledgePreview(id: photo.id, at: 100)
        assert(photo.secondsRemaining(at: 100) == 5)
        assert(photo.secondsRemaining(at: 102) == 3)
        assert(photo.secondsRemaining(at: 104.999) == 1)
        assert(!photo.canCapture(at: 104.999), "Capture must not occur even slightly before five seconds")
        photo.acknowledgePreview(id: photo.id, at: 104)
        assert(photo.canCapture(at: 105), "Duplicate UI acknowledgments must not restart the countdown")
        assert(photo.secondsRemaining(at: 105) == 0)
        assert(photo.canCapture(at: 110), "A delayed timer must still finish the pending photo")
        assert(!photo.canCapture(at: 99), "A timestamp before preview presentation must not trigger capture")

        var replacement = HandCapturePreparation(kind: .photo)
        replacement.acknowledgePreview(id: photo.id, at: 200)
        assert(!replacement.canCapture(at: 300), "A canceled request must not start its replacement")

        var video = HandCapturePreparation(kind: .video)
        assert(!video.canCapture(at: 1000), "Video must not record while the preview is hidden")
        video.acknowledgePreview(id: video.id, at: 20)
        assert(video.canCapture(at: 20), "Video starts after preview acknowledgment without a photo countdown")
        assert(video.secondsRemaining(at: 20) == nil)
    }

    static func throttledRecognitionTests() {
        // Simulate actual camera frames and skipped Vision frames. Lower sampling must
        // still trigger once per hold and allow a new capture after a neutral interval.
        for visualCapture in [false, true] {
            for constrained in [false, true] {
                for previewVisible in [false, true] {
                    for recordingVideo in [false, true] {
                        let budget = HandCaptureBudget(visualCapture: visualCapture, constrained: constrained, previewVisible: previewVisible, recordingVideo: recordingVideo)
                        assert(budget.detectionInterval == (recordingVideo ? 0.3 : constrained ? 0.25 : 0.2), "Preview must not increase Vision frequency")
                        if !visualCapture && !recordingVideo {
                            assert(budget.cameraFPS == (constrained ? (previewVisible ? 15 : 10) : (previewVisible ? 30 : 15)))
                        }
                        var gate = HandGestureGate()
                        var lastDetection = -1.0
                        var actions: [TimeInterval] = []
                        for frame in 0...(Int(budget.cameraFPS) * 6) {
                            let time = Double(frame) / Double(budget.cameraFPS)
                            guard time - lastDetection >= budget.detectionInterval else { continue }
                            lastDetection = time
                            let pose: HandGesture? = (time < 2 || time >= 3) ? .photo : nil
                            if gate.update(pose, at: time).action != nil { actions.append(time) }
                        }
                        assert(actions.count == 2, "Throttling must preserve repeat protection and neutral rearming")
                        assert(actions[0] >= 0.9 && actions[0] <= 1.5, "First hold must remain responsive")
                        assert(actions[1] >= 3.9 && actions[1] <= 4.5, "Rearmed hold must remain responsive")
                        if recordingVideo { assert(budget.cameraFPS == 60, "Target 60fps regardless of standby power settings") }
                        else if visualCapture { assert(budget.cameraFPS == 30, "Photos retain their existing profile") }
                    }
                }
            }
        }
    }

    static func videoFormatTests() {
        let hd30 = HandVideoFormat(width: 1280, height: 720, frameRates: [1...30])
        let hd60 = HandVideoFormat(width: 1280, height: 720, frameRates: [1...60])
        let fullHD60 = HandVideoFormat(width: 1920, height: 1080, frameRates: [1...60])
        let fourK60 = HandVideoFormat(width: 3840, height: 2160, frameRates: [1...60])
        assert(HandVideoFormat.select(from: [hd30, fullHD60])?.index == 1, "Prefer 60fps over a 30fps preset")
        assert(HandVideoFormat.select(from: [fullHD60, hd60])?.index == 1, "Prefer 720p60 to reduce encoding and Vision load")
        assert(HandVideoFormat.select(from: [hd30])?.fps == 30, "Older front cameras must fall back to 30fps")
        assert(HandVideoFormat.select(from: [fourK60, hd30])?.index == 1, "Avoid increasing heat with 4K60")
        let discontinuous = HandVideoFormat(width: 1280, height: 720, frameRates: [1...30, 120...240])
        assert(HandVideoFormat.select(from: [discontinuous])?.fps == 30, "A high maximum does not imply support for 60fps")
        assert(HandVideoFormat.select(from: []) == nil)
        assert(HandVideoFormat.select(from: [HandVideoFormat(width: 1280, height: 720, frameRates: [1...24])]) == nil)
    }
}
