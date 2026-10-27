import Foundation

/// Logs when the main thread stops responding (everything on screen freezes while it is blocked,
/// e.g. the overlay's waveform → spinner animation). A background thread pings the main thread
/// every 100 ms; an answer later than 120 ms is logged with how long it took, so the next
/// "it looked frozen" report can be matched to what Mowa was doing at that moment in the log.
enum MainThreadWatchdog {
    private static let threshold: TimeInterval = 0.12

    static func start() {
        let thread = Thread {
            while true {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + threshold) == .timedOut {
                    answered.wait()
                    let blocked = Date().timeIntervalSince(sent)
                    Log.error(String(format: "Main thread was blocked for %.2fs", blocked))
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.name = "Mowa main-thread watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
