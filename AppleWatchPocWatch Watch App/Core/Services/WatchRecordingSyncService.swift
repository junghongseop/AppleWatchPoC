import AVFoundation
import Combine
import Foundation
import WatchConnectivity
import CoreMotion
import WatchKit

final class WatchRecordingSyncService: NSObject, ObservableObject, WCSessionDelegate, AVAudioRecorderDelegate {
    static let shared = WatchRecordingSyncService()
    @Published private(set) var contactlessRecording: ContactlessRecording?
    @Published private(set) var preparingContactless = false
    @Published var markerLabel = "커스텀 마커"
    @Published private(set) var motionStatus = "녹음 중 손목 모션 감지"
    private var lastRecordingError: Error?
    private let motion = CMMotionManager()
    private var markerDetector = MotionMarkerDetector()
    private var contactlessStartCancelled = false
    private var preparingRecording = false
    @Published private(set) var recordings: [URL] = []
    @Published private(set) var isRecording = false
    @Published private(set) var connectionState: WatchConnectionState = .checking
    @Published var errorMessage: String?
    @Published private(set) var speechTestMode: String?
    @Published private(set) var liveStreamInterrupted = false
    @Published private(set) var currentInputDBFS: Double?

    private static let startTimesKey = "recordingConnectedTransferStartTimesV2"
    private static let speechResetKey = "speechTestRecordingsResetV2"
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var speechEngine: AVAudioEngine?
    private var speechFile: AVAudioFile?
    private let speechQueue = DispatchQueue(label: "speech.test.audio")
    private var pendingSamples = Data()
    private var phoneLiveReady = false
    private var speechID: String?
    private var pendingStopID: String?
    private var monitorRequested = false
    private var monitorRecorder: AVAudioRecorder?
    private var monitorTimer: Timer?
    private var monitorURL: URL?
    private var isPreparingSpeechTest = false
    private var activeProbeID: UUID?
    private let directory: URL

