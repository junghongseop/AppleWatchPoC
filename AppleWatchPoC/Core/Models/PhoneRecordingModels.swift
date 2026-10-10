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

struct SpeechTestResult: Codable {
    static let referenceSentence = "오늘은 바람이 불지만 산책하기 좋은 날입니다"

    let id: String
    let mode: String
    let startedAt: Date
    var transcript: String
    var status: String
    var ambientDBFS: Double? = nil
    var fileTranscript: String? = nil
    var fileStatus: String? = nil
    var liveStreamInterrupted: Bool? = nil

    var liveAccuracy: Int? { accuracy(for: transcript) }
    var fileAccuracy: Int? { accuracy(for: fileTranscript ?? "") }

    private func accuracy(for text: String) -> Int? {
        let expected = Array(Self.referenceSentence.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
        guard !expected.isEmpty else { return nil }
        let actual = Array(text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
        var previous = Array(0...actual.count)
        for (index, character) in expected.enumerated() {
            var row = [index + 1] + Array(repeating: 0, count: actual.count)
            for (column, candidate) in actual.enumerated() {
                row[column + 1] = min(previous[column + 1] + 1,
                                      row[column] + 1,
                                      previous[column] + (character == candidate ? 0 : 1))
            }
            previous = row
        }
        return Int((max(0, 1 - Double(previous[actual.count]) / Double(expected.count)) * 100).rounded())
    }
}

enum AmbientNoiseBand: String, CaseIterable {
    case low = "조용한 편"
    case medium = "생활 소음 수준"
    case high = "시끄러운 편"

    static func from(_ dbfs: Double) -> Self {
        if dbfs < -50 { return .low }
        if dbfs < -30 { return .medium }
        return .high
    }
}
