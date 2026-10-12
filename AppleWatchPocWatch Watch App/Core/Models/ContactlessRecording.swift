import Foundation

nonisolated struct MotionMarker: Codable, Identifiable {
    let id: UUID
    let offset: TimeInterval
    let label: String
}

nonisolated struct ContactlessRecording: Codable {
    let startedAt: Date
    var endedAt: Date?
    let trigger: String
    var markers: [MotionMarker] = []
    var endReason: String?
    var stopTrigger: String? = nil
    var executionMode: String? = nil
    var startApplicationState: String? = nil

    var stopTriggerDescription: String {
        stopTrigger ?? "미기록 (이전 버전 또는 시스템 종료)"
    }
}