    override init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            clearPreviousSpeechRecordingsIfNeeded()
            recoverContactlessRecordings()
            refreshRecordings()
        } catch {
            errorMessage = error.localizedDescription
        }
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        } else {
            connectionState = .unavailable
        }
    }

    private func clearPreviousSpeechRecordingsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.speechResetKey) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)
            for url in files where url.pathExtension == "caf" {
                try FileManager.default.removeItem(at: url)
            }
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where ["speechMode.", "speechNoise.", "speechDistance.",
                   "speechAmbientDBFS.", "speechStreamInterrupted."].contains(where: key.hasPrefix) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            UserDefaults.standard.set(true, forKey: Self.speechResetKey)
        } catch {
            errorMessage = "기존 시험 녹음을 삭제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func cancelPreviousSpeechTransfers(_ session: WCSession) {
        for transfer in session.outstandingFileTransfers
        where transfer.file.metadata?["speechMode"] != nil &&
              transfer.file.metadata?["speechDataGeneration"] as? Int != 2 {
            transfer.cancel()
        }
    }

    func startRecording() {
        guard !isRecording, speechTestMode == nil, !isPreparingSpeechTest, !preparingContactless, !preparingRecording else { return }
        preparingRecording = true
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparingRecording = false
                guard granted else {
                    self.errorMessage = "마이크 권한을 허용해 주세요."
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        lastRecordingError = nil
        stopMonitorRecorder()
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
            recorder.delegate = self
            self.recorder = recorder
            currentURL = url
            isRecording = true
            errorMessage = nil
        } catch {
            try? FileManager.default.removeItem(at: url)
            lastRecordingError = error
            errorMessage = error.localizedDescription
            if monitorRequested { beginMonitorRecorder() }
        }
    }

    func stopRecording(trigger: String = "워치 버튼") {
        guard isRecording else { return }
        if contactlessRecording != nil { contactlessRecording?.stopTrigger = trigger }
        finishContactless(reason: "사용자 요청")
        recorder?.stop()
        recorder = nil
        isRecording = false
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        refreshRecordings()
        queuePendingRecordings()
        if monitorRequested { beginMonitorRecorder() }
    }

    func startAmbientMonitoring() {
        monitorRequested = true
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.monitorRequested else { return }
                if granted {
                    self.beginMonitorRecorder()
                } else {
                    self.errorMessage = "마이크 권한을 허용해야 입력 레벨을 볼 수 있습니다."
                }
            }
        }
    }

    func stopAmbientMonitoring() {
        monitorRequested = false
        stopMonitorRecorder()
        currentInputDBFS = nil
        if !isRecording && speechTestMode == nil {
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    private func beginMonitorRecorder() {
        guard monitorRequested, monitorRecorder == nil, !isRecording,
              speechTestMode == nil, !isPreparingSpeechTest else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
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
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw NSError(domain: "AmbientMeter", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "마이크 입력 레벨을 시작할 수 없습니다."])
            }
            monitorRecorder = recorder
            monitorURL = url
            monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.monitorRecorder else { return }
                recorder.updateMeters()
                let reading = Double(recorder.averagePower(forChannel: 0))
                self.currentInputDBFS = self.currentInputDBFS.map { $0 * 0.7 + reading * 0.3 } ?? reading
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            errorMessage = error.localizedDescription
        }
    }

    private func stopMonitorRecorder() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        monitorRecorder?.stop()
        monitorRecorder = nil
        if let monitorURL { try? FileManager.default.removeItem(at: monitorURL) }
        monitorURL = nil
    }

    func startSpeechTest() {
        guard !isRecording, speechTestMode == nil, pendingStopID == nil,
              !isPreparingSpeechTest, !preparingContactless, !preparingRecording else { return }
        guard let ambientLevel = currentInputDBFS else {
            errorMessage = "마이크 입력 레벨을 확인한 뒤 녹음해 주세요."
            return
        }
        if connectionState != .reachable {
            errorMessage = "아이폰 앱을 열고 연결한 뒤 시작해 주세요."
            return
        }
        isPreparingSpeechTest = true
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.isPreparingSpeechTest = false
                    self.errorMessage = "마이크 권한을 허용해 주세요."
                    return
                }
                self.prepareSpeechTest(ambientLevel: ambientLevel)
            }
        }
    }

    private func prepareSpeechTest(ambientLevel: Double) {
        let id = UUID().uuidString
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            isPreparingSpeechTest = false
            errorMessage = "워치 마이크의 오디오 형식을 사용할 수 없습니다."
            return
        }
        guard beginSpeechCapture(id: id, engine: engine, format: format,
                                 ambientLevel: ambientLevel) else { return }
        WCSession.default.sendMessage([
            "speechTestEvent": "start", "id": id, "sampleRate": format.sampleRate,
            "ambientDBFS": ambientLevel
        ], replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                guard let self else { return }
                if reply["ready"] as? Bool == true {
                    let stopped = self.pendingStopID == id
                    guard self.speechID == id || stopped else { return }
                    if stopped { self.pendingStopID = nil }
                    self.speechQueue.async {
                        self.phoneLiveReady = true
                        self.drainSpeechSamples(id: id,
                            chunkBytes: Int(format.sampleRate * 0.25) * MemoryLayout<Float>.size)
                        if stopped { self.finishLiveStream(id: id) }
                    }
                } else {
                    self.abortSpeechTest(id: id, message: reply["reason"] as? String
                                         ?? "아이폰에서 음성 인식을 시작할 수 없습니다.")
                }
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                self?.abortSpeechTest(id: id, message: error.localizedDescription)
            }
        })
    }

    @discardableResult
    private func beginSpeechCapture(id: String, engine: AVAudioEngine, format: AVAudioFormat,
                                    ambientLevel: Double) -> Bool {
        let url = directory.appendingPathComponent(id).appendingPathExtension("caf")
        stopMonitorRecorder()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            speechQueue.sync {
                pendingSamples.removeAll(keepingCapacity: true)
                phoneLiveReady = false
            }
            liveStreamInterrupted = false
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                do { try file.write(from: buffer) }
                catch {
                    DispatchQueue.main.async { self?.errorMessage = error.localizedDescription }
                }
                guard let channel = buffer.floatChannelData?.pointee else { return }
                let data = Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
                guard !data.isEmpty else { return }
                self?.speechQueue.async { [weak self] in
                    guard let self else { return }
                    var sum = 0.0
                    data.withUnsafeBytes { bytes in
                        for sample in bytes.bindMemory(to: Float.self) {
                            let value = Double(sample)
                            sum += value * value
                        }
                    }
                    let currentLevel = 20 * log10(max(sqrt(sum / Double(data.count / MemoryLayout<Float>.size)), 0.000_001))
                    DispatchQueue.main.async {
                        self.currentInputDBFS = self.currentInputDBFS.map { $0 * 0.7 + currentLevel * 0.3 }
                            ?? currentLevel
                    }
                    self.pendingSamples.append(data)
                    if self.phoneLiveReady {
                        self.drainSpeechSamples(id: id,
                            chunkBytes: Int(format.sampleRate * 0.25) * MemoryLayout<Float>.size)
                    }
                }
            }
            try engine.start()
            speechEngine = engine
            speechFile = file
            speechID = id
            speechTestMode = "both"
            isPreparingSpeechTest = false
            currentURL = url
            UserDefaults.standard.set("both", forKey: "speechMode.\(id)")
            UserDefaults.standard.set(ambientLevel, forKey: "speechAmbientDBFS.\(id)")
            errorMessage = nil
            return true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: url)
            try? AVAudioSession.sharedInstance().setActive(false)
            errorMessage = error.localizedDescription
            isPreparingSpeechTest = false
            if monitorRequested { beginMonitorRecorder() }
            return false
        }
    }

    private func drainSpeechSamples(id: String, chunkBytes: Int) {
        while pendingSamples.count >= chunkBytes {
            let chunk = pendingSamples.prefix(chunkBytes)
            pendingSamples.removeFirst(chunkBytes)
            sendSpeechChunk(Data(chunk), id: id)
        }
    }

    private func sendSpeechChunk(_ data: Data, id: String) {
        guard WCSession.default.isReachable else {
            markStreamInterrupted(id: id)
            return
        }
        WCSession.default.sendMessage(["speechTestEvent": "chunk", "id": id, "samples": data],
                                      replyHandler: { _ in }, errorHandler: { [weak self] _ in
            self?.markStreamInterrupted(id: id)
        })
    }

    private func markStreamInterrupted(id: String) {
        UserDefaults.standard.set(true, forKey: "speechStreamInterrupted.\(id)")
        DispatchQueue.main.async { self.liveStreamInterrupted = true }
    }

    private func abortSpeechTest(id: String, message: String) {
        guard speechID == id || pendingStopID == id else { return }
        speechEngine?.inputNode.removeTap(onBus: 0)
        speechEngine?.stop()
        speechEngine = nil
        speechFile = nil
        speechID = nil
        pendingStopID = nil
        speechTestMode = nil
        let url = currentURL ?? directory.appendingPathComponent(id).appendingPathExtension("caf")
        currentURL = nil
        speechQueue.sync {
            pendingSamples.removeAll()
            phoneLiveReady = false
        }
        try? FileManager.default.removeItem(at: url)
        UserDefaults.standard.removeObject(forKey: "speechMode.\(id)")
        UserDefaults.standard.removeObject(forKey: "speechAmbientDBFS.\(id)")
        try? AVAudioSession.sharedInstance().setActive(false)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["speechTestEvent": "cancel", "id": id],
                                          replyHandler: { _ in }, errorHandler: nil)
        }
        if monitorRequested { beginMonitorRecorder() }
        refreshRecordings()
        errorMessage = message
    }

    private func finishLiveStream(id: String) {
        if phoneLiveReady && !pendingSamples.isEmpty {
            sendSpeechChunk(pendingSamples, id: id)
        } else if !phoneLiveReady {
            markStreamInterrupted(id: id)
        }
        pendingSamples.removeAll()
        phoneLiveReady = false
        WCSession.default.sendMessage(["speechTestEvent": "stop", "id": id],
                                      replyHandler: { [weak self] _ in
            DispatchQueue.main.async { self?.queuePendingRecordings() }
        }, errorHandler: { [weak self] _ in
            self?.markStreamInterrupted(id: id)
            DispatchQueue.main.async { self?.queuePendingRecordings() }
        })
    }

    func stopSpeechTest() {
        guard let id = speechID, speechTestMode != nil else { return }
        speechEngine?.inputNode.removeTap(onBus: 0)
        speechEngine?.stop()
        speechEngine = nil
        speechFile = nil
        speechID = nil
        speechTestMode = nil
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        let ready = speechQueue.sync { phoneLiveReady }
        if ready {
            speechQueue.async { [weak self] in self?.finishLiveStream(id: id) }
        } else {
            pendingStopID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.pendingStopID == id else { return }
                self.pendingStopID = nil
                self.speechQueue.async { self.finishLiveStream(id: id) }
            }
        }
        refreshRecordings()
        if monitorRequested { beginMonitorRecorder() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.queuePendingRecordings()
        }
    }

    func queuePendingRecordings() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        let queued = Set(session.outstandingFileTransfers.compactMap {
            $0.file.metadata?["recordingID"] as? String
        })
        for url in recordings where url != currentURL {
            if url.deletingPathExtension().lastPathComponent == pendingStopID { continue }
            if url.pathExtension == "caf" && !UserDefaults.standard.bool(forKey: Self.speechResetKey) {
                continue
            }
            let id = url.deletingPathExtension().lastPathComponent
            guard !queued.contains(id) else { continue }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if connectionState == .reachable { markConnected(at: Date(), for: [id]) }
            var metadata: [String: Any] = ["recordingID": id, "fileBytes": bytes,
                                            "fileExtension": url.pathExtension]
            if let data = try? Data(contentsOf: contactlessURL(for: url)) {
                metadata["contactlessRecording"] = data
            }
            if url.pathExtension == "caf" {
                metadata["speechMode"] = UserDefaults.standard.string(forKey: "speechMode.\(id)") ?? "after"
                metadata["speechDataGeneration"] = 2
                if let level = UserDefaults.standard.object(forKey: "speechAmbientDBFS.\(id)") as? Double {
                    metadata["speechAmbientDBFS"] = level
                }
                metadata["speechStreamInterrupted"] = UserDefaults.standard.bool(forKey: "speechStreamInterrupted.\(id)")
            }
            session.transferFile(url, metadata: metadata)
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
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["m4a", "caf"].contains($0.pathExtension) && $0 != currentURL }
        let datedFiles = files.map { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return (url: url, date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast)
        }
        recordings = datedFiles.sorted { left, right in
            left.date == right.date
                ? left.url.lastPathComponent > right.url.lastPathComponent
                : left.date > right.date
        }.map(\.url)
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
                self.cancelPreviousSpeechTransfers(session)
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
            let m4a = self.directory.appendingPathComponent(id).appendingPathExtension("m4a")
            let caf = self.directory.appendingPathComponent(id).appendingPathExtension("caf")
            let url = FileManager.default.fileExists(atPath: caf.path) ? caf : m4a
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    try? FileManager.default.removeItem(at: self.contactlessURL(for: url))
                }
                self.refreshRecordings()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}


