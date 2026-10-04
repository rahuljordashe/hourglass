import AppKit
import Observation
import SwiftUI
import UsageCore

/// The fallback when no screen has a notch (lid closed on an external display, or an older Mac):
/// a small menu bar pill with the 5-hour ring and percentage, and the expanded view in a popover.
@MainActor
final class StatusItemController: NSObject {
    private let context: NotchContext
    private var item: NSStatusItem?
    private let popover = NSPopover()

    init(context: NotchContext) {
        self.context = context
        super.init()
        popover.behavior = .transient
        popover.animates = !context.ui.reduceMotion
        let host = NSHostingController(rootView:
            ExpandedView(context: context, showsNotchGap: false)
                .padding(14)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    var isShowing: Bool { item != nil }

    func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageLeading
        self.item = item
        refresh()
        observe()
        Log.ui.info("No notch screen: showing menu bar pill")
    }

    func hide() {
        popover.performClose(nil)
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func observe() {
        withObservationTracking {
            _ = context.store.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.item != nil else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func refresh() {
        guard let button = item?.button else { return }
        let state = context.store.state
        let five = state.fiveHour
        let dimmed = state.freshness == .stale || state.freshness == .none
        let ring = UsageRing(fraction: five?.fraction ?? 0, color: Theme.color(for: five?.level ?? .normal), lineWidth: 2.2, isDimmed: dimmed)
            .frame(width: 14, height: 14)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: ring)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        button.image = renderer.nsImage
        button.title = five.map { " " + UsageFormat.percent($0.percentage) } ?? " --"
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityLabel(CompactAccessibility.label(state))
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            context.ui.mode = .expanded
            context.refresher.request(.expand)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
