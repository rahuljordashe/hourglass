import AppKit
import SwiftUI
import UsageCore

/// Development aid: `Hourglass --render-previews <folder>` draws each notch state with the
/// saved reading to PNGs (no screen recording needed) and quits.
@MainActor
enum PreviewRenderer {
    static func run(context: NotchContext, into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ui = context.ui
        ui.geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                    notchWidth: 185, notchHeight: 32, notchMidX: 864)
        let state = context.store.state
        var modes: [(String, NotchUIModel.Mode, Bool)] = [
            ("rest", .compact, false), ("rest-video", .compact, true), ("peek", .peek, false), ("open", .expanded, false)
        ]
        if let five = state.fiveHour {
            modes.append(("alert", .alert(UsageAlert(window: .fiveHour, kind: .threshold(75), percentage: five.percentage, resetsAt: five.resetsAt)), false))
        }
        for (name, mode, hidden) in modes {
            ui.mode = mode
            ui.earsHidden = hidden
            let size = mode == .compact ? CGSize(width: 300, height: 32) : NotchGeometry.openSize
            let view = NotchRootView(context: context)
                .environment(\.isStaticRender, true)
                .frame(width: size.width + 40, height: size.height)
                .background(Color(red: 0.07, green: 0.08, blue: 0.2))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: folder.appending(path: "\(name).png"))
        }
        print("Rendered previews to \(folder.path)")
    }

    /// `--snapshot-live <folder>`: drives a real, off-screen panel through rest, peek, open and
    /// back with the live overlay and animations, and saves each settled state. Checks that the
    /// travelling figures land on their slots, which still images can't show.
    static func snapshotLive(context: NotchContext, into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ui = context.ui
        let geometry = NotchGeometry(screenFrame: CGRect(x: -6000, y: 0, width: 1728, height: 1117),
                                     notchWidth: 185, notchHeight: 32, notchMidX: -6000 + 864)
        ui.geometry = geometry
        ui.reduceMotion = false
        let panel = NotchPanel(rootView: NotchRootView(context: context))
        panel.place(geometry.openWindowFrame, geometry: geometry)
        panel.orderFrontRegardless()

        let steps: [(String, NotchUIModel.Mode, Animation)] = [
            ("1-rest", .compact, Motion.close), ("2-peek", .peek, Motion.open),
            ("3-open", .expanded, Motion.open), ("4-rest-again", .compact, Motion.close)
        ]
        func run(_ index: Int) {
            guard index < steps.count else {
                print("Snapshots in \(folder.path)")
                exit(0)
            }
            let (name, mode, animation) = steps[index]
            withAnimation(animation) { ui.mode = mode }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
                }
                let slots = Figure.allCases.compactMap { figure -> String? in
                    ui.slots[FigureSlotKey(figure: figure, tag: ui.slotTag)].map { "\(figure)=\($0.integral)" }
                }
                print(name, slots.joined(separator: " "))
                run(index + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(0) }
    }
}