extension WatchRecordingSyncService {
    @MainActor
    func startContactless(trigger: String) async throws {
        if contactlessRecording != nil { return }
        guard !isRecording, speechTestMode == nil, !isPreparingSpeechTest,
              !preparingRecording, !preparingContactless else {
            throw contactlessError("다른 녹음이 진행 중입니다.")
        }
        preparingContactless = true
        contactlessStartCancelled = false
        defer { preparingContactless = false }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard !contactlessStartCancelled else { return }
        guard granted else { throw contactlessError("워치 앱에서 마이크 권한을 허용해 주세요.") }
        beginRecording()
        guard isRecording else { throw lastRecordingError ?? contactlessError(errorMessage ?? "녹음 시작 실패") }
        contactlessRecording = ContactlessRecording(startedAt: Date(), trigger: trigger,
            executionMode: "foreground",
            startApplicationState: currentApplicationState)
        persistContactless()
        markerDetector = MotionMarkerDetector()
        startMotionMarkers()
        WKInterfaceDevice.current().play(.start)
    }

    func stopContactless(trigger: String = "워치 버튼") {
        if preparingContactless { contactlessStartCancelled = true }
        guard contactlessRecording != nil else { return }
        stopRecording(trigger: trigger)
        WKInterfaceDevice.current().play(.stop)
    }

