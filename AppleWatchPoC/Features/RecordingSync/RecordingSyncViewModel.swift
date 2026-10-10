import Combine
import Foundation

final class RecordingSyncViewModel: ObservableObject {
    private let service: PhoneRecordingSyncService
    private var cancellable: AnyCancellable?

    init(service: PhoneRecordingSyncService = PhoneRecordingSyncService()) {
        self.service = service
        cancellable = service.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var recordings: [URL] { service.recordings }
    var connectionState: PhoneConnectionState { service.connectionState }
    var errorMessage: String? { service.errorMessage }
    var playingURL: URL? { service.playingURL }
    var speechTests: [SpeechTestResult] {
        service.speechTests.values.sorted { $0.startedAt > $1.startedAt }
    }

    func measurement(for url: URL) -> TransferMeasurement? { service.measurement(for: url) }
    func details(for url: URL) -> ReceivedRecordingDetails? { service.details(for: url) }
    func refreshConnectionState() { service.refreshConnectionState() }
    func deleteRecordings(at offsets: IndexSet) { service.deleteRecordings(at: offsets) }
    func togglePlayback(_ url: URL) { service.togglePlayback(url) }
    func stopPlayback() { service.stopPlayback() }
    func requestSpeechAuthorization() { service.requestSpeechAuthorization() }
    func deleteSpeechTest(id: String) { service.deleteSpeechTest(id: id) }
    func clearError() { service.errorMessage = nil }
}
