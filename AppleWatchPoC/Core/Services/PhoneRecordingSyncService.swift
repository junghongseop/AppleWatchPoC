import Foundation
import Combine
import AVFoundation
import WatchConnectivity

final class PhoneRecordingSyncService: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var recordings: [URL] = []
    @Published private(set) var connectionState: PhoneConnectionState = .checking
    @Published private(set) var measurements: [String: TransferMeasurement] = [:]
    @Published private(set) var recordingDetails: [String: ReceivedRecordingDetails] = [:]
    @Published var errorMessage: String?
    @Published private(set) var playingURL: URL?

    private let directory: URL
    private var player: AVAudioPlayer?
    private var lastProbeAt: Date?
    private static let measurementsKey = "receivedRecordingMeasurementsV2"
    private static let detailsKey = "receivedRecordingDetails"

    override init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReceivedRecordings", isDirectory: true)
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.measurementsKey),
           let saved = try? JSONDecoder().decode([String: TransferMeasurement].self, from: data) {
            measurements = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.detailsKey),
           let saved = try? JSONDecoder().decode([String: ReceivedRecordingDetails].self, from: data) {
            recordingDetails = saved
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            refreshRecordings()
        } catch {
            errorMessage = error.localizedDescription
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        } else {
            connectionState = .unavailable
        }
    }

    func measurement(for url: URL) -> TransferMeasurement? {
        measurements[url.deletingPathExtension().lastPathComponent]
    }

    func details(for url: URL) -> ReceivedRecordingDetails? {
        recordingDetails[url.deletingPathExtension().lastPathComponent]
    }

    func refreshConnectionState() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        updateConnectionStatus(WCSession.default)
    }

    func deleteRecordings(at offsets: IndexSet) {
        for index in offsets {
            let url = recordings[index]
            do {
                if playingURL == url { stopPlayback() }
                try FileManager.default.removeItem(at: url)
                measurements.removeValue(forKey: url.deletingPathExtension().lastPathComponent)
                recordingDetails.removeValue(forKey: url.deletingPathExtension().lastPathComponent)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        saveMeasurements()
        saveDetails()
        refreshRecordings()
    }

    private func saveMeasurements() {
        if let data = try? JSONEncoder().encode(measurements) {
            UserDefaults.standard.set(data, forKey: Self.measurementsKey)
        }
    }

    private func saveDetails() {
        if let data = try? JSONEncoder().encode(recordingDetails) {
            UserDefaults.standard.set(data, forKey: Self.detailsKey)
        }
    }

    private func refreshRecordings() {
        recordings = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var changed = false
        for url in recordings {
            let id = url.deletingPathExtension().lastPathComponent
            guard recordingDetails[id] == nil else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let receivedAt = attributes?[.creationDate] as? Date ?? Date()
            let duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
            recordingDetails[id] = ReceivedRecordingDetails(
                receivedAt: receivedAt, durationSeconds: duration
            )
            changed = true
        }
        if changed { saveDetails() }
    }

    func togglePlayback(_ url: URL) {
        if playingURL == url {
            stopPlayback()
            return
        }
        do {
            stopPlayback()
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
            playingURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    private func updateConnectionStatus(_ session: WCSession) {
        if !session.isPaired {
            connectionState = .unpaired
        } else if !session.isWatchAppInstalled {
            connectionState = .watchAppMissing
        } else {
            let recentlyProbed = lastProbeAt.map { Date().timeIntervalSince($0) < 3 } ?? false
            connectionState = session.isReachable || recentlyProbed ? .reachable : .background
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async {
            if let error { self.errorMessage = error.localizedDescription }
            self.updateConnectionStatus(session)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.updateConnectionStatus(session) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        if message["connectionProbe"] as? Bool == true {
            replyHandler(["connected": true])
            DispatchQueue.main.async {
                self.lastProbeAt = Date()
                self.updateConnectionStatus(session)
            }
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The received temporary file disappears when this callback returns.
        guard let id = file.metadata?["recordingID"] as? String,
              UUID(uuidString: id) != nil else { return }
        let destination = directory.appendingPathComponent(id).appendingPathExtension("m4a")
        do {
            let firstReceipt = !FileManager.default.fileExists(atPath: destination.path)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: file.fileURL, to: destination)
            }
            let receivedAt = Date()
            let duration = (try? AVAudioPlayer(contentsOf: destination).duration) ?? 0
            session.transferUserInfo(["savedRecordingID": id])
            DispatchQueue.main.async {
                if firstReceipt {
                    self.recordingDetails[id] = ReceivedRecordingDetails(
                        receivedAt: receivedAt, durationSeconds: duration
                    )
                    self.saveDetails()
                }
                self.errorMessage = nil
                self.refreshRecordings()
            }
        } catch {
            DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let id = userInfo["transferMetricID"] as? String,
              UUID(uuidString: id) != nil,
              let bytes = userInfo["fileBytes"] as? Int else { return }
        DispatchQueue.main.async {
            self.measurements[id] = TransferMeasurement(
                elapsedSeconds: userInfo["elapsedSeconds"] as? Double,
                fileBytes: bytes
            )
            self.saveMeasurements()
        }
    }
}
