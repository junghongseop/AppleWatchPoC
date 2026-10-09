import SwiftUI
import Combine

struct RecordingSyncView: View {
    @EnvironmentObject private var sync: RecordingSyncViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            WatchConnectionStatusSection()

            Section("녹음") {
                Button(sync.isRecording ? "녹음 중지" : "녹음 시작") {
                    sync.isRecording ? sync.stopRecording() : sync.startRecording()
                }
                .tint(sync.isRecording ? .red : .accentColor)

                Button("동기화 재시도") { sync.queuePendingRecordings() }
                    .disabled(sync.isRecording || sync.recordings.isEmpty)
            }

            Section("워치에 보관 중") {
                if sync.recordings.isEmpty {
                    Text("대기 중인 녹음 없음")
                }
                ForEach(sync.recordings, id: \.lastPathComponent) { url in
                    VStack(alignment: .leading) {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .lineLimit(1)
                        Text(sync.status(for: url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = sync.errorMessage {
                Section("오류") { Text(error) }
            }
        }
        .navigationTitle("녹음 동기화")
        .onAppear { sync.refreshConnectionStatus() }
        .onReceive(refreshTimer) { _ in sync.refreshConnectionStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { sync.refreshConnectionStatus() }
        }
    }
}

private struct WatchConnectionStatusSection: View {
    @EnvironmentObject private var sync: RecordingSyncViewModel

    var body: some View {
        Section("아이폰 연결 상태") {
            Label(title, systemImage: symbol)
                .foregroundStyle(color)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch sync.connectionState {
        case .checking: "연결 확인 중"
        case .unavailable: "연결 기능 사용 불가"
        case .reachable: "실시간 연결 가능"
        case .background: "실시간 연결 안 됨"
        }
    }

    private var symbol: String {
        switch sync.connectionState {
        case .reachable: "checkmark.circle.fill"
        case .checking, .background: "clock.fill"
        case .unavailable: "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch sync.connectionState {
        case .reachable: .green
        case .checking, .background: .orange
        case .unavailable: .red
        }
    }

    private var detail: String {
        switch sync.connectionState {
        case .reachable: "아이폰 앱과 즉시 통신할 수 있습니다."
        case .background: "아이폰 앱이 백그라운드이거나 기기 연결이 끊겼을 수 있습니다."
        case .checking: "연결 상태를 확인하고 있습니다."
        case .unavailable: "WatchConnectivity를 사용할 수 없습니다."
        }
    }
}
