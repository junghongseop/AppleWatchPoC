import Foundation

enum PhoneConnectionState: Equatable {
    case checking, unavailable, unpaired, watchAppMissing, reachable, background
}

struct TransferMeasurement: Codable {
    let elapsedSeconds: Double?
    let fileBytes: Int
}

struct ReceivedRecordingDetails: Codable {
    let receivedAt: Date
    let durationSeconds: Double
}