    var currentApplicationState: String {
        switch WKApplication.shared().applicationState {
        case .active: return "전면"
        case .inactive: return "비활성"
        case .background: return "백그라운드"
        @unknown default: return "알 수 없음"
        }
    }

    private func contactlessError(_ message: String) -> NSError {
        NSError(domain: "Contactless", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func contactlessURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("contactless.json")
    }

    private func persistContactless() {
        guard let currentURL, let contactlessRecording else { return }
        do {
            try JSONEncoder().encode(contactlessRecording).write(to: contactlessURL(for: currentURL), options: .atomic)
        } catch { errorMessage = "마커 저장 실패: \(error.localizedDescription)" }
    }

    private func startMotionMarkers() {
        guard motion.isDeviceMotionAvailable else {
            motionStatus = "이 기기에서 손목 모션을 사용할 수 없습니다."
            return
        }
        motionStatus = "손목 흔들기 감지 중"
        motion.deviceMotionUpdateInterval = 1.0 / 25
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
            guard let self else { return }
            if let error {
                self.motionStatus = "모션 오류: \(error.localizedDescription)"
                self.motion.stopDeviceMotionUpdates()
                return
            }
            guard let sample, let recorder = self.recorder, self.contactlessRecording != nil else { return }
            let a = sample.userAcceleration
            let r = sample.rotationRate
            let acceleration = sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
            let rotation = sqrt(r.x*r.x + r.y*r.y + r.z*r.z)
            let offset = recorder.currentTime
            guard self.markerDetector.detect(acceleration: acceleration, rotation: rotation, time: offset) else { return }
            let label = self.markerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            self.contactlessRecording?.markers.append(MotionMarker(id: UUID(), offset: offset,
                label: label.isEmpty ? "커스텀 마커" : String(label.prefix(80))))
            self.persistContactless()
            WKInterfaceDevice.current().play(.click)
        }
    }

