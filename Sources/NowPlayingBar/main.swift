import AppKit

// Resources are bundled in Contents/Resources when packaged as a .app.
// Fall back to the build/ layout when run straight from the package directory.
private func resolveResourceDir() -> URL {
    if let bundled = Bundle.main.resourceURL,
       FileManager.default.fileExists(atPath: bundled.appendingPathComponent("mediaremote-adapter.pl").path) {
        return bundled
    }
    // Dev fallback: ./build/NowPlayingBar.app/Contents/Resources
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return cwd.appendingPathComponent("build/NowPlayingBar.app/Contents/Resources")
}

let resourceDir = resolveResourceDir()
let scriptURL = resourceDir.appendingPathComponent("mediaremote-adapter.pl")
let frameworkURL = resourceDir.appendingPathComponent("MediaRemoteAdapter.framework")

let app = NSApplication.shared
let delegate = AppDelegate(scriptURL: scriptURL, frameworkURL: frameworkURL)
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
