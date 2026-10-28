import AppKit

/// One running viw per login session. A second `viw file.md` hands its arguments to the
/// first process over a CFMessagePort (so the file opens as a new tab there) and exits.
enum SingleInstance {
    private static let portName = "com.td72.viw.open"

    struct Request: Codable {
        var files: [String] = []
        var stdin: String?
    }

    /// Try to hand `request` to an already running instance. Returns true when it was
    /// accepted (the caller should exit), false when no instance is listening.
    static func forward(_ request: Request) -> Bool {
        guard let port = CFMessagePortCreateRemote(nil, portName as CFString),
              let data = try? JSONEncoder().encode(request) else { return false }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 0, data as CFData, 5, 5, CFRunLoopMode.defaultMode.rawValue, &reply)
        CFMessagePortInvalidate(port)
        guard status == kCFMessagePortSuccess else { return false }
        // The reply carries the server pid; bring it to the front (we are about to exit).
        if let d = reply?.takeRetainedValue() as Data?,
           let pid = Int32(String(decoding: d, as: UTF8.self)),
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        return true
    }

    /// Server side: owns the local port for the lifetime of the object.
    final class Listener {
        private var port: CFMessagePort?
        private let handler: (Request) -> Void

        init?(handler: @escaping (Request) -> Void) {
            self.handler = handler
            var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: CFMessagePortCallBack = { _, _, data, info in
                guard let info, let data else { return nil }
                let listener = Unmanaged<Listener>.fromOpaque(info).takeUnretainedValue()
                if let req = try? JSONDecoder().decode(Request.self, from: data as Data) {
                    DispatchQueue.main.async { listener.handler(req) }
                }
                let pid = String(ProcessInfo.processInfo.processIdentifier)
                return Unmanaged.passRetained(pid.data(using: .utf8)! as CFData)
            }
            guard let port = CFMessagePortCreateLocal(nil, portName as CFString, callback, &context, nil) else {
                return nil // another instance already owns the name
            }
            self.port = port
            let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        deinit { if let port { CFMessagePortInvalidate(port) } }
    }
}
