import AVFoundation
import Foundation
import ImageIO
import Vision

nonisolated struct HandCaptureState: Sendable {
    var statusMessage = "카메라 시작 대기"
    var ready = false
    var cameraActive = false
    var microphoneAvailable = false
    var recording: HandRecordingKind?
    var startedAt: Date?
    var saving = false
    var preparation: HandCapturePreparation?
    var photoCountdown: Int?
    var photoInFlight = false
}

nonisolated enum HandCaptureEvent: Sendable {
    case state(HandCaptureState)
    case tracking(HandGesture?, Double, String)
    case saved(URL)
    case error(String)
}

/// All mutable capture/writer state is confined to `queue`. Vision runs on a separate
/// serial queue with at most one frame in flight. Session/connection writes never run on UI.
nonisolated final class HandCaptureEngine: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var previewVisible = true
    private var previewAngle: CGFloat = 90
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservers: [NSKeyValueObservation] = []
    private var rotationRevision = UUID()
    private let queue = DispatchQueue(label: "hand.capture", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let visionQueue = DispatchQueue(label: "hand.vision", qos: .utility, autoreleaseFrequency: .workItem)
    // Accessed only on visionQueue; reuse the request/model across frames.
    private var handRequest: VNDetectHumanHandPoseRequest?
    private let onEvent: @Sendable (HandCaptureEvent) -> Void
    private let directory: URL
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var configured = false
    private var configuredCamera = false
    private var wantsRunning = false
    private var pendingStart: (camera: Bool, microphone: Bool)?
    private var audioInput: AVCaptureDeviceInput?
    private var cameraDevice: AVCaptureDevice?
    private var ownsAudioSession = false
    private var observers: [NSObjectProtocol] = []
    private var state = HandCaptureState()
    private var gate = HandGestureGate()
    private var visionInFlight = false
    private var lastVisionTime: TimeInterval = 0
    private var generation = 0
    private var angle: CGFloat = 90
    private var recordingFPS: Int32 = 30
    private var writer: AVAssetWriter?
    private var finishingWriter: AVAssetWriter?
    private var writerAudio: AVAssetWriterInput.SampleBufferReceiver?
    private var writerVideo: AVAssetWriterInput.SampleBufferReceiver?
    private var writerStart: CMTime?
    private var hasAudio = false
    private var hasVideo = false
    private var photoDelegate: HandPhotoDelegate?

    init(directory: URL, onEvent: @escaping @Sendable (HandCaptureEvent) -> Void) {
        self.directory = directory
        self.onEvent = onEvent
        super.init()
        for name in [AVCaptureSession.didStartRunningNotification, AVCaptureSession.didStopRunningNotification,
                     AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard self.wantsRunning else { return }
                    // Notifications can arrive after a stop/restart. Read current state,
                    // rather than treating an old interruption as a new stop request.
                    if self.session.isInterrupted {
                        self.cancelPreparation()
                        self.finishRecording()
                        self.generation += 1
                        self.gate = HandGestureGate()
                    } else if name == AVCaptureSession.interruptionEndedNotification, !self.session.isRunning,
                              self.configuredCamera || self.audioInput != nil {
                        self.session.startRunning()
                    }
                    self.synchronizeSessionState()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let description = error?.localizedDescription ?? "알 수 없는 카메라 오류"
            guard let self else { return }
            self.queue.async {
                guard self.wantsRunning else { return }
                self.stopSession()
                self.state.statusMessage = "카메라 시작 실패 · 다시 시작해 주세요"
                self.publishState()
                self.onEvent(.error(description))
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: nil) { [weak self] notification in
            // Camera toggles deliberately deactivate/reconfigure audio. A delayed app
            // deactivation notification must not shut down the newly started session.
            guard let context = notification.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                  context.source == .system, let self else { return }
            self.queue.async {
                guard self.wantsRunning, self.ownsAudioSession, self.state.recording != nil else { return }
                self.stopSession()
                self.onEvent(.error("오디오 인터럽트로 기록을 종료했습니다. 카메라 다시 시작을 눌러 주세요."))
            }
        })
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    // Do not change the format of a recording or an in-flight photo.
                    if self.wantsRunning, self.state.recording != .video, !self.state.photoInFlight,
                       self.state.preparation == nil {
                        self.restoreTrackingProfile()
                    }
                }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start(cameraEnabled: Bool, microphoneAllowed: Bool) {
        queue.async { self.startSession(cameraEnabled: cameraEnabled, microphoneAllowed: microphoneAllowed) }
    }

    private func startSession(cameraEnabled: Bool, microphoneAllowed: Bool) {
        guard self.state.recording == nil, self.state.preparation == nil else { return }
        if self.state.saving {
            self.pendingStart = (cameraEnabled, microphoneAllowed)
            return
        }
        self.pendingStart = nil
        if self.wantsRunning {
            if self.configuredCamera == cameraEnabled && self.state.microphoneAvailable == microphoneAllowed,
               self.state.ready {
                self.synchronizeSessionState()
                return
            }
            self.stopSession()
        }
        self.wantsRunning = true
        self.state.statusMessage = "기록 장치 시작 중…"
        self.publishState()
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if !self.configured || self.configuredCamera != cameraEnabled { try self.configure(cameraEnabled: cameraEnabled) }
            self.state.microphoneAvailable = microphoneAllowed
            self.videoOutput.setSampleBufferDelegate(self, queue: self.queue)
            if cameraEnabled { try self.applyCaptureProfile(visualCapture: false) }
            self.generation += 1
            self.gate = HandGestureGate()
            // Audio-only standby does not need a running capture session.
            if cameraEnabled { self.session.startRunning() }
            self.synchronizeSessionState()
            self.onEvent(.tracking(nil, 0, cameraEnabled ? "손 전체가 보이도록 한 손을 보여 주세요." : "카메라 꺼짐 · 음성 버튼으로 녹음할 수 있습니다."))
            if !self.state.ready && !self.session.isInterrupted { throw CaptureFailure("기록 장치를 시작할 수 없습니다. 다른 카메라·녹음 앱을 닫고 다시 시도하세요.") }
        } catch {
            self.stopSession()
            self.state.statusMessage = "기록 장치 시작 실패 · 다시 시작해 주세요"
            self.publishState()
            self.onEvent(.error(error.localizedDescription))
        }
    }

    func stop() { queue.async { self.stopSession() } }

    func perform(_ action: HandGesture) {
        queue.async { self.execute(action) }
    }

    func previewDidBecomeVisible(for id: UUID) {
        queue.async {
            guard self.state.ready, self.state.cameraActive,
                  self.state.preparation?.id == id,
                  self.state.preparation?.previewVisibleAt == nil else { return }
            self.state.preparation?.acknowledgePreview(id: id, at: ProcessInfo.processInfo.systemUptime)
            self.advancePreparation(id: id)
        }
    }

    func connectPreview(_ target: HandPreviewTarget, visible: Bool) {
        queue.async {
            let changed = self.previewVisible != visible
            self.previewVisible = visible
            if self.previewLayer !== target.layer {
                self.previewLayer?.session = nil
                self.previewLayer = target.layer
                target.layer.session = self.session
                self.configureRotationCoordinator()
            }
            self.updatePreviewConnection()
            if changed, self.state.recording != .video, self.state.preparation == nil, !self.state.photoInFlight {
                self.restoreTrackingProfile()
            }
        }
    }

    func disconnectPreview(_ target: HandPreviewTarget) {
        queue.async {
            guard self.previewLayer === target.layer else { return }
            self.rotationRevision = UUID()
            self.rotationObservers.removeAll()
            self.rotationCoordinator = nil
            target.layer.session = nil
            self.previewLayer = nil
        }
    }

    private func configureRotationCoordinator() {
        let revision = UUID()
        rotationRevision = revision
        rotationObservers.removeAll()
        rotationCoordinator = nil
        guard let cameraDevice, let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: cameraDevice, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservers = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                self.queue.async {
                    guard self.rotationRevision == revision else { return }
                    self.previewAngle = angle
                    self.updatePreviewConnection()
                }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                self.queue.async {
                    guard self.rotationRevision == revision, self.angle != angle else { return }
                    self.angle = angle
                    self.generation += 1
                    self.gate = HandGestureGate()
                    if self.writer == nil { self.applyVideoRotation() }
                }
            }
        ]
    }

    private func updatePreviewConnection() {
        guard let connection = previewLayer?.connection else { return }
        if connection.isEnabled != previewVisible { connection.isEnabled = previewVisible }
        if connection.videoRotationAngle != previewAngle, connection.isVideoRotationAngleSupported(previewAngle) {
            connection.videoRotationAngle = previewAngle
        }
        if connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
            if !connection.isVideoMirrored { connection.isVideoMirrored = true }
        }
    }

    private func synchronizeSessionState() {
        guard wantsRunning else { return }
        state.cameraActive = configuredCamera && session.isRunning && !session.isInterrupted
        state.ready = !session.isInterrupted && (configuredCamera ? state.cameraActive : state.microphoneAvailable)
        state.statusMessage = session.isInterrupted ? "카메라·마이크 일시 중단 · 자동 복귀 대기"
            : state.ready ? "기록 준비 완료" : "기록 장치 중지 · 다시 시작해 주세요"
        publishState()
    }

    private func configure(cameraEnabled: Bool) throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            configureRotationCoordinator()
            updatePreviewConnection()
        }
        configured = false
        // Rebuild cleanly if a previous setup attempt failed halfway through.
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        audioInput = nil
        cameraDevice = nil
        session.automaticallyConfiguresApplicationAudioSession = false
        configuredCamera = cameraEnabled
        guard cameraEnabled else {
            // Removing the camera input really turns off video capture, not just its preview.
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            configured = true
            return
        }
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw CaptureFailure("전면 카메라를 사용할 수 없습니다. 실제 iPhone에서 실행해 주세요.")
        }
        let input = try AVCaptureDeviceInput(device: camera)
        cameraDevice = camera
        guard session.canAddInput(input) else { throw CaptureFailure("전면 카메라를 연결할 수 없습니다.") }
        session.addInput(input)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        guard session.canAddOutput(videoOutput) else { throw CaptureFailure("손 추적 영상 출력을 구성할 수 없습니다.") }
        session.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(photoOutput) else { throw CaptureFailure("사진 출력을 구성할 수 없습니다.") }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .balanced
        applyVideoRotation()
        configured = true
    }

    private func configureAudio() throws {
        guard audioInput == nil else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try audioSession.setActive(true)
        ownsAudioSession = true
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw CaptureFailure("마이크를 찾을 수 없습니다.")
        }
        let input = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(input) else { throw CaptureFailure("마이크를 연결할 수 없습니다.") }
        session.addInput(input)
        audioInput = input
        guard session.canAddOutput(audioOutput) else { throw CaptureFailure("오디오 출력을 구성할 수 없습니다.") }
        session.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
    }

    private func disconnectAudio() {
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        if audioInput != nil || session.outputs.contains(audioOutput) {
            session.beginConfiguration()
            if let audioInput { session.removeInput(audioInput) }
            audioInput = nil
            if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
            session.commitConfiguration()
        }
        if !configuredCamera, session.isRunning { session.stopRunning() }
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    private var isResourceConstrained: Bool {
        let process = ProcessInfo.processInfo
        return process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical
    }

    private func applyCaptureProfile(visualCapture: Bool, recordingVideo: Bool = false) throws {
        guard let cameraDevice else { return }
        if recordingVideo {
            try applyVideoRecordingProfile(cameraDevice)
            return
        }
        let budget = HandCaptureBudget(visualCapture: visualCapture, constrained: isResourceConstrained, previewVisible: previewVisible)
        let preset: AVCaptureSession.Preset = visualCapture ? .hd1280x720 : .vga640x480
        if session.sessionPreset != preset, session.canSetSessionPreset(preset) {
            session.beginConfiguration()
            session.sessionPreset = preset
            session.commitConfiguration()
            // Ignore any Vision result from the previous format; preserve the gesture latch.
            generation += 1
        }
        let fps = Double(budget.cameraFPS)
        guard cameraDevice.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= fps && fps <= $0.maxFrameRate
        }) else { return }
        let duration = CMTime(value: 1, timescale: budget.cameraFPS)
        if cameraDevice.activeVideoMinFrameDuration != duration || cameraDevice.activeVideoMaxFrameDuration != duration {
            try cameraDevice.lockForConfiguration()
            defer { cameraDevice.unlockForConfiguration() }
            cameraDevice.activeVideoMinFrameDuration = duration
            cameraDevice.activeVideoMaxFrameDuration = duration
        }
        applyVideoRotation()
        updatePreviewConnection()
    }

    private func applyVideoRecordingProfile(_ device: AVCaptureDevice) throws {
        let formats = device.formats.filter {
            let subtype = CMFormatDescriptionGetMediaSubType($0.formatDescription)
            return subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let options = formats.map { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return HandVideoFormat(width: size.width, height: size.height,
                                   frameRates: format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate })
        }
        guard let selection = HandVideoFormat.select(from: options) else {
            throw CaptureFailure("이 카메라에서 30fps 이상 HD 녹화 포맷을 찾지 못했습니다.")
        }
        let format = formats[selection.index]
        let duration = CMTime(value: 1, timescale: selection.fps)
        if device.activeFormat !== format || device.activeVideoMinFrameDuration != duration
            || device.activeVideoMaxFrameDuration != duration || device.isAutoVideoFrameRateEnabled {
            // Format and frame durations must be committed together. Selecting the
            // active format puts the session in inputPriority, preserving 60fps.
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isAutoVideoFrameRateEnabled { device.isAutoVideoFrameRateEnabled = false }
            device.activeFormat = format
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            generation += 1
        }
        recordingFPS = selection.fps
        applyVideoRotation()
        updatePreviewConnection()
    }

    private func restoreTrackingProfile() {
        guard wantsRunning, configuredCamera else { return }
        do { try applyCaptureProfile(visualCapture: false) }
        catch { onEvent(.error("절전 카메라 설정을 적용하지 못했습니다: \(error.localizedDescription)")) }
    }

    private func stopSession() {
        pendingStart = nil
        wantsRunning = false
        generation += 1
        gate = HandGestureGate()
        cancelPreparation()
        finishRecording()
        if session.isRunning { session.stopRunning() }
        disconnectAudio()
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        visionQueue.async { [self] in handRequest = nil }
        releaseCaptureGraphIfIdle()
        state.microphoneAvailable = false
        state.ready = false
        state.cameraActive = false
        state.statusMessage = "기록 장치 일시 정지"
        publishState()
        onEvent(.tracking(nil, 0, "카메라가 일시 정지되었습니다."))
    }

    private func releaseCaptureGraphIfIdle() {
        // A photo's delegate must finish before its output can be disconnected.
        guard !wantsRunning, !state.photoInFlight else { return }
        session.beginConfiguration()
        session.outputs.forEach(session.removeOutput)
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
        rotationRevision = UUID()
        rotationObservers.removeAll()
        rotationCoordinator = nil
        cameraDevice = nil
        configured = false
        configuredCamera = false
    }

    private func applyVideoRotation() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.videoRotationAngle != angle, connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        if connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
            if !connection.isVideoMirrored { connection.isVideoMirrored = true }
        }
    }

    private func execute(_ action: HandGesture) {
        if action == .stop {
            cancelPreparation()
            finishRecording()
            return
        }
        guard state.ready, !state.saving, state.recording == nil, state.preparation == nil else { return }
        guard state.cameraActive || action == .voice else {
            onEvent(.error("사진·영상은 핸드트래킹 카메라를 켠 후 사용할 수 있습니다."))
            return
        }
        do {
            switch action {
            case .voice: try beginRecording(.voice)
            case .video:
                guard state.microphoneAvailable else { throw CaptureFailure("영상 기록에는 마이크 권한이 필요합니다.") }
                try prepareVisualCapture(.video)
            case .photo: try prepareVisualCapture(.photo)
            case .stop: break
            }
        } catch {
            disconnectAudio()
            restoreTrackingProfile()
            onEvent(.error(error.localizedDescription))
        }
    }

    private func prepareVisualCapture(_ kind: HandRecordingKind) throws {
        try applyCaptureProfile(visualCapture: true, recordingVideo: kind == .video)
        let preparation = HandCapturePreparation(kind: kind)
        state.preparation = preparation
        publishState() // The view expands and starts the preview before acknowledging.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.state.preparation?.id == preparation.id,
                  self.state.preparation?.previewVisibleAt == nil else { return }
            self.cancelPreparation()
            self.onEvent(.error("카메라 미리보기를 표시하지 못해 촬영을 취소했습니다. 다시 시도해 주세요."))
        }
    }

    private func advancePreparation(id: UUID) {
        guard state.ready, state.cameraActive, let preparation = state.preparation,
              preparation.id == id else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if preparation.canCapture(at: now) {
            state.preparation = nil
            state.photoCountdown = nil
            do {
                if preparation.kind == .photo { takePhoto() }
                else { try beginRecording(.video) }
            } catch {
                disconnectAudio()
                restoreTrackingProfile()
                publishState()
                onEvent(.error(error.localizedDescription))
            }
        } else if let remaining = preparation.secondsRemaining(at: now) {
            if state.photoCountdown != remaining {
                state.photoCountdown = remaining
                publishState()
            }
            // A monotonic deadline prevents early capture even if timer delivery jitters.
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.advancePreparation(id: id) }
        }
    }

    private func cancelPreparation() {
        guard state.preparation != nil else { return }
        state.preparation = nil
        state.photoCountdown = nil
        restoreTrackingProfile()
        publishState()
    }

    private func beginRecording(_ kind: HandRecordingKind) throws {
        guard state.microphoneAvailable else {
            throw CaptureFailure("음성·영상 기록에는 마이크 권한이 필요합니다. 설정에서 마이크 접근을 허용해 주세요. 사진은 촬영할 수 있습니다.")
        }
        try configureAudio()
        try applyCaptureProfile(visualCapture: kind == .video, recordingVideo: kind == .video)
        if !session.isRunning { session.startRunning() }
        // Unfinished files never appear in the saved-recordings list after a crash.
        let staging = directory.appendingPathComponent("Pending", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let url = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension(kind.fileExtension)
        let newWriter = try AVAssetWriter(outputURL: url, fileType: kind == .voice ? .m4a : .mov)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96000
        ])
        guard newWriter.canAdd(audio) else { throw CaptureFailure("녹음 파일을 구성할 수 없습니다.") }
        let audioReceiver = newWriter.inputReceiver(for: audio)
        var video: AVAssetWriterInput.SampleBufferReceiver?
        if kind == .video {
            guard var settings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov) else {
                throw CaptureFailure("영상 저장 설정을 가져오지 못했습니다.")
            }
            var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            compression[AVVideoExpectedSourceFrameRateKey] = recordingFPS
            compression[AVVideoAllowFrameReorderingKey] = false
            compression[AVVideoMaxKeyFrameIntervalKey] = recordingFPS * 2
            let width = (settings[AVVideoWidthKey] as? NSNumber)?.intValue ?? 1280
            let height = (settings[AVVideoHeightKey] as? NSNumber)?.intValue ?? 720
            compression[AVVideoAverageBitRateKey] = max(4_000_000, width * height * Int(recordingFPS) / 10)
            settings[AVVideoCompressionPropertiesKey] = compression
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            guard newWriter.canAdd(input) else { throw CaptureFailure("영상 파일을 구성할 수 없습니다.") }
            video = newWriter.inputReceiver(for: input)
        }
        do { try newWriter.start() } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        writer = newWriter
        writerAudio = audioReceiver
        writerVideo = video
        writerStart = nil
        hasAudio = false
        hasVideo = false
        state.recording = kind
        state.startedAt = nil // Set when the first media sample actually arrives.
        publishState()
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.writer?.outputURL == url else { return }
            if !self.hasAudio || (kind == .video && !self.hasVideo) {
                self.failRecording("카메라 또는 마이크에서 기록 데이터를 받지 못했습니다. 다시 시작해 주세요.")
            }
        }
    }

    private func append(_ sample: CMSampleBuffer, isVideo: Bool) {
        guard let writer, CMSampleBufferDataIsReady(sample) else { return }
        guard !isVideo || writerVideo != nil else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if writerStart == nil {
            // A movie's timeline begins on its first video frame; earlier audio is dropped.
            if writerVideo != nil && !isVideo { return }
            writer.startSession(atSourceTime: time)
            writerStart = time
            state.startedAt = Date()
            publishState()
        }
        guard let writerStart, CMTimeCompare(time, writerStart) >= 0 else { return }
        let input = isVideo ? writerVideo : writerAudio
        if writer.status == .failed {
            failRecording(writer.error?.localizedDescription ?? "기록 저장 중 오류가 발생했습니다.")
        } else if let input {
            do {
                // Copy sample metadata; the media payload stays read-only and is shared.
                let readySample = CMReadySampleBuffer(unsafeBuffer: try CMSampleBuffer(copying: sample))
                if try input.appendImmediately(readySample) {
                    if isVideo { hasVideo = true } else { hasAudio = true }
                } // Back pressure drops this sample without blocking the capture queue.
            } catch { failRecording(error.localizedDescription) }
        }
    }

    private func finishRecording() {
        guard let finishingWriter = writer else { return }
        guard writerStart != nil, hasAudio, writerVideo == nil || hasVideo else {
            failRecording("기록이 너무 짧거나 입력이 없어 저장하지 못했습니다.")
            return
        }
        writerAudio?.finish()
        writerVideo?.finish()
        self.finishingWriter = finishingWriter
        clearWriter()
        state.saving = true
        publishState()
        finishingWriter.finishWriting { [self] in
            queue.async {
                guard let finishingWriter = self.finishingWriter else { return }
                self.finishingWriter = nil
                defer { self.resumePendingStart() }
                self.state.saving = false
                self.publishState()
                if finishingWriter.status == .completed {
                    do {
                        let destination = self.directory.appendingPathComponent(finishingWriter.outputURL.lastPathComponent)
                        try FileManager.default.moveItem(at: finishingWriter.outputURL, to: destination)
                        self.onEvent(.saved(destination))
                    } catch {
                        self.onEvent(.error("완료된 기록을 저장 목록으로 옮기지 못했습니다: \(error.localizedDescription)"))
                    }
                } else {
                    try? FileManager.default.removeItem(at: finishingWriter.outputURL)
                    self.onEvent(.error(finishingWriter.error?.localizedDescription ?? "기록을 마무리하지 못했습니다."))
                }
            }
        }
    }

    private func failRecording(_ message: String) {
        if let writer {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
        }
        clearWriter()
        publishState()
        onEvent(.error(message))
    }

    private func clearWriter() {
        writer = nil
        writerAudio = nil
        writerVideo = nil
        writerStart = nil
        state.recording = nil
        state.startedAt = nil
        applyVideoRotation()
        disconnectAudio()
        restoreTrackingProfile()
    }

    private func takePhoto() {
        guard photoDelegate == nil else { return }
        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        state.saving = true
        state.photoInFlight = true
        publishState()
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let delegate = HandPhotoDelegate { [self] result in
            queue.async {
                defer {
                    self.photoDelegate = nil
                    self.state.saving = false
                    self.state.photoInFlight = false
                    self.restoreTrackingProfile()
                    self.releaseCaptureGraphIfIdle()
                    self.publishState()
                    self.resumePendingStart()
                }
                do {
                    let data = try result.get()
                    try data.write(to: url, options: .atomic)
                    self.onEvent(.saved(url))
                } catch { self.onEvent(.error("사진 저장 실패: \(error.localizedDescription)")) }
            }
        }
        photoDelegate = delegate
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.photoQualityPrioritization = .balanced
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    private func resumePendingStart() {
        guard let request = pendingStart else { return }
        pendingStart = nil
        startSession(cameraEnabled: request.camera, microphoneAllowed: request.microphone)
    }

    private func publishState() { onEvent(.state(state)) }

    private func detectHand(in sample: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = HandCaptureBudget(visualCapture: state.recording == .video, constrained: isResourceConstrained,
                                         recordingVideo: state.recording == .video || state.preparation?.kind == .video).detectionInterval
        guard state.ready, state.cameraActive, !visionInFlight, now - lastVisionTime >= interval,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        visionInFlight = true
        lastVisionTime = now
        let frameGeneration = generation
        // Relax occlusion only for stopping/canceling an existing operation.
        // Starting a recording still requires the original high-confidence pose.
        let allowPartiallyOccludedFist = state.recording != nil || state.preparation != nil
        // Capture buffers are immutable here; the read-only wrapper can cross queues.
        let frame = CVReadOnlyPixelBuffer(unsafeBuffer: buffer)
        visionQueue.async { [self] in
            autoreleasepool {
                var gesture: HandGesture?
                var guidance = "손 전체가 보이도록 한 손을 카메라에 보여 주세요."
                frame.withUnsafeBuffer { buffer in
                    do {
                        if handRequest == nil {
                            let request = VNDetectHumanHandPoseRequest()
                            request.maximumHandCount = 2
                            request.preferBackgroundProcessing = true
                            handRequest = request
                        }
                        guard let request = handRequest else { return }
                        // VideoDataOutput already rotates and mirrors its pixel buffers.
                        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
                        if let hands = request.results, hands.count == 1, let hand = hands.first {
                            let points = try hand.recognizedPoints(.all)
                            let aspect = CGFloat(CVPixelBufferGetWidth(buffer)) / CGFloat(CVPixelBufferGetHeight(buffer))
                            let names: [[VNHumanHandPoseObservation.JointName]] = [
                                [.indexMCP, .indexPIP, .indexTip], [.middleMCP, .middlePIP, .middleTip],
                                [.ringMCP, .ringPIP, .ringTip], [.littleMCP, .littlePIP, .littleTip]
                            ]
                            func point(_ name: VNHumanHandPoseObservation.JointName, confidence: Float = 0.5) -> CGPoint? {
                                guard let p = points[name], p.confidence >= confidence else { return nil }
                                return CGPoint(x: p.location.x * aspect, y: p.location.y)
                            }
                            if let wrist = point(.wrist) {
                                let fingers = names.compactMap { joints -> HandPose.Finger? in
                                    guard let base = point(joints[0], confidence: 0.3) else { return nil }
                                    return HandPose.Finger(base: base,
                                                           joint: point(joints[1], confidence: 0.3),
                                                           tip: point(joints[2], confidence: 0.3),
                                                           baseConfidence: points[joints[0]]?.confidence ?? 0,
                                                           jointConfidence: points[joints[1]]?.confidence ?? 0,
                                                           tipConfidence: points[joints[2]]?.confidence ?? 0)
                                }
                                gesture = HandPose(wrist: wrist, fingers: fingers)
                                    .gesture(allowPartiallyOccludedFist: allowPartiallyOccludedFist)
                            }
                            guidance = gesture == nil ? "손가락 모양을 또렷하게 보여 주세요." : "동작을 약 1초간 유지하세요."
                        } else if (request.results?.count ?? 0) > 1 {
                            guidance = "한 손만 보여 주세요."
                        }
                    } catch {
                        guidance = "손 인식에 실패했습니다. 손 위치와 조명을 확인해 주세요."
                    }
                }
                let detected = gesture
                let message = guidance
                queue.async {
                    self.visionInFlight = false
                    guard self.generation == frameGeneration, self.state.ready else { return }
                    let result = self.gate.update(detected, at: now)
                    self.onEvent(.tracking(detected, result.progress, message))
                    if let action = result.action { self.execute(action) }
                }
            }
        }
    }
}

extension HandCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output === videoOutput
        append(sampleBuffer, isVideo: isVideo)
        if isVideo { detectHand(in: sampleBuffer) }
    }
}

nonisolated private struct CaptureFailure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

nonisolated private final class HandPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private var result: Result<Data, Error> = .failure(CaptureFailure("사진 데이터를 받지 못했습니다."))

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { result = .failure(error) }
        else if let data = photo.fileDataRepresentation() { result = .success(data) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(error.map { .failure($0) } ?? result)
    }
}
