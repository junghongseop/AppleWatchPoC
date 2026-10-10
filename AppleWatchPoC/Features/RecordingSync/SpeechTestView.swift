import SwiftUI

struct SpeechTestView: View {
    @EnvironmentObject private var sync: RecordingSyncViewModel
    @State private var pendingDeletionID: String?

    var body: some View {
        List {
            Section("문장") {
                Text(SpeechTestResult.referenceSentence)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !summaries.isEmpty {
                Section("입력 수준별 평균") {
                    ForEach(summaries, id: \.band) { summary in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(summary.band.rawValue) · \(summary.count)회")
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("실시간 \(summary.live)% · 파일 변환 \(summary.file)%")
                                .fixedSize(horizontal: false, vertical: true)
                            Text("평균 시작 직전 입력: \(summary.ambient, specifier: "%.1f") dBFS")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("시험 결과") {
                if sync.speechTests.isEmpty {
                    Text("아직 시험 결과가 없습니다.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sync.speechTests, id: \.id) { test in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(test.startedAt, format: .dateTime.month().day().hour().minute().second())
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if let level = test.ambientDBFS {
                            Text("시작 직전 입력: \(level, specifier: "%.1f") dBFS · 대략 \(AmbientNoiseBand.from(level).rawValue)")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("시작 직전 입력 레벨 없음")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if test.liveStreamInterrupted == true {
                            Text("실시간 오디오 전송이 일부 끊겼습니다.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if test.mode == "both" || test.mode == "live" {
                            transcriptSection("실시간", text: test.transcript,
                                              status: test.status, accuracy: test.liveAccuracy)
                        }
                        if test.mode == "both" || test.mode == "after" {
                            transcriptSection("파일 변환", text: test.fileTranscript ?? (test.mode == "after" ? test.transcript : ""),
                                              status: test.fileStatus ?? "파일 전송 대기 중",
                                              accuracy: test.fileAccuracy)
                        }
                        Button(role: .destructive) {
                            pendingDeletionID = test.id
                        } label: {
                            Label("결과 삭제", systemImage: "trash")
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("음성 기록 시험")
        .onAppear { sync.requestSpeechAuthorization() }
        .alert("오류", isPresented: Binding(
            get: { sync.errorMessage != nil },
            set: { if !$0 { sync.clearError() } }
        )) {
            Button("확인", role: .cancel) { sync.clearError() }
        } message: {
            Text(sync.errorMessage ?? "")
        }
        .confirmationDialog("시험 결과를 삭제할까요?", isPresented: Binding(
            get: { pendingDeletionID != nil },
            set: { if !$0 { pendingDeletionID = nil } }
        ), titleVisibility: .visible) {
            Button("결과와 녹음 삭제", role: .destructive) {
                if let id = pendingDeletionID { sync.deleteSpeechTest(id: id) }
                pendingDeletionID = nil
            }
            Button("취소", role: .cancel) { pendingDeletionID = nil }
        } message: {
            Text("이 시험의 문장과 워치에서 받은 녹음 파일을 삭제합니다.")
        }
    }

    private func transcriptSection(_ title: String, text: String,
                                   status: String, accuracy: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.bold())
            if let accuracy, status == "완료" {
                Text("일치율 \(accuracy)%")
                    .font(.caption.bold())
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(text.isEmpty ? "인식된 문장 대기 중" : text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaries: [(band: AmbientNoiseBand, count: Int, live: Int,
                             file: Int, ambient: Double)] {
        let complete = sync.speechTests.filter {
            $0.mode == "both" && $0.status == "완료" && $0.fileStatus == "완료" &&
            $0.ambientDBFS != nil
        }
        return AmbientNoiseBand.allCases.compactMap { band in
            let tests = complete.filter { AmbientNoiseBand.from($0.ambientDBFS ?? -160) == band }
            guard !tests.isEmpty else { return nil }
            let live = tests.compactMap(\.liveAccuracy)
            let file = tests.compactMap(\.fileAccuracy)
            let ambient = tests.compactMap(\.ambientDBFS)
            return (band, tests.count,
                    live.reduce(0, +) / max(live.count, 1),
                    file.reduce(0, +) / max(file.count, 1),
                    ambient.reduce(0, +) / Double(ambient.count))
        }
    }
}
