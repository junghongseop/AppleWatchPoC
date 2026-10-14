import QuickLook
import SwiftUI

struct HandTrackingView: View {
    @StateObject private var model = HandTrackingViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showingRecords = false
    @State private var isVisible = false

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    cameraOptions
                    camera
                        .id("capturePreview")
                    recordingStatus
                    if model.state.cameraActive {
                        HandTrackingFeedbackView(feedback: model.feedback, recording: model.state.recording != nil)
                    }
                    controls
                    if let message = model.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("handTracking.message")
                    }
                    if model.needsSettings {
                        Button("권한 설정 열기", systemImage: "gearshape") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                    if !model.state.ready {
                        Button("기록 장치 다시 시작", systemImage: "arrow.clockwise") { model.startCapture() }
                            .disabled(model.requestingPermission || model.state.saving)
                    }
                    instructions
                }
                .padding()
            }
            .navigationTitle("손동작 기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장 목록", systemImage: "folder") {
                        model.stopCapture()
                        showingRecords = true
                    }
                    .disabled(model.state.recording != nil || model.state.saving || model.state.preparation != nil)
                }
            }
            .sheet(isPresented: $showingRecords, onDismiss: {
                if isVisible && scenePhase == .active { model.startCapture() }
            }) {
                HandRecordingList(recordings: model.recordings)
            }
            .onAppear {
                isVisible = true
                if scenePhase == .active { model.startCapture() }
            }
            .onDisappear {
                isVisible = false
                model.stopCapture()
            }
            .onChange(of: scenePhase) { _, phase in
                guard isVisible, !showingRecords else { return }
                if phase == .active { model.startCapture() }
                // Permission dialogs also make the scene inactive; let their request finish.
                else if phase == .background { model.stopCapture() }
            }
            .onChange(of: model.showsCameraPreview) { _, visible in
                if visible { scroll.scrollTo("capturePreview", anchor: .top) }
            }
            .onChange(of: model.state.preparation?.id) { _, id in
                // The preview may already be enabled but scrolled offscreen.
                if id != nil { scroll.scrollTo("capturePreview", anchor: .top) }
            }
        }
    }

    private var previewVisible: Bool { model.cameraEnabled && model.showsCameraPreview }

    private var cameraOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("핸드트래킹 카메라", isOn: Binding(
                get: { model.cameraEnabled },
                set: { model.setCameraEnabled($0) }
            ))
            .disabled(!model.canChangeCamera)
            .accessibilityIdentifier("handTracking.cameraEnabled")
            Toggle("핸드트래킹 미리보기", isOn: $model.showsTrackingPreview)
                .disabled(!model.cameraEnabled)
                .accessibilityIdentifier("handTracking.previewVisible")
            Text(model.cameraEnabled
                 ? "손동작 인식·음성 녹음 중 미리보기 표시 여부를 선택할 수 있습니다. 사진·영상 촬영 중에는 자동으로 표시하고, 종료하면 선택한 설정으로 돌아갑니다. 사진은 미리보기가 켜진 뒤 5초 후 촬영합니다."
                 : "카메라와 손동작 인식이 꺼져 있습니다. 음성 버튼으로 카메라 없이 녹음할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            if model.state.recording != nil || model.state.preparation != nil {
                Text("카메라 켜기·끄기는 촬영 취소 또는 기록 종료 후 변경할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var camera: some View {
        ZStack(alignment: .topLeading) {
            HandCameraPreview(showsPreview: previewVisible,
                              preparationID: model.state.preparation?.id,
                              onConnect: model.connectPreview, onDisconnect: model.disconnectPreview,
                              onVisible: model.previewDidBecomeVisible)
                .accessibilityLabel("전면 카메라 미리보기")
            if !model.state.cameraActive {
                Color.black.opacity(0.7)
                VStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").font(.largeTitle)
                    Text(model.requestingPermission ? "카메라·마이크 권한 확인 중" : model.state.statusMessage)
                        .font(.callout)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let countdown = model.state.photoCountdown {
                VStack(spacing: 6) {
                    Text("\(countdown)")
                        .font(.system(size: 80, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("초 후 사진 촬영").font(.headline)
                }
                .foregroundStyle(.white)
                .shadow(radius: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.2))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("handTracking.photoCountdown")
            }
        }
        // Keep the rotation coordinator attached even when no camera image is shown.
        .frame(height: previewVisible ? 330 : 0)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityHidden(!previewVisible)
    }

    private var recordingStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: model.state.recording == .voice ? "waveform" : "record.circle")
                .font(.title2)
                .foregroundStyle(model.state.recording == nil ? Color.secondary : Color.red)
            VStack(alignment: .leading, spacing: 5) {
                if let countdown = model.state.photoCountdown {
                    Text("사진 촬영까지 \(countdown)초").font(.headline)
                } else if model.state.preparation != nil {
                    Text("카메라 미리보기 준비 중").font(.headline)
                } else if let kind = model.state.recording {
                    Text("\(kind.title) 기록 중").font(.headline)
                    if let start = model.state.startedAt { Text(start, style: .timer).monospacedDigit() }
                } else {
                    Text(model.state.saving ? "저장 중…" : model.state.statusMessage)
                        .font(.headline)
                }
                Text(model.state.cameraActive ? "카메라 켜짐 · 손동작 인식 중" : "카메라 꺼짐 · 손동작 인식 중지")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Button("음성", systemImage: "mic.fill") { model.perform(.voice) }
                    .disabled(!model.canStart || !model.state.microphoneAvailable)
                Button("사진", systemImage: "camera.fill") { model.perform(.photo) }
                    .disabled(!model.canStart || !model.state.cameraActive)
                Button("영상", systemImage: "video.fill") { model.perform(.video) }
                    .disabled(!model.canStart || !model.state.microphoneAvailable || !model.state.cameraActive)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            if model.state.preparation != nil {
                Button("촬영 취소", systemImage: "xmark.circle.fill") { model.perform(.stop) }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
            if model.state.recording != nil {
                Button("기록 종료 및 저장", systemImage: "stop.fill") { model.perform(.stop) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("손동작 안내").font(.headline)
            ForEach(HandGesture.allCases, id: \.self) { gesture in
                Label(gesture.title, systemImage: gesture.symbol)
                    .font(.subheadline)
            }
            Text("손바닥이 카메라를 향하게 하고 한 손 전체를 보여 주세요. 각 동작을 약 1초간 유지하면 실행됩니다. 같은 동작을 반복하려면 손을 0.5초 이상 화면 밖으로 뺐다가 다시 보여 주세요. 엄지의 모양은 상관없습니다.")
            Text("V자는 미리보기를 켜고 5초 후 사진을 촬영합니다. 손바닥은 미리보기를 켠 다음 영상 녹화를 시작합니다. 준비 중에는 주먹이나 촬영 취소 버튼으로 취소할 수 있습니다. 촬영이 끝나거나 취소하면 선택한 미리보기 설정으로 돌아갑니다.")
            Text("카메라가 켜져 있으면 녹음·녹화 중 주먹으로 종료할 수 있습니다. 카메라가 꺼져 있으면 종료 버튼을 사용하세요. 다른 기록을 시작하려면 현재 기록을 먼저 종료하세요. 영상에는 소리가 포함됩니다. 영상 촬영 중에는 기기의 방향을 유지해 주세요.")
            Text("화면을 나가거나 앱이 백그라운드로 이동하면 기록을 종료합니다. 파일은 이 iPhone의 앱 내부에 저장되며, 저장 목록에서 재생·확인·공유할 수 있습니다.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct HandTrackingFeedbackView: View {
    @ObservedObject var feedback: HandTrackingFeedback
    let recording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(feedback.value.gesture?.title ?? "손동작을 기다리고 있어요", systemImage: feedback.value.gesture?.symbol ?? "hand.raised")
                .font(.headline)
            ProgressView(value: feedback.value.progress)
                .tint(recording ? .red : .accentColor)
                .accessibilityLabel("손동작 유지 진행률")
            Text(feedback.value.guidance).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct HandRecordingList: View {
    let recordings: [HandRecording]
    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            List(recordings) { recording in
                HStack(spacing: 12) {
                    Button {
                        previewURL = recording.url
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(recording.kind.title, systemImage: symbol(recording.kind))
                                .font(.headline)
                            Text(recording.date, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                            Text(recording.url.lastPathComponent).font(.caption2).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    ShareLink(item: recording.url) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("\(recording.kind.title) 파일 공유")
                }
            }
            .overlay {
                if recordings.isEmpty {
                    ContentUnavailableView("아직 기록이 없습니다", systemImage: "folder", description: Text("손동작으로 첫 기록을 남겨 보세요."))
                }
            }
            .navigationTitle("손동작 기록 목록")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .quickLookPreview($previewURL)
        }
    }

    private func symbol(_ kind: HandRecordingKind) -> String {
        switch kind {
        case .voice: "waveform"
        case .photo: "photo"
        case .video: "video"
        }
    }
}
