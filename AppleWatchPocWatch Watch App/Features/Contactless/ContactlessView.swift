import SwiftUI

struct ContactlessView: View {
    @ObservedObject private var service = WatchRecordingSyncService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let record = service.contactlessRecording {
                    Text(record.startedAt, style: .timer)
                        .font(.title2.monospacedDigit())
                    Text("마커 \(record.markers.count)개")
                }
                Button(service.contactlessRecording == nil ? "녹음 시작" : "녹음 중지") {
                    if service.contactlessRecording != nil {
                        service.stopContactless()
                    } else {
                        Task {
                            do { try await service.startContactless(trigger: "워치 버튼") }
                            catch { service.errorMessage = error.localizedDescription }
                        }
                    }
                }
                .tint(service.contactlessRecording == nil ? .accentColor : .red)
                .disabled(service.preparingContactless ||
                          (service.contactlessRecording == nil && (service.isRecording || service.speechTestMode != nil)))
                Text(service.motionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("마커 이름", text: $service.markerLabel)
                Text("한 번 집기: 비접촉 녹음 시작\n두 번 집기: 비접촉 녹음 중지 또는 백그라운드 녹음 중지\nAssistiveTouch에서 단축어를 지정하세요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical)
        }
        .navigationTitle("비접촉 제어")
        .alert("오류", isPresented: Binding(get: { service.errorMessage != nil },
            set: { if !$0 { service.errorMessage = nil } })) {
            Button("확인") { service.errorMessage = nil }
        } message: { Text(service.errorMessage ?? "") }
    }
}
