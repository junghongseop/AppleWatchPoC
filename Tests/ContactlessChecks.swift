import Foundation

@main
struct ContactlessChecks {
    static func main() throws {
        var detector = MotionMarkerDetector()
        assert(!detector.detect(acceleration: 0.1, rotation: 0.2, time: 0))
        assert(!detector.detect(acceleration: 2, rotation: 0.2, time: 0.1))
        assert(detector.detect(acceleration: 2, rotation: 4, time: 0.2))
        assert(!detector.detect(acceleration: 2, rotation: 4, time: 3)) // sustained movement
        assert(!detector.detect(acceleration: 0, rotation: 0, time: 3.1))
        assert(detector.detect(acceleration: 2, rotation: 4, time: 3.2))
        assert(!detector.detect(acceleration: 0, rotation: 0, time: 3.3))
        assert(!detector.detect(acceleration: 2, rotation: 4, time: 3.4)) // cooldown
        assert(!detector.detect(acceleration: .nan, rotation: 4, time: 6))
        assert(detector.detect(acceleration: 2, rotation: 4, time: 6))
        let start = Date(timeIntervalSince1970: 100)
        let record = ContactlessRecording(startedAt: start, endedAt: start.addingTimeInterval(10),
            trigger: "단축어", markers: [.init(id: UUID(), offset: 3, label: "커스텀 마커")], endReason: "사용자 요청", stopTrigger: "일반 단축어 / AssistiveTouch",
            executionMode: "audioRecordingIntent", startApplicationState: "백그라운드")
        let data = try JSONEncoder().encode(record)
        let restored = try JSONDecoder().decode(ContactlessRecording.self, from: data)
        assert(restored.startedAt == start && restored.endedAt == start.addingTimeInterval(10))
        assert(restored.markers.first?.offset == 3 && restored.markers.first?.label == "커스텀 마커")
        assert(restored.stopTriggerDescription == "일반 단축어 / AssistiveTouch")
        assert(restored.executionMode == "audioRecordingIntent" && restored.startApplicationState == "백그라운드")
        // Old recordings did not record the stop source. Never infer it from the start source.
        let legacyData = Data(#"{"startedAt":100,"trigger":"단축어","markers":[],"endReason":"중지"}"#.utf8)
        let legacy = try JSONDecoder().decode(ContactlessRecording.self, from: legacyData)
        assert(legacy.stopTrigger == nil && legacy.executionMode == nil)
        assert(legacy.stopTriggerDescription.contains("미기록"))
        print("Contactless detector and metadata checks passed")
    }
}
