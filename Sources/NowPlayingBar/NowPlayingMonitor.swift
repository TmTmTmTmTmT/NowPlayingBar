import Foundation

/// Drives the `mediaremote-adapter` Perl bridge and surfaces Now Playing
/// updates on the main thread.
final class NowPlayingMonitor {
    private let perlURL = URL(fileURLWithPath: "/usr/bin/perl")
    private let scriptURL: URL
    private let frameworkURL: URL

    private var streamProcess: Process?
    /// Byte buffer for partial lines received from the stream.
    private var buffer = Data()
    /// Logical start of unprocessed data in `buffer`. Avoids reallocating
    /// the Data on every newline; compacted periodically.
    private var bufferStart = 0
    private let newline = Data([0x0A])
    private var stopped = false

    var onUpdate: ((NowPlayingInfo?) -> Void)?

    init(scriptURL: URL, frameworkURL: URL) {
        self.scriptURL = scriptURL
        self.frameworkURL = frameworkURL
    }

    var adapterExists: Bool {
        FileManager.default.fileExists(atPath: scriptURL.path)
            && FileManager.default.fileExists(atPath: frameworkURL.path)
    }

    func start() {
        stopped = false
        launchStream()   // stream sends initial state immediately on connect
    }

    func stop() {
        stopped = true
        streamProcess?.terminate()
        streamProcess = nil
    }

    // MARK: - Live stream

    private func launchStream() {
        guard !stopped else { return }

        let process = Process()
        process.executableURL = perlURL
        process.arguments = [
            scriptURL.path, frameworkURL.path,
            "stream", "--no-diff", "--no-artwork", "--debounce=150"
        ]

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }

        process.terminationHandler = { [weak self] _ in
            guard let self, !self.stopped else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.launchStream()
            }
        }

        do {
            try process.run()
            streamProcess = process
        } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.launchStream()
            }
        }
    }

    /// Splits incoming bytes into newline-delimited JSON lines without
    /// reallocating the buffer on every line.
    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let relRange = buffer[bufferStart...].range(of: newline) {
            let lineSlice = buffer[bufferStart..<relRange.lowerBound]
            bufferStart = relRange.upperBound
            guard !lineSlice.isEmpty else { continue }
            let info = NowPlayingParser.parse(lineSlice)
            DispatchQueue.main.async { [weak self] in self?.onUpdate?(info) }
        }
        // Compact once the consumed prefix grows large to reclaim memory.
        if bufferStart > 8_192 {
            buffer = Data(buffer[bufferStart...])
            bufferStart = 0
        }
    }

    // MARK: - Playback control

    /// Runs a fire-and-forget adapter command (output discarded).
    private func runAdapter(_ arguments: [String]) {
        let process = Process()
        process.executableURL = perlURL
        process.arguments = [scriptURL.path, frameworkURL.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    func send(command id: Int) {
        runAdapter(["send", String(id)])
    }

    /// Seeks the now-playing app to `seconds`. The adapter expects the timeline
    /// position in **microseconds**.
    func seek(to seconds: Double) {
        let micros = Int64(max(0, seconds) * 1_000_000)
        runAdapter(["seek", String(micros)])
    }

    // MARK: - One-shot detail fetch (for the control popover)

    /// Fetches a full snapshot incl. artwork via a one-shot `get`. Runs the
    /// process + base64/image decode off the main thread; calls back on main.
    /// Drains the pipe while the process writes to avoid a 64 KB-buffer deadlock
    /// (artwork payloads are ~160 KB).
    func fetchDetail(_ completion: @escaping (NowPlayingDetail?) -> Void) {
        let process = Process()
        process.executableURL = perlURL
        process.arguments = [scriptURL.path, frameworkURL.path, "get"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        DispatchQueue.global(qos: .userInitiated).async {
            do { try process.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let detail = NowPlayingParser.parseDetail(data)
            DispatchQueue.main.async { completion(detail) }
        }
    }

    // MARK: - Shuffle / repeat state (Apple Music only)

    /// Reads Music.app's shuffle/repeat state via osascript. Off the main
    /// thread; calls back on main. Non-Music sources report `.unsupported`.
    func fetchModes(for bundleID: String, completion: @escaping (ModesResult) -> Void) {
        guard bundleID == "com.apple.Music" else {
            DispatchQueue.main.async { completion(.unsupported) }
            return
        }

        let script = """
        if application "Music" is running then
          tell application "Music" to return ((shuffle enabled) as string) & "," & ((song repeat) as string)
        else
          return "notrunning"
        end if
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            do { try process.run() } catch {
                DispatchQueue.main.async { completion(.failed) }
                return
            }

            // Safety net: kill a hung osascript (e.g. stuck permission prompt).
            var timedOut = false
            let lock = NSLock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning {
                    lock.lock(); timedOut = true; lock.unlock()
                    process.terminate()
                }
            }

            // Drain stderr concurrently so neither pipe can fill and block.
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            group.wait()

            lock.lock(); let didTimeOut = timedOut; lock.unlock()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            let result: ModesResult
            if didTimeOut {
                result = .failed
            } else if stderr.contains("-1743") || stderr.contains("Not authorized") {
                result = .denied
            } else if process.terminationStatus == 0, let modes = PlaybackModes.parse(stdout) {
                result = .modes(modes)
            } else {
                result = .failed
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
