import AppKit

// A nonactivating panel normally cannot change the onscreen cursor while another app has focus.
// Use the optional WindowServer property only for the duration of a cursor update.
enum PanelCursor {
    private typealias ConnectionID = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static let setBackgroundCursor: ((NSCursor) -> Void)? = {
        guard let process = dlopen(nil, RTLD_LAZY),
              let connectionSymbol = dlsym(process, "CGSMainConnectionID"),
              let propertySymbol = dlsym(process, "CGSSetConnectionProperty") else { return nil }
        let connectionID = unsafeBitCast(connectionSymbol, to: ConnectionID.self)
        let setProperty = unsafeBitCast(propertySymbol, to: SetProperty.self)
        return { cursor in
            let connection = connectionID()
            let key = "SetsCursorInBackground" as CFString
            guard setProperty(connection, connection, key, kCFBooleanTrue) == 0 else { cursor.set(); return }
            defer { _ = setProperty(connection, connection, key, kCFBooleanFalse) }
            cursor.set()
        }
    }()

    static func set(_ cursor: NSCursor) {
        // Clicking a nonactivating panel can make AppKit report active while
        // another process still owns the system cursor.
        if let setBackgroundCursor { setBackgroundCursor(cursor) }
        else { cursor.set() }
    }
}
