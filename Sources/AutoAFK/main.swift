import AppKit

// Retained for the lifetime of the process (NSApplication.delegate is weak).
let appDelegate: AppDelegate = MainActor.assumeIsolated { AppDelegate() }

let application = NSApplication.shared
application.delegate = appDelegate
application.run()
