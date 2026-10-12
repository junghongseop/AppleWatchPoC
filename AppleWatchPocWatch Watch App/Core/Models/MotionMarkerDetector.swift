import Foundation

/// Experimental shake detector. Acceleration is in g; rotation is in radians/second.
/// Requires a quiet sample to rearm and two seconds between accepted markers.
nonisolated struct MotionMarkerDetector {
    private var armed = true
    private var lastAccepted: TimeInterval = -2

    mutating func detect(acceleration: Double, rotation: Double, time: TimeInterval) -> Bool {
        guard acceleration.isFinite, rotation.isFinite, time.isFinite, time >= 0 else { return false }
        if acceleration < 0.35 && rotation < 1.5 { armed = true }
        guard armed, acceleration > 1.1, rotation > 3, time - lastAccepted >= 2 else { return false }
        armed = false
        lastAccepted = time
        return true
    }
}
