import SwiftUI

struct SpeechTestView: View {
    @EnvironmentObject private var sync: RecordingSyncViewModel

    var body: some View {
        VStack(spacing: 20) {
            Text(sync.currentInputDBFS.map { String(format: "%.1f dBFS", $0) } ?? "--.- dBFS")
                .font(.title2.bold())
                .monospacedDigit()

            Button(sync.speechTestMode == nil ? "녹음 시작" : "녹음 중지") {
                sync.speechTestMode == nil ? sync.startSpeechTest() : sync.stopSpeechTest()
            }
            .tint(sync.speechTestMode == nil ? .accentColor : .red)
            .disabled(sync.isRecording || (sync.speechTestMode == nil && sync.currentInputDBFS == nil))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("음성 기록")
        .onAppear {
            sync.refreshConnectionStatus()
            sync.startAmbientMonitoring()
        }
        .onDisappear { sync.stopAmbientMonitoring() }
        .alert("오류", isPresented: Binding(
            get: { sync.errorMessage != nil },
            set: { if !$0 { sync.clearError() } }
        )) {
            Button("확인", role: .cancel) { sync.clearError() }
        } message: {
            Text(sync.errorMessage ?? "")
        }
    }
}
