import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "FloatingLyric", category: "output-latency")

/// Source of the output delay the lyrics are held back by; `LyricsView` takes any, so tests can inject one.
protocol OutputLatencySource: AnyObject {
    /// Seconds of delay for the current default output (0 when none applies).
    var seconds: TimeInterval { get }
    /// Called on the main queue when `seconds` changes.
    var onChange: ((TimeInterval) -> Void)? { get set }
    func start()
    func stop()
    /// Recompute now (e.g. after the setting flipped).
    func refresh()
}

/// Delay of the default output device, for Bluetooth outputs only (PLAN 13): Music reports a playback
/// position that does not include it, so the lyrics would run ahead of the sound.
final class OutputLatency: OutputLatencySource {
    enum Metrics {
        static let maxDelay: TimeInterval = 0.5
        /// Used when a Bluetooth device reports no usable latency.
        static let fallbackDelay: TimeInterval = 0.18
    }

    // MARK: Rule (pure)

    /// (device latency + safety offset + stream latency) / sample rate, Bluetooth transports only.
    /// Buffer size is left out: the built-in speaker has the same amount, so it does not add to the difference.
    static func delay(transport: UInt32, deviceLatency: UInt32, safetyOffset: UInt32,
                      streamLatency: UInt32, sampleRate: Double, enabled: Bool) -> TimeInterval {
        guard enabled, isBluetooth(transport) else { return 0 }
        let frames = Double(deviceLatency) + Double(safetyOffset) + Double(streamLatency)
        guard frames > 0, sampleRate > 0 else { return Metrics.fallbackDelay }
        return min(max(frames / sampleRate, 0), Metrics.maxDelay)
    }

    static func isBluetooth(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: State

    var onChange: ((TimeInterval) -> Void)?
    private(set) var seconds: TimeInterval = 0
    private let isEnabled: () -> Bool
    private var started = false
    private var watchedDevice: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var lastLogged: (transport: UInt32, ms: Int, applied: Bool)?

    init(isEnabled: @escaping () -> Bool = { true }) { self.isEnabled = isEnabled }

    deinit { stop() }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.deviceChanged() }
        systemBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        watchCurrentDevice()
        update(notify: false)
    }

    func stop() {
        guard started else { return }
        started = false
        if let systemBlock {
            var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, systemBlock)
        }
        systemBlock = nil
        unwatchDevice()
    }

    func refresh() { if started { update(notify: true) } }

    // MARK: Watching

    private static let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
        (kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
    ]

    private func deviceChanged() {
        watchCurrentDevice()
        update(notify: true)
    }

    /// Moves the per-device listeners to the current default output; the old device's are removed first.
    private func watchCurrentDevice() {
        let device = Self.defaultOutputDevice()
        guard device != watchedDevice else { return }
        unwatchDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.update(notify: true) }
        deviceBlock = block
        watchedDevice = device
        for (selector, scope) in Self.watched {
            var addr = Self.address(selector, scope)
            AudioObjectAddPropertyListenerBlock(device, &addr, .main, block)
        }
    }

    private func unwatchDevice() {
        if let deviceBlock, watchedDevice != AudioObjectID(kAudioObjectUnknown) {
            for (selector, scope) in Self.watched {
                var addr = Self.address(selector, scope)
                AudioObjectRemovePropertyListenerBlock(watchedDevice, &addr, .main, deviceBlock)
            }
        }
        deviceBlock = nil
        watchedDevice = AudioObjectID(kAudioObjectUnknown)
    }

    private func update(notify: Bool) {
        let device = Self.defaultOutputDevice()
        let enabled = isEnabled()
        let transport = Self.read(UInt32.self, device, kAudioDevicePropertyTransportType) ?? 0
        let value = Self.delay(
            transport: transport,
            deviceLatency: Self.read(UInt32.self, device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) ?? 0,
            safetyOffset: Self.read(UInt32.self, device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) ?? 0,
            streamLatency: Self.firstOutputStreamLatency(device),
            sampleRate: Self.read(Float64.self, device, kAudioDevicePropertyNominalSampleRate) ?? 0,
            enabled: enabled)
        let entry = (transport: transport, ms: Int((value * 1000).rounded()), applied: enabled && value > 0)
        if lastLogged == nil || lastLogged! != entry {
            lastLogged = entry
            log.notice("output transport=\(Self.fourCC(transport), privacy: .public) delay_ms=\(entry.ms, privacy: .public) applied=\(entry.applied, privacy: .public)")
        }
        guard value != seconds else { return }
        seconds = value
        if notify { onChange?(value) }
    }

    // MARK: CoreAudio reads

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        read(AudioObjectID.self, AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
            ?? AudioObjectID(kAudioObjectUnknown)
    }

    private static func read<T>(_ type: T.Type, _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        guard object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw) == noErr else { return nil }
        return raw.load(as: T.self)
    }

    private static func firstOutputStreamLatency(_ device: AudioObjectID) -> UInt32 {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return 0 }
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return 0 }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first else { return 0 }
        return read(UInt32.self, first, kAudioStreamPropertyLatency) ?? 0
    }

    private static func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(v) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
