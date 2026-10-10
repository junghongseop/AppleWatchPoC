import Foundation
import Combine
import AVFoundation
import WatchConnectivity
import Speech

final class PhoneRecordingSyncService: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var recordings: [URL] = []
    @Published private(set) var connectionState: PhoneConnectionState = .checking
    @Published private(set) var measurements: [String: TransferMeasurement] = [:]
    @Published private(set) var recordingDetails: [String: ReceivedRecordingDetails] = [:]
    @Published var errorMessage: String?
    @Published private(set) var playingURL: URL?
    @Published private(set) var speechTests: [String: SpeechTestResult] = [:]

    private let directory: URL
    private var player: AVAudioPlayer?
    private var lastProbeAt: Date?
    private static let measurementsKey = "receivedRecordingMeasurementsV2"
    private static let detailsKey = "receivedRecordingDetails"
    private static let speechTestsKey = "speechTestResultsV1"
    private static let speechResetKey = "speechTestResultsResetV2"
    private static let deletedSpeechTestPrefix = "deletedSpeechTest."
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?
    private var liveID: String?
    private var liveFormat: AVAudioFormat?
    private var liveFinishingID: String?
    private var fileTask: SFSpeechRecognitionTask?
    private var activeFileID: String?
    private var fileQueue: [(url: URL, id: String)] = []

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
        if let data = UserDefaults.standard.data(forKey: Self.speechTestsKey),
           let saved = try? JSONDecoder().decode([String: SpeechTestResult].self, from: data) {
            speechTests = saved
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            clearPreviousSpeechTestsIfNeeded()
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

    private func clearPreviousSpeechTestsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.speechResetKey) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)
            var oldIDs = Set(speechTests.keys)
            for url in files where url.pathExtension == "caf" {
                let id = url.deletingPathExtension().lastPathComponent
                try FileManager.default.removeItem(at: url)
                oldIDs.insert(id)
            }
            for id in oldIDs {
                measurements.removeValue(forKey: id)
                recordingDetails.removeValue(forKey: id)
            }
            speechTests.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.speechTestsKey)
            saveMeasurements()
            saveDetails()
            UserDefaults.standard.set(true, forKey: Self.speechResetKey)
        } catch {
            errorMessage = "기존 시험 결과를 삭제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func measurement(for url: URL) -> TransferMeasurement? {
        measurements[url.deletingPathExtension().lastPathComponent]
    }

    func details(for url: URL) -> ReceivedRecordingDetails? {
        recordingDetails[url.deletingPathExtension().lastPathComponent]
    }

    func requestSpeechAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self?.resumePendingTranscriptions()
                } else {
                    self?.errorMessage = "아이폰 설정에서 음성 인식 권한을 허용해 주세요."
                }
            }
        }
    }

    private func saveSpeechTests() {
        if let data = try? JSONEncoder().encode(speechTests) {
            UserDefaults.standard.set(data, forKey: Self.speechTestsKey)
        }
    }

    private func isDeletedSpeechTest(_ id: String) -> Bool {
        UserDefaults.standard.bool(forKey: Self.deletedSpeechTestPrefix + id)
    }

    func deleteSpeechTest(id: String) {
        guard UUID(uuidString: id) != nil else { return }
        let url = directory.appendingPathComponent(id).appendingPathExtension("caf")
        do {
            UserDefaults.standard.set(true, forKey: Self.deletedSpeechTestPrefix + id)
            if playingURL == url { stopPlayback() }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            if liveID == id || liveFinishingID == id {
                liveTask?.cancel()
                liveTask = nil
                liveRequest = nil
                liveFormat = nil
                liveID = nil
                liveFinishingID = nil
            }
            if activeFileID == id {
                fileTask?.cancel()
                fileTask = nil
                activeFileID = nil
            }
            fileQueue.removeAll { $0.id == id }
            speechTests.removeValue(forKey: id)
            measurements.removeValue(forKey: id)
            recordingDetails.removeValue(forKey: id)
            saveSpeechTests()
            saveMeasurements()
            saveDetails()
            refreshRecordings()
            startNextFileTranscription()
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.deletedSpeechTestPrefix + id)
            errorMessage = error.localizedDescription
        }
    }

    private func updateLiveTranscript(_ text: String, status: String, for id: String) {
        guard var test = speechTests[id] else { return }
        test.transcript = text
        test.status = status
        speechTests[id] = test
        saveSpeechTests()
    }

    private func updateFileTranscript(_ text: String, status: String, for id: String) {
        guard var test = speechTests[id] else { return }
        test.fileTranscript = text
        test.fileStatus = status
        speechTests[id] = test
        saveSpeechTests()
    }

    private func beginLiveRecognition(id: String, sampleRate: Double,
                                      ambientLevel: Double?) -> String? {
        guard !isDeletedSpeechTest(id) else { return "삭제된 시험입니다." }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return "아이폰에서 음성 인식 권한을 먼저 허용해 주세요."
        }
        guard let recognizer, recognizer.isAvailable else {
            return "한국어 음성 인식을 사용할 수 없습니다. 네트워크 상태를 확인해 주세요."
        }
        guard activeFileID == nil, liveFinishingID == nil else {
            return "종료 후 변환이 진행 중입니다. 완료 후 다시 시작해 주세요."
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false) else {
            return "오디오 형식을 사용할 수 없습니다."
        }
        liveTask?.cancel()
        liveRequest = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        var test = SpeechTestResult(id: id, mode: "both", startedAt: Date(), transcript: "",
                                    status: "듣는 중")
        test.ambientDBFS = ambientLevel
        speechTests[id] = test
        saveSpeechTests()
        liveID = id
        liveFormat = format
        liveRequest = request
        liveTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.speechTests[id] != nil else { return }
                if let result {
                    self.updateLiveTranscript(result.bestTranscription.formattedString,
                                              status: result.isFinal ? "완료" : "실시간 인식 중", for: id)
                    if result.isFinal { self.finishLiveRecognition(id: id) }
                }
                if let error, self.speechTests[id]?.status != "완료" {
                    self.updateLiveTranscript(self.speechTests[id]?.transcript ?? "",
                                              status: "인식 오류: \(error.localizedDescription)", for: id)
                    self.finishLiveRecognition(id: id)
                }
            }
        }
        return nil
    }

    private func appendLiveSamples(_ data: Data, id: String) {
        guard liveID == id, let format = liveFormat, let request = liveRequest,
              data.count.isMultiple(of: MemoryLayout<Float>.size),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(data.count / MemoryLayout<Float>.size)),
              let channel = buffer.floatChannelData?.pointee else { return }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(channel, source, data.count)
        }
        request.append(buffer)
    }

    private func endLiveRecognition(id: String) {
        guard liveID == id else { return }
        liveRequest?.endAudio()
        liveRequest = nil
        liveFormat = nil
        liveID = nil
        if speechTests[id]?.status == "완료" {
            liveTask = nil
            startNextFileTranscription()
            return
        }
        liveFinishingID = id
        if var test = speechTests[id], test.status == "듣는 중" || test.status == "실시간 인식 중" {
            test.status = "최종 결과 대기 중"
            speechTests[id] = test
            saveSpeechTests()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.liveFinishingID == id else { return }
            self.updateLiveTranscript(self.speechTests[id]?.transcript ?? "",
                                      status: "실시간 결과 지연 또는 중단", for: id)
            self.liveTask?.cancel()
            self.finishLiveRecognition(id: id)
        }
    }

    private func cancelLiveRecognition(id: String) {
        if liveID == id || liveFinishingID == id {
            liveTask?.cancel()
            liveTask = nil
            liveRequest = nil
            liveFormat = nil
            liveID = nil
            liveFinishingID = nil
        }
        speechTests.removeValue(forKey: id)
        saveSpeechTests()
        startNextFileTranscription()
    }

    private func finishLiveRecognition(id: String) {
        guard liveFinishingID == id else { return }
        liveFinishingID = nil
        liveTask = nil
        startNextFileTranscription()
    }

    private func resumePendingTranscriptions() {
        for test in speechTests.values
        where (test.mode == "both" && test.fileStatus != "완료") ||
              (test.mode == "after" && test.status != "완료") {
            let url = directory.appendingPathComponent(test.id).appendingPathExtension("caf")
            if FileManager.default.fileExists(atPath: url.path) { enqueueTranscription(url, id: test.id) }
        }
    }

    private func enqueueTranscription(_ url: URL, id: String) {
        guard activeFileID != id, !fileQueue.contains(where: { $0.id == id }) else { return }
        fileQueue.append((url, id))
        startNextFileTranscription()
    }

    private func startNextFileTranscription() {
        guard activeFileID == nil, liveID == nil, liveFinishingID == nil,
              !fileQueue.isEmpty else { return }
        let next = fileQueue.removeFirst()
        let url = next.url
        let id = next.id
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer, recognizer.isAvailable else {
            updateFileTranscript("", status: "음성 인식 권한 또는 서비스를 확인해 주세요", for: id)
            return
        }
        activeFileID = id
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        fileTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.speechTests[id] != nil else { return }
                if let result {
                    self.updateFileTranscript(result.bestTranscription.formattedString,
                                              status: result.isFinal ? "완료" : "변환 중", for: id)
                    if result.isFinal { self.finishFileTranscription(id: id) }
                }
                if let error, self.speechTests[id]?.fileStatus != "완료" {
                    self.updateFileTranscript(self.speechTests[id]?.fileTranscript ?? "",
                                              status: "인식 오류: \(error.localizedDescription)", for: id)
                    self.finishFileTranscription(id: id)
                }
            }
        }
    }

    private func finishFileTranscription(id: String) {
        guard activeFileID == id else { return }
        activeFileID = nil
        fileTask = nil
        startNextFileTranscription()
    }

    func refreshConnectionState() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        updateConnectionStatus(WCSession.default)
    }

    func deleteRecordings(at offsets: IndexSet) {
        let selected = offsets.compactMap { recordings.indices.contains($0) ? recordings[$0] : nil }
        for url in selected {
            if url.pathExtension == "caf" {
                deleteSpeechTest(id: url.deletingPathExtension().lastPathComponent)
                continue
            }
            do {
                if playingURL == url { stopPlayback() }
                try FileManager.default.removeItem(at: url)
                measurements.removeValue(forKey: url.deletingPathExtension().lastPathComponent)
                recordingDetails.removeValue(forKey: url.deletingPathExtension().lastPathComponent)
                speechTests.removeValue(forKey: url.deletingPathExtension().lastPathComponent)
                fileQueue.removeAll { $0.id == url.deletingPathExtension().lastPathComponent }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        saveMeasurements()
        saveDetails()
        saveSpeechTests()
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
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["m4a", "caf"].contains($0.pathExtension) }
        var changed = false
        for url in files {
            let id = url.deletingPathExtension().lastPathComponent
            guard recordingDetails[id] == nil else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let receivedAt = (attributes?[.creationDate] as? Date)
                ?? (attributes?[.modificationDate] as? Date)
                ?? .distantPast
            let duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
            recordingDetails[id] = ReceivedRecordingDetails(
                receivedAt: receivedAt, durationSeconds: duration
            )
            changed = true
        }
        if changed { saveDetails() }
        recordings = files.sorted { left, right in
            let leftDate = recordingDetails[left.deletingPathExtension().lastPathComponent]?.receivedAt
                ?? .distantPast
            let rightDate = recordingDetails[right.deletingPathExtension().lastPathComponent]?.receivedAt
                ?? .distantPast
            return leftDate == rightDate
                ? left.lastPathComponent > right.lastPathComponent
                : leftDate > rightDate
        }
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
        guard let event = message["speechTestEvent"] as? String,
              let id = message["id"] as? String, UUID(uuidString: id) != nil else { return }
        if event == "start", let sampleRate = message["sampleRate"] as? Double {
            DispatchQueue.main.async {
                if let reason = self.beginLiveRecognition(
                    id: id, sampleRate: sampleRate,
                    ambientLevel: message["ambientDBFS"] as? Double) {
                    replyHandler(["ready": false, "reason": reason])
                } else {
                    replyHandler(["ready": true])
                }
            }
        } else if event == "chunk", let samples = message["samples"] as? Data {
            DispatchQueue.main.async { self.appendLiveSamples(samples, id: id) }
            replyHandler(["received": true])
        } else if event == "stop" {
            DispatchQueue.main.async { self.endLiveRecognition(id: id) }
            replyHandler(["received": true])
        } else if event == "cancel" {
            DispatchQueue.main.async { self.cancelLiveRecognition(id: id) }
            replyHandler(["received": true])
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The received temporary file disappears when this callback returns.
        guard let id = file.metadata?["recordingID"] as? String,
              UUID(uuidString: id) != nil else { return }
        let fileExtension = (file.metadata?["fileExtension"] as? String == "caf" ||
                             file.metadata?["speechMode"] != nil) ? "caf" : "m4a"
        if fileExtension == "caf", isDeletedSpeechTest(id) {
            session.transferUserInfo(["savedRecordingID": id])
            return
        }
        if fileExtension == "caf", file.metadata?["speechDataGeneration"] as? Int != 2 {
            session.transferUserInfo(["savedRecordingID": id])
            return
        }
        let destination = directory.appendingPathComponent(id).appendingPathExtension(fileExtension)
        do {
            let firstReceipt = !FileManager.default.fileExists(atPath: destination.path)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: file.fileURL, to: destination)
            }
            let receivedAt = Date()
            let duration = (try? AVAudioPlayer(contentsOf: destination).duration) ?? 0
            session.transferUserInfo(["savedRecordingID": id])
            DispatchQueue.main.async {
                if self.isDeletedSpeechTest(id) {
                    try? FileManager.default.removeItem(at: destination)
                    self.refreshRecordings()
                    return
                }
                if firstReceipt, let mode = file.metadata?["speechMode"] as? String {
                    if mode == "live" || mode == "both" { self.endLiveRecognition(id: id) }
                    if self.speechTests[id] == nil {
                        self.speechTests[id] = SpeechTestResult(
                            id: id, mode: mode,
                            startedAt: receivedAt, transcript: "",
                            status: mode == "after" ? "변환 중" : "실시간 결과 확인")
                    }
                    if var test = self.speechTests[id] {
                        test.ambientDBFS = file.metadata?["speechAmbientDBFS"] as? Double
                        test.liveStreamInterrupted = file.metadata?["speechStreamInterrupted"] as? Bool
                        if mode == "both" || mode == "after" {
                            test.fileStatus = "변환 대기 중"
                        }
                        self.speechTests[id] = test
                        self.saveSpeechTests()
                    }
                    if mode == "both" || mode == "after" {
                        self.enqueueTranscription(destination, id: id)
                    }
                }
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
              let bytes = userInfo["fileBytes"] as? Int,
              !isDeletedSpeechTest(id) else { return }
        DispatchQueue.main.async {
            self.measurements[id] = TransferMeasurement(
                elapsedSeconds: userInfo["elapsedSeconds"] as? Double,
                fileBytes: bytes
            )
            self.saveMeasurements()
        }
    }
}