    private func finishContactless(reason: String) {
        guard contactlessRecording != nil else { return }
        motion.stopDeviceMotionUpdates()
        contactlessRecording?.endedAt = Date()
        contactlessRecording?.endReason = reason
        persistContactless()
        contactlessRecording = nil
        motionStatus = "녹음 중 손목 모션 감지"
    }

    private func recoverContactlessRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for audio in files where audio.pathExtension == "m4a" {
            let sidecar = contactlessURL(for: audio)
            guard let data = try? Data(contentsOf: sidecar),
                  var record = try? JSONDecoder().decode(ContactlessRecording.self, from: data),
                  record.endedAt == nil else { continue }
            let duration = (try? AVAudioPlayer(contentsOf: audio).duration) ?? 0
            record.endedAt = record.startedAt.addingTimeInterval(duration)
            record.endReason = "앱 종료 후 복구 (종료 시각은 파일 길이로 추정)"
            record.markers = record.markers.filter { $0.offset <= duration }
            try? JSONEncoder().encode(record).write(to: sidecar, options: .atomic)
        }
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        DispatchQueue.main.async {
            if self.contactlessRecording != nil {
                self.finishContactless(reason: "오디오 인터럽트")
                self.stopRecording()
                self.errorMessage = "오디오 인터럽트로 녹음이 종료되었습니다."
            }
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard recorder === self.recorder, isRecording else { return }
        finishContactless(reason: flag ? "시스템 종료" : "녹음 오류")
        stopRecording()
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard recorder === self.recorder else { return }
        finishContactless(reason: "인코딩 오류")
        stopRecording()
        errorMessage = error?.localizedDescription ?? "녹음 인코딩 오류"
    }
}
