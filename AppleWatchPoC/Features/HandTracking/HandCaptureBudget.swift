import Foundation

/// Keep recognition responsive enough for the 0.9-second hold even when throttled.
nonisolated struct HandCaptureBudget {
    let visualCapture: Bool
    let constrained: Bool

    var previewVisible = false
    var recordingVideo = false

    var cameraFPS: Int32 {
        if recordingVideo { return 60 }
        if visualCapture { return 30 }
        if constrained { return previewVisible ? 15 : 10 }
        return previewVisible ? 30 : 15
    }
    var detectionInterval: TimeInterval {
        // Keep the stop gesture available while prioritizing real-time video encoding.
        recordingVideo ? 0.3 : constrained ? 0.25 : 0.2
    }
}

/// Prefer a small 60fps video format; never select a costly 4K/still-photo format.
nonisolated struct HandVideoFormat {
    let width: Int32
    let height: Int32
    let frameRates: [ClosedRange<Double>]

    static func select(from formats: [Self]) -> (index: Int, fps: Int32)? {
        let eligible = formats.indices.filter {
            let format = formats[$0]
            return format.width >= 1280 && format.width <= 1920 && format.height >= 720
                && format.height <= 1080 && format.width * 9 == format.height * 16
        }.sorted {
            let left = formats[$0], right = formats[$1]
            if left.width != right.width { return left.width < right.width }
            return $0 < $1
        }
        for fps: Int32 in [60, 30] {
            if let index = eligible.first(where: { index in
                formats[index].frameRates.contains { $0.contains(Double(fps)) }
            }) { return (index, fps) }
        }
        return nil
    }
}
