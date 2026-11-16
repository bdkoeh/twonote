// The end-to-end run's stand-in for another app's Share menu (Safari's, Notes'): a small
// process that shares a web address through the "TwoNote" sharing service, i.e. the real share
// extension, in its own process. (TwoNote itself cannot: macOS leaves an app's own share
// extension out of that app's Share menu.) Built and started by tools/e2e-mac-control.py.
//
//   e2e-mac-share <url>          share it; exit 0 when the extension reports it shared
//   e2e-mac-share --list <url>   only print the sharing services offered for it
//
// Uses no permission: no Apple events, no accessibility, no screen recording. The extension's
// Debug build saves by itself when the run asked it to (a marker file the app wrote); a person
// would click Save.
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let listOnly = arguments.first == "--list"
guard let text = arguments.last, let url = NSURL(string: text) else {
    print("usage: e2e-mac-share [--list] <url>")
    exit(64)
}

final class Host: NSObject, NSSharingServiceDelegate {
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320),
                          styleMask: [.titled], backing: .buffered, defer: false)

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        print("shared")
        exit(0)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        print("failed: \(error)")
        exit(4)
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        window
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let items: [Any] = [url]
let services = NSSharingService.sharingServices(forItems: items)
print("services: \(services.map(\.title))")
if listOnly { exit(0) }
guard let service = services.first(where: { $0.title == "TwoNote" }) else {
    print("TwoNote is not offered")
    exit(3)
}
let host = Host()
host.window.title = "Share Helper"
host.window.center()
host.window.makeKeyAndOrderFront(nil)
service.delegate = host
DispatchQueue.main.async {
    app.activate()
    service.perform(withItems: items)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
    print("timed out")
    exit(5)
}
app.run()
