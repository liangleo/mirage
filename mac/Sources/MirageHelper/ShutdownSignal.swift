import Foundation
import Darwin

/// Routes SIGTERM/SIGINT to a handler so the helper can stop its capture
/// stream and tear down the virtual display before exiting. A plain
/// `signal()` handler cannot run this cleanup, and a bare kill leaves the
/// ScreenCaptureKit session open, which keeps the system's screen-recording
/// indicator lit until it times out.
public final class ShutdownSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var installed: [Int32] = []

    public init() {}

    public func install(handler: @escaping @Sendable () -> Void) {
        for sig in [SIGTERM, SIGINT] {
            // DispatchSource only sees the signal if the default action is ignored.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler(handler: handler)
            source.resume()
            lock.lock()
            sources.append(source)
            installed.append(sig)
            lock.unlock()
        }
    }

    public func uninstall() {
        lock.lock()
        let sources = self.sources
        let installed = self.installed
        self.sources = []
        self.installed = []
        lock.unlock()
        for source in sources {
            source.cancel()
        }
        for sig in installed {
            signal(sig, SIG_DFL)
        }
    }
}