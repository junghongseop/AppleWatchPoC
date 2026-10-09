import AVFoundation
import Combine
import Foundation
import WatchConnectivity

final class WatchRecordingSyncService: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var recordings: [URL] = []
    @Published private(set) var isRecording = false
    @Published private(set) var connectionState: WatchConnectionState = .checking
    @Published var errorMessage: String?

    private static let startTimesKey = "recordingConnectedTransferStartTimesV2"
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var activeProbeID: UUID?
    private let directory: URL

    override init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        super.init()
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

    func startRecording() {
        guard !isRecording else { return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.errorMessage = "마이크 권한을 허용해 주세요."
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
            ])
            guard recorder.record() else {
                throw NSError(domain: "Recording", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "녹음을 시작할 수 없습니다."])
            }
            self.recorder = recorder
            currentURL = url
            isRecording = true
            errorMessage = nil
        } catch {
            try? FileManager.default.removeItem(at: url)
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recorder?.stop()
        recorder = nil
        isRecording = false
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        refreshRecordings()
        queuePendingRecordings()
    }

    func queuePendingRecordings() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        let queued = Set(session.outstandingFileTransfers.compactMap {
            $0.file.metadata?["recordingID"] as? String
        })
        for url in recordings where url != currentURL {
            let id = url.deletingPathExtension().lastPathComponent
            guard !queued.contains(id) else { continue }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if connectionState == .reachable { markConnected(at: Date(), for: [id]) }
            session.transferFile(url, metadata: ["recordingID": id, "fileBytes": bytes])
        }
        objectWillChange.send()
    }

    private func removeStartTime(for id: String) -> Double? {
        var startTimes = UserDefaults.standard.dictionary(forKey: Self.startTimesKey) as? [String: Double] ?? [:]
        let value = startTimes.removeValue(forKey: id)
        UserDefaults.standard.set(startTimes, forKey: Self.startTimesKey)
        return value
    }

    private func markConnected(at date: Date, for ids: [String]) {
        var startTimes = UserDefaults.standard.dictionary(forKey: Self.startTimesKey) as? [String: Double] ?? [:]
        for id in ids where startTimes[id] == nil {
            startTimes[id] = date.timeIntervalSince1970
        }
        UserDefaults.standard.set(startTimes, forKey: Self.startTimesKey)
    }

    private func updateMeasurementStart(for session: WCSession, reachable: Bool) {
        let ids = session.outstandingFileTransfers.compactMap {
            $0.file.metadata?["recordingID"] as? String
        }
        if reachable {
            markConnected(at: Date(), for: ids)
        } else {
            for id in ids { _ = removeStartTime(for: id) }
        }
    }

    func status(for url: URL) -> String {
        let id = url.deletingPathExtension().lastPathComponent
        let queued = WCSession.isSupported() && WCSession.default.outstandingFileTransfers.contains {
            ($0.file.metadata?["recordingID"] as? String) == id
        }
        return queued ? "전송 대기 또는 진행 중" : "아이폰 저장 확인 대기"
    }

    private func refreshRecordings() {
        recordings = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" && $0 != currentURL }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func setConnectionStatus(_ reachable: Bool, session: WCSession) {
        let newState: WatchConnectionState = reachable ? .reachable : .background
        guard connectionState != newState else { return }
        connectionState = newState
        updateMeasurementStart(for: session, reachable: reachable)
        if reachable { queuePendingRecordings() }
    }

    func refreshConnectionStatus() {
        guard WCSession.isSupported() else {
            connectionState = .unavailable
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            connectionState = .checking
            return
        }
        guard session.isReachable else {
            activeProbeID = nil
            setConnectionStatus(false, session: session)
            return
        }
        guard activeProbeID == nil else { return }
        let probeID = UUID()
        activeProbeID = probeID
        session.sendMessage(["connectionProbe": true], replyHandler: { [weak self] _ in
            DispatchQueue.main.async {
                self?.finishProbe(probeID, connected: true, session: session)
            }
        }, errorHandler: { [weak self] _ in
            DispatchQueue.main.async {
                self?.finishProbe(probeID, connected: false, session: session)
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finishProbe(probeID, connected: false, session: session)
        }
    }

    private func finishProbe(_ probeID: UUID, connected: Bool, session: WCSession) {
        guard activeProbeID == probeID else { return }
        activeProbeID = nil
        setConnectionStatus(connected && session.isReachable, session: session)
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async {
            if let error { self.errorMessage = error.localizedDescription }
            if state == .activated {
                self.setConnectionStatus(session.isReachable, session: session)
                self.queuePendingRecordings()
                self.refreshConnectionStatus()
            } else {
                self.connectionState = .checking
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.activeProbeID = nil
            self.setConnectionStatus(session.isReachable, session: session)
            if session.isReachable { self.refreshConnectionStatus() }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer,
                 error: Error?) {
        DispatchQueue.main.async {
            if let id = fileTransfer.file.metadata?["recordingID"] as? String {
                let startedAt = self.removeStartTime(for: id)
                guard error == nil else {
                    self.errorMessage = error?.localizedDescription
                    self.objectWillChange.send()
                    return
                }
                let bytes = fileTransfer.file.metadata?["fileBytes"] as? Int ?? 0
                var metric: [String: Any] = [
                    "transferMetricID": id,
                    "fileBytes": bytes
                ]
                if let startedAt {
                    metric["elapsedSeconds"] = max(0, Date().timeIntervalSince1970 - startedAt)
                }
                session.transferUserInfo(metric)
            }
            if let error { self.errorMessage = error.localizedDescription }
            self.objectWillChange.send()
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let id = userInfo["savedRecordingID"] as? String,
              UUID(uuidString: id) != nil else { return }
        DispatchQueue.main.async {
            let url = self.directory.appendingPathComponent(id).appendingPathExtension("m4a")
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                self.refreshRecordings()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
