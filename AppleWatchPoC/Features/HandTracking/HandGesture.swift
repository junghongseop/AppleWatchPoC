import Foundation
import CoreGraphics

nonisolated enum HandGesture: String, CaseIterable, Sendable {
    case voice, photo, video, stop

    var title: String {
        switch self {
        case .voice: "검지 하나 · 음성 녹음"
        case .photo: "V자 · 사진 촬영"
        case .video: "손바닥 · 영상 녹화"
        case .stop: "주먹 · 기록 종료"
        }
    }

    var symbol: String {
        switch self {
        case .voice: "mic.fill"
        case .photo: "camera.fill"
        case .video: "video.fill"
        case .stop: "stop.fill"
        }
    }
}

/// Points must be in an aspect-correct coordinate space, not a stretched unit square.
nonisolated struct HandPose: Sendable {
    struct Finger: Sendable {
        let base: CGPoint
        let joint: CGPoint?
        let tip: CGPoint?
        var baseConfidence: Float = 1
        var jointConfidence: Float = 1
        var tipConfidence: Float = 1
    }

    let wrist: CGPoint
    let fingers: [Finger] // Index, middle, ring, little. Thumb is intentionally ignored.

    func gesture(allowPartiallyOccludedFist: Bool = false) -> HandGesture? {
        guard fingers.count == 4 else { return nil }
        let states = fingers.map { finger -> Int in
            guard finger.baseConfidence >= 0.5, finger.jointConfidence >= 0.5, finger.tipConfidence >= 0.5,
                  let joint = finger.joint, let tip = finger.tip else { return 0 }
            let a = CGPoint(x: finger.base.x - joint.x, y: finger.base.y - joint.y)
            let b = CGPoint(x: tip.x - joint.x, y: tip.y - joint.y)
            let denominator = hypot(a.x, a.y) * hypot(b.x, b.y)
            let jointDistance = distance(joint, wrist)
            guard denominator > 0.0001, jointDistance > 0.0001 else { return 0 }
            let cosine = (a.x * b.x + a.y * b.y) / denominator
            let ratio = distance(tip, wrist) / jointDistance
            if cosine < -0.65, ratio > 1.12 { return 1 } // Extended.
            if ratio < 0.95 { return -1 } // Folded; uncertain poses stay neutral.
            return 0
        }
        switch states {
        case [1, -1, -1, -1]: return .voice
        case [1, 1, -1, -1]: return .photo
        case [1, 1, 1, 1]: return .video
        case [-1, -1, -1, -1]: return .stop
        default:
            return isCompactFist(allowOcclusion: allowPartiallyOccludedFist) ? .stop : nil
        }
    }

    private func isCompactFist(allowOcclusion: Bool) -> Bool {
        // A front-facing fist projects PIP and tip almost on top of one another.
        // Normalize against the palm, instead of requiring a visible bent joint.
        guard fingers.allSatisfy({ $0.baseConfidence >= 0.3 }),
              fingers.filter({ $0.baseConfidence >= 0.5 }).count >= 3 else { return false }
        let palmSize = fingers.map { distance($0.base, wrist) }.reduce(0, +) / 4
        let palmWidth = distance(fingers[0].base, fingers[3].base)
        guard palmSize > 0.025, palmWidth > 0.015, palmWidth / palmSize > 0.25 else { return false }
        var compactCount = 0
        var uncertainCount = 0
        for (index, finger) in fingers.enumerated() {
            guard let tip = finger.tip, finger.tipConfidence >= (allowOcclusion ? 0.3 : 0.5) else {
                // Keep index/middle visible so an occluded voice/V gesture cannot
                // be mistaken for a stop; only ring/little may be missing.
                guard allowOcclusion, index >= 2 else { return false }
                uncertainCount += 1
                continue
            }
            let axisLength = distance(finger.base, wrist)
            guard axisLength > 0.0001 else { return false }
            let dx = tip.x - finger.base.x, dy = tip.y - finger.base.y
            let projection = (dx * (finger.base.x - wrist.x) + dy * (finger.base.y - wrist.y)) / axisLength
            // Even one visible protruding finger rules out a fist. Missing points
            // alone never imply a folded finger.
            guard distance(tip, finger.base) <= palmSize * 0.6,
                  projection <= palmSize * 0.35 else { return false }
            if let joint = finger.joint, finger.jointConfidence >= 0.3 {
                guard distance(joint, finger.base) <= palmSize * 0.75 else { return false }
            } else if !allowOcclusion { return false }
            compactCount += 1
        }
        return compactCount == 4 || (allowOcclusion && compactCount == 3 && uncertainCount == 1)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// A stable hold fires once. A different pose can fire next; repeating the same pose
/// requires a neutral interval. Long gaps never count toward a continuous hold.
nonisolated struct HandGestureGate {
    var holdDuration: TimeInterval = 0.9
    var releaseDuration: TimeInterval = 0.5
    private var candidate: HandGesture?
    private var candidateSince: TimeInterval = 0
    private var fired: HandGesture?
    private var neutralSince: TimeInterval?
    private var lastSample: TimeInterval?

    mutating func update(_ gesture: HandGesture?, at time: TimeInterval) -> (progress: Double, action: HandGesture?) {
        if let lastSample, time - lastSample > 0.4 || time < lastSample {
            candidate = nil
            neutralSince = nil
        }
        lastSample = time
        guard let gesture else {
            candidate = nil
            if neutralSince == nil { neutralSince = time }
            if time - (neutralSince ?? time) >= releaseDuration { fired = nil }
            return (0, nil)
        }
        neutralSince = nil
        guard gesture != fired else { return (1, nil) }
        if candidate != gesture {
            candidate = gesture
            candidateSince = time
        }
        let progress = min(1, max(0, (time - candidateSince) / holdDuration))
        guard progress >= 1 else { return (progress, nil) }
        fired = gesture
        candidate = nil
        return (1, gesture)
    }
}

nonisolated enum HandRecordingKind: String, Sendable {
    case voice, photo, video

    var title: String {
        switch self {
        case .voice: "음성"
        case .photo: "사진"
        case .video: "영상"
        }
    }

    var fileExtension: String {
        switch self {
        case .voice: "m4a"
        case .photo: "jpg"
        case .video: "mov"
        }
    }
}

nonisolated struct HandRecording: Identifiable, Sendable {
    let url: URL
    let kind: HandRecordingKind
    let date: Date
    var id: URL { url }
}

/// Timing starts only after the visible preview acknowledges this particular request.
nonisolated struct HandCapturePreparation: Sendable {
    let id = UUID()
    let kind: HandRecordingKind
    private(set) var previewVisibleAt: TimeInterval?

    mutating func acknowledgePreview(id: UUID, at time: TimeInterval) {
        guard self.id == id, previewVisibleAt == nil else { return }
        previewVisibleAt = time
    }

    func secondsRemaining(at time: TimeInterval) -> Int? {
        guard kind == .photo, let previewVisibleAt else { return nil }
        return Int(ceil(max(0, 5 - (time - previewVisibleAt))))
    }

    func canCapture(at time: TimeInterval) -> Bool {
        guard let previewVisibleAt, time >= previewVisibleAt else { return false }
        return kind == .video || (kind == .photo && time - previewVisibleAt >= 5)
    }
}
