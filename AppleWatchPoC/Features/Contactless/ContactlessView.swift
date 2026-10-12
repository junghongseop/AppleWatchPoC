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
            Section("비접촉 제어 단축어") {
                Text("비접촉 녹음 시작: 워치 앱을 열고 녹음을 시작합니다.")
                Text("비접촉 녹음 중지: 워치 앱을 열고 녹음을 저장합니다.")
                Text("백그라운드 녹음 중지: 워치 앱을 열지 않고 진행 중인 녹음을 저장합니다.")
                Text("세 액션은 Apple Watch에서 실행하세요. 녹음 종료 후 파일과 마커가 아이폰으로 전송됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AssistiveTouch 설정") {
                Text("단축어를 만들고 ‘Apple Watch에서 보기’를 켠 뒤 워치에서 직접 실행해 보세요. 손쉬운 사용 → AssistiveTouch → 손 제스처에서 한 번 집기에 시작, 두 번 집기에 원하는 중지 단축어를 지정합니다.")
                Text("시작은 워치 앱을 엽니다. 앱을 열지 않고 중지하려면 ‘백그라운드 녹음 중지’를 선택하세요. 시스템 단축어 알림은 표시될 수 있습니다.")
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
                            Text("시작 경로: \(record.trigger)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("종료 경로: \(record.stopTriggerDescription)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("종료 사유: \(record.endReason ?? "확인 불가")")
                                .font(.caption).foregroundStyle(.secondary)
                            if let state = record.startApplicationState {
                                Text("시작 당시 앱 상태: \(state)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
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
