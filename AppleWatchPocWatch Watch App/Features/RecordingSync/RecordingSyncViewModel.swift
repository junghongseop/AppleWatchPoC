import Combine
import Foundation

final class RecordingSyncViewModel: ObservableObject {
    private let service: WatchRecordingSyncService
    private var cancellable: AnyCancellable?

    init(service: WatchRecordingSyncService = WatchRecordingSyncService()) {
        self.service = service
        cancellable = service.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var recordings: [URL] { service.recordings }
    var isRecording: Bool { service.isRecording }
    var connectionState: WatchConnectionState { service.connectionState }
    var errorMessage: String? { service.errorMessage }

    func startRecording() { service.startRecording() }
    func stopRecording() { service.stopRecording() }
    func queuePendingRecordings() { service.queuePendingRecordings() }
    func refreshConnectionStatus() { service.refreshConnectionStatus() }
    func status(for url: URL) -> String { service.status(for: url) }
}
