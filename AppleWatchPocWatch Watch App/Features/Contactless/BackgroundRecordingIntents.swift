import AppIntents
import Foundation

// Only stops an existing contactless recording; never activates an audio session.
// Preserve the intent type name so previously created stop shortcuts remain identifiable.
struct StopBackgroundRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "워치 백그라운드 녹음 중지"
    static var description = IntentDescription("워치 앱을 열지 않고 진행 중인 비접촉 녹음을 저장하고 아이폰 전송을 예약합니다.")
    static var openAppWhenRun = false
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        WatchRecordingSyncService.shared.stopContactless(trigger: "백그라운드 단축어 / AssistiveTouch")
        #else
        try rejectBackgroundPhoneExecution()
        #endif
        return .result()
    }
}

#if os(iOS)
private func rejectBackgroundPhoneExecution() throws {
    throw NSError(domain: "Contactless", code: 1, userInfo: [NSLocalizedDescriptionKey:
        "이 동작은 Apple Watch에서 실행해 주세요. 아이폰 원격 실행은 지원하지 않습니다."])
}
#endif
