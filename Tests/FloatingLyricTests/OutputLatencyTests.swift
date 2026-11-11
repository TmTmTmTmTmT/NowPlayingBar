import AppKit
import CoreAudio
import Testing
@testable import FloatingLyric

/// PLAN 13.2 rule and 13.3 offset sum. No real CoreAudio listeners.
@MainActor
@Suite struct OutputLatencyTests {
    private let bt = kAudioDeviceTransportTypeBluetooth

    private func delay(_ transport: UInt32, _ lat: UInt32, _ safety: UInt32 = 0, _ stream: UInt32 = 0,
                       rate: Double = 48000, enabled: Bool = true) -> TimeInterval {
        OutputLatency.delay(transport: transport, deviceLatency: lat, safetyOffset: safety,
                            streamLatency: stream, sampleRate: rate, enabled: enabled)
    }

    @Test func bluetoothUsesReportedFrames() {
        #expect(abs(delay(bt, 7680) - 0.160) < 1e-9)
        #expect(abs(delay(kAudioDeviceTransportTypeBluetoothLE, 7680) - 0.160) < 1e-9)
    }

    @Test func builtInIsZero() {
        #expect(delay(kAudioDeviceTransportTypeBuiltIn, 140, 148, 1390, rate: 96000) == 0)
    }

    @Test func bluetoothReportingZeroFallsBack() { #expect(delay(bt, 0) == 0.18) }
    @Test func zeroRateFallsBack() { #expect(delay(bt, 7680, rate: 0) == 0.18) }
    @Test func clampedToHalfSecond() { #expect(delay(bt, 48000) == 0.5) }
    @Test func settingOffIsZero() { #expect(delay(bt, 7680, enabled: false) == 0) }

    private final class Fake: OutputLatencySource {
        var seconds: TimeInterval
        var onChange: ((TimeInterval) -> Void)?
        init(_ s: TimeInterval) { seconds = s }
        func start() {}
        func stop() {}
        func refresh() {}
        func set(_ s: TimeInterval) { seconds = s; onChange?(s) }
    }

    @Test func timingOffsetIsMinusDelayAndFollowsChanges() {
        _ = NSApplication.shared
        let prefs = LyricPreferences(defaults: UserDefaults(suiteName: "FloatingLyricOL-\(UUID().uuidString)")!)
        let fake = Fake(0.16)
        let view = LyricsView(preferences: prefs, outputLatency: fake)
        view.show(document: nil, emptyState: .none)
        #expect(abs(view.clock.timingOffset + 0.16) < 1e-9)    // Atmos offset is 0 while its compensation is off
        fake.set(0.05)
        #expect(abs(view.clock.timingOffset + 0.05) < 1e-9)
        prefs.bluetoothDelay = false
        view.reload()
        #expect(view.clock.timingOffset == 0)
    }

    @Test func defaultIsOn() {
        let prefs = LyricPreferences(defaults: UserDefaults(suiteName: "FloatingLyricOL-\(UUID().uuidString)")!)
        #expect(prefs.bluetoothDelay)
    }
}
