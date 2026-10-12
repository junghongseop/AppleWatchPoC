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
            trigger: "단축어", markers: [.init(id: UUID(), offset: 3, label: "커스텀 마커")], endReason: "중지")
        let data = try JSONEncoder().encode(record)
        let restored = try JSONDecoder().decode(ContactlessRecording.self, from: data)
        assert(restored.startedAt == start && restored.endedAt == start.addingTimeInterval(10))
        assert(restored.markers.first?.offset == 3 && restored.markers.first?.label == "커스텀 마커")
        print("Contactless detector and metadata checks passed")
    }
}
