import SwiftUI
import Combine

struct RecordingSyncView: View {
    @EnvironmentObject private var sync: RecordingSyncViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            ConnectionStatusSection()
            Section("워치에서 받은 녹음") {
                if sync.recordings.isEmpty {
                    Text("받은 녹음 없음")
                }
                ForEach(sync.recordings, id: \.lastPathComponent) { url in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Button(sync.playingURL == url ? "중지" : "재생") {
                                sync.togglePlayback(url)
                            }
                        }
                        if let details = sync.details(for: url) {
                            Text("받은 시각: \(details.receivedAt, format: .dateTime.year().month().day().hour().minute().second()) · 녹음 길이: \(details.durationSeconds, specifier: "%.1f")초")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let metric = sync.measurement(for: url),
                           let elapsed = metric.elapsedSeconds {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(metric.fileBytes), countStyle: .file)) · \(elapsed, specifier: "%.1f")초 · \(Double(metric.fileBytes) / max(elapsed, 0.001) / 1_000_000, specifier: "%.2f") MB/s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if sync.measurement(for: url) != nil {
                            Text("실시간 연결 시점을 확인하지 못해 시간 측정 불가")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("전송 시간 측정값 대기 중")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: sync.deleteRecordings)
            }

            if let error = sync.errorMessage {
                Section("오류") { Text(error) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("녹음 동기화")
        .onDisappear { sync.stopPlayback() }
        .onAppear { sync.refreshConnectionState() }
        .onReceive(refreshTimer) { _ in sync.refreshConnectionState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { sync.refreshConnectionState() }
        }
    }
}

private struct ConnectionStatusSection: View {
    @EnvironmentObject private var sync: RecordingSyncViewModel

    var body: some View {
        Section {
            Label(title, systemImage: symbol)
                .foregroundStyle(color)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("워치 연결 상태")
        }
    }

    private var title: String {
        switch sync.connectionState {
        case .checking: "연결 확인 중"
        case .unavailable: "연결 기능 사용 불가"
        case .unpaired: "페어링된 워치 없음"
        case .watchAppMissing: "워치 앱 설치 필요"
        case .reachable: "실시간 연결 가능"
        case .background: "실시간 연결 안 됨"
        }
    }

    private var symbol: String {
        switch sync.connectionState {
        case .reachable: "checkmark.circle.fill"
        case .checking, .background: "clock.fill"
        case .unavailable, .unpaired, .watchAppMissing: "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch sync.connectionState {
        case .reachable: .green
        case .checking, .background: .orange
        case .unavailable, .unpaired, .watchAppMissing: .red
        }
    }

    private var detail: String {
        switch sync.connectionState {
        case .reachable: "워치 앱과 즉시 통신할 수 있습니다."
        case .background: "앱이 백그라운드이거나 기기 연결이 끊겼을 수 있습니다. 파일 전송은 백그라운드에서 진행됩니다."
        case .checking: "WatchConnectivity 상태를 확인하고 있습니다."
        case .unavailable: "이 기기에서 WatchConnectivity를 사용할 수 없습니다."
        case .unpaired: "Apple Watch를 아이폰과 페어링해 주세요."
        case .watchAppMissing: "Apple Watch에 테스트 앱을 설치해 주세요."
        }
    }
}
