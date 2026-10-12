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
}
