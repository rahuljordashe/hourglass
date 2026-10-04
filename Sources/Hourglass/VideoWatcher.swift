import AppKit
import IOKit.pwr_mgt
import UsageCore

/// Notices video playing (any app holding a display-awake power assertion, see `VideoSignal`)
/// so the resting indicators can step aside. Public API, no permission prompt.
///
/// There's no notification for assertion changes, so it samples every two seconds: one call to
/// the power daemon. It stops while the displays are asleep.
@MainActor
final class VideoWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var isWatching = false

    private var state = VideoHideState()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    static let interval: TimeInterval = 2

    func start() {
        resume()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
    }

    private func resume() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let holders = Self.displayAwakeHolders()
        if state.update(playing: !holders.isEmpty, now: Date()) {
            isWatching = state.isWatching
            Log.ui.info("Video \(self.isWatching ? "started" : "stopped", privacy: .public): \(holders.joined(separator: ", "), privacy: .public)")
            onChange?(isWatching)
        }
    }

    static func displayAwakeHolders() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess, let dict = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }
        var byProcess: [Int32: [[String: Any]]] = [:]
        for (pid, assertions) in dict { byProcess[pid.int32Value] = assertions }
        return VideoSignal.holders(byProcess, ownPid: ProcessInfo.processInfo.processIdentifier) { pid in
            if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
            var buffer = [UInt8](repeating: 0, count: 256)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
