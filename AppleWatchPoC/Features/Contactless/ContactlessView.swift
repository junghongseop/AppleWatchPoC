import SwiftUI

struct ContactlessView: View {
    @EnvironmentObject private var sync: RecordingSyncViewModel

    private var recordings: [URL] {
        sync.recordings.filter { sync.details(for: $0)?.contactless != nil }
            .sorted {
                (sync.details(for: $0)?.contactless?.startedAt ?? .distantPast) >
                (sync.details(for: $1)?.contactless?.startedAt ?? .distantPast)
            }
    }

    var body: some View {
        List {
            Section("AssistiveTouch 설정") {
                Text("워치 단축어에서 ‘비접촉 녹음 시작’과 ‘비접촉 녹음 중지’를 먼저 실행해 보세요. 손쉬운 사용 → AssistiveTouch → 손 제스처에서 한 번 집기와 두 번 집기에 각각 지정합니다.")
                Text("단축어는 워치 앱을 열어 실행합니다. 시작 후 화면이 꺼진 상태의 녹음 지속과 모션 감지는 실제 워치에서 확인하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("시험 결과") {
                if recordings.isEmpty {
                    Text("아직 받은 녹음이 없습니다. 녹음 종료 후 워치에서 전송됩니다.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recordings, id: \.lastPathComponent) { url in
                    if let details = sync.details(for: url), let record = details.contactless {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.headline)
                            if let end = record.endedAt {
                                Text("종료: \(end, format: .dateTime.year().month().day().hour().minute().second())")
                            } else {
                                Text("종료 시각 확인 불가")
                            }
                            Text("녹음 길이: \(details.durationSeconds, specifier: "%.1f")초 · 마커 \(record.markers.count)개")
                            Text("시작: \(record.trigger) · 종료: \(record.endReason ?? "확인 불가")")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(record.markers) { marker in
                                Text("+\(marker.offset, specifier: "%.1f")초 · \(marker.label)")
                                    .font(.caption)
                            }
                            Button(sync.playingURL == url ? "재생 중지" : "녹음 재생") {
                                sync.togglePlayback(url)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if let error = sync.errorMessage {
                Section("오류") { Text(error) }
            }
        }
        .navigationTitle("비접촉 제어")
        .onDisappear { sync.stopPlayback() }
    }
}
