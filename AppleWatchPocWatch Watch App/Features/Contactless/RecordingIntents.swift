import AppIntents
import Foundation

// These actions execute on the watch and use the same recorder as the UI.
// Opening the app is intentional: background refresh cannot initiate microphone capture.
struct StartContactlessRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "워치 비접촉 녹음 시작"
    static var description = IntentDescription("워치 앱을 열고 모션 마커를 포함한 녹음을 시작합니다.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        try await WatchRecordingSyncService.shared.startContactless(trigger: "단축어 / AssistiveTouch")
        #else
        try rejectPhoneExecution()
        #endif
        return .result()
    }
}

struct StopContactlessRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "워치 비접촉 녹음 중지"
    static var description = IntentDescription("워치의 비접촉 녹음을 저장하고 아이폰 전송을 예약합니다.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        WatchRecordingSyncService.shared.stopContactless()
        #else
        try rejectPhoneExecution()
        #endif
        return .result()
    }
}

struct RecordingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartContactlessRecordingIntent(),
                    phrases: ["\(.applicationName) 비접촉 녹음 시작"],
                    shortTitle: "비접촉 녹음 시작", systemImageName: "mic.fill")
        AppShortcut(intent: StopContactlessRecordingIntent(),
                    phrases: ["\(.applicationName) 비접촉 녹음 중지"],
                    shortTitle: "비접촉 녹음 중지", systemImageName: "stop.fill")
    }
}

#if os(iOS)
private func rejectPhoneExecution() throws {
    throw NSError(domain: "Contactless", code: 1, userInfo: [NSLocalizedDescriptionKey:
        "이 동작은 Apple Watch에서 실행해 주세요. 아이폰 원격 실행은 지원하지 않습니다."])
}
#endif
