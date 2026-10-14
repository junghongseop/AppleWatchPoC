import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class HandTrackingFeedback: ObservableObject {
    struct Value: Equatable {
        var gesture: HandGesture?
        var progress = 0.0
        var guidance = "카메라를 준비하고 있습니다."
    }

    @Published private(set) var value = Value()

    func update(gesture: HandGesture? = nil, progress: Double = 0, guidance: String) {
        let next = Value(gesture: gesture, progress: progress, guidance: guidance)
        if value != next { value = next }
    }
}

@MainActor
final class HandTrackingViewModel: ObservableObject {
    @Published private(set) var state = HandCaptureState()
    let feedback = HandTrackingFeedback()
    @Published private(set) var recordings: [HandRecording] = []
    @Published private(set) var message: String?
    @Published private(set) var requestingPermission = false
    @Published private(set) var needsSettings = false
    @Published private(set) var cameraEnabled = true
    @Published var showsTrackingPreview = true

    private var wantsCapture = false
    private var recordingsRevision = UUID()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HandTrackingRecords", isDirectory: true)
    private lazy var engine = HandCaptureEngine(directory: directory) { [weak self] event in
        DispatchQueue.main.async { [weak self] in self?.receive(event) }
    }

    deinit {
        let task = backgroundTask
        if task != .invalid {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(task) }
        }
    }

    var showsCameraPreview: Bool {
        showsTrackingPreview || state.preparation != nil || state.recording == .video || state.photoInFlight
    }
    var canStart: Bool { state.ready && canChangeCamera }
    var canChangeCamera: Bool { state.recording == nil && !state.saving && state.preparation == nil && !requestingPermission }

    func setCameraEnabled(_ enabled: Bool) {
        guard canChangeCamera else { return }
        cameraEnabled = enabled
        feedback.update(guidance: enabled ? "카메라를 준비하고 있습니다." : "카메라 꺼짐")
        startCapture()
    }

    func startCapture() {
        wantsCapture = true
        guard !requestingPermission else { return }
        requestingPermission = true
        message = nil
        Task {
            let camera = cameraEnabled ? await authorize(.video) : false
            let microphone = await authorize(.audio)
            requestingPermission = false
            needsSettings = (cameraEnabled && !camera) || !microphone
            guard wantsCapture else { return }
            guard camera || microphone else {
                engine.stop()
                feedback.update(guidance: "기록에 필요한 권한을 허용해 주세요.")
                message = cameraEnabled ? "카메라 또는 마이크 접근을 설정에서 허용해 주세요." : "카메라 없이 녹음하려면 마이크 접근을 허용해 주세요."
                return
            }
            if !microphone { message = "마이크 접근이 꺼져 있어 사진 촬영만 가능합니다." }
            else if cameraEnabled && !camera { message = "카메라 접근이 꺼져 있어 수동 음성 녹음만 가능합니다." }
            engine.start(cameraEnabled: camera, microphoneAllowed: microphone)
            refreshRecordings()
        }
    }

    func stopCapture() {
        wantsCapture = false
        // Give AssetWriter a short opportunity to finish if the app enters background.
        if (state.recording != nil || state.saving), backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish hand recording") { [weak self] in
                Task { @MainActor [weak self] in self?.endBackgroundTask() }
            }
        }
        engine.stop()
    }

    func perform(_ action: HandGesture) { engine.perform(action) }
    func connectPreview(_ target: HandPreviewTarget, visible: Bool) { engine.connectPreview(target, visible: visible) }
    func disconnectPreview(_ target: HandPreviewTarget) { engine.disconnectPreview(target) }
    func previewDidBecomeVisible(for id: UUID) {
        guard wantsCapture, state.preparation?.id == id else { return }
        engine.previewDidBecomeVisible(for: id)
    }

    func refreshRecordings() {
        let revision = UUID()
        recordingsRevision = revision
        let directory = directory
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<[HandRecording], Error> in
                Result {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
                        .compactMap { url -> HandRecording? in
                            guard let kind = [HandRecordingKind.voice, .photo, .video].first(where: { $0.fileExtension == url.pathExtension }) else { return nil }
                            let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                            return HandRecording(url: url, kind: kind, date: date)
                        }
                        .sorted { $0.date > $1.date }
                }
            }.value
            guard recordingsRevision == revision else { return }
            switch result {
            case .success(let values): recordings = values
            case .failure(let error): message = "저장 목록을 읽지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    private func authorize(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    private func receive(_ event: HandCaptureEvent) {
        switch event {
        case .state(let value):
            state = value
            if value.recording == nil && !value.saving { endBackgroundTask() }
        case .tracking(let value, let progress, let guidance):
            feedback.update(gesture: value, progress: progress, guidance: guidance)
        case .saved(let url):
            let kind = url.pathExtension == "jpg" ? "사진" : url.pathExtension == "mov" ? "영상" : "음성"
            message = "\(kind) 기록을 저장했습니다. 저장 목록에서 확인하세요."
            refreshRecordings()
        case .error(let error): message = error
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
