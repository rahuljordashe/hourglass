import SwiftUI
import UsageCore

enum EditorTab: String, CaseIterable, Identifiable {
    case faces, left, right, hover, open

    var id: Self { self }

    var title: String {
        switch self {
        case .faces: "Faces"
        case .left: "Left ear"
        case .right: "Right ear"
        case .hover: "Hover"
        case .open: "Open"
        }
    }

    var side: NotchLayout.Side? {
        switch self {
        case .left: .left
        case .right: .right
        default: nil
        }
    }
}

/// The notch editor. The open panel turns into it; its top row keeps both ears where they rest,
/// showing what they'd show, so the preview is the real notch. Hovering a face or tile tries it
/// on the ears, moving away puts the saved choice back, and clicking keeps it. Everything saves
/// as it changes, so Done only closes.
struct NotchEditorView: View {
    let context: NotchContext

    var body: some View {
        let ui = context.ui
        let rm = ui.reduceMotion
        VStack(alignment: .leading, spacing: 0) {
            EditorEarsRow(context: context)
            VStack(alignment: .leading, spacing: 12) {
                tabs.entrance(0, rm)
                Group {
                    switch ui.editorTab {
                    case .faces: FacesGrid(context: context)
                    case .left: EarItemGrid(context: context, side: .left)
                    case .right: EarItemGrid(context: context, side: .right)
                    case .hover: HoverEditor(context: context)
                    case .open: OpenEditor(context: context)
                    }
                }
                .entrance(1, rm)
                footer.entrance(2, rm)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabs: some View {
        let ui = context.ui
        return HStack(spacing: 2) {
            ForEach(EditorTab.allCases) { tab in
                let selected = ui.editorTab == tab
                Button {
                    ui.preview = nil
                    ui.editorTab = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(Color.white.opacity(selected ? 0.95 : 0.55))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(selected ? 0.14 : 0), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 6)
            Button(action: context.actions.collapse) {
                Text("Done")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Your choices are already saved")
        }
    }

    private var footer: some View {
        let ui = context.ui
        let isDefault = ui.layout == .default
        return HStack {
            Button("Reset to default") { ui.commit(.default) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(isDefault ? 0.25 : 0.6))
                .disabled(isDefault)
            Spacer(minLength: 6)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.38))
        }
    }

    private var hint: String {
        switch context.ui.editorTab {
        case .faces, .left, .right: "Hover to try, click to keep"
        case .hover, .open: "Changes save as you go"
        }
    }
}

// MARK: - Top row

/// The notch band of the editor: both ears exactly where they rest, outlined. The selected ear
/// (the Left ear or Right ear tab) is solid blue; clicking an ear opens its tab.
struct EditorEarsRow: View {
    let context: NotchContext

    var body: some View {
        let ui = context.ui
        let sideWidth = (NotchGeometry.openSize.width - ui.notchWidth) / 2
        HStack(spacing: 0) {
            ear(.left).frame(width: sideWidth, alignment: .trailing)
            Color.clear.frame(width: ui.notchWidth)
            ear(.right).frame(width: sideWidth, alignment: .leading)
        }
        .frame(height: ui.notchHeight)
    }

    private func ear(_ side: NotchLayout.Side) -> some View {
        let ui = context.ui
        let selected = ui.editorTab.side == side
        let item = ui.shownLayout[side]
        return EarItemView(item: item, side: side, state: context.store.state, now: context.store.now, memory: ui)
            .frame(height: ui.notchHeight)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.white.opacity(0.38),
                                  style: selected ? StrokeStyle(lineWidth: 1.5) : StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                    .padding(.vertical, 3)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                ui.preview = nil
                ui.editorTab = side == .left ? .left : .right
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(side == .left ? "Left" : "Right") ear: \(item.title)")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Try then keep

/// Hovering shows `candidate` on the ears; leaving restores the saved layout; clicking saves it.
struct TryOnHover: ViewModifier {
    let candidate: NotchLayout
    let ui: NotchUIModel

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    ui.preview = candidate
                } else if ui.preview == candidate {
                    ui.preview = nil
                }
            }
            .onTapGesture { ui.commit(candidate) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { ui.commit(candidate) }
    }
}

extension View {
    func tryOnHover(_ candidate: NotchLayout, ui: NotchUIModel) -> some View {
        modifier(TryOnHover(candidate: candidate, ui: ui))
    }
}

/// A tile's frame: a card that brightens under the pointer, outlined in blue when it's the saved
/// choice.
struct TileBackground: View {
    let selected: Bool
    let trying: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape.fill(Color.white.opacity(trying ? 0.12 : 0.06))
            .overlay {
                shape.strokeBorder(selected ? Theme.accent : Color.white.opacity(trying ? 0.18 : 0),
                                   lineWidth: selected ? 1.5 : 1)
            }
    }
}

// MARK: - Faces

struct FacesGrid: View {
    let context: NotchContext

    var body: some View {
        let ui = context.ui
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Face.allCases, id: \.self) { face in
                let candidate = ui.layout.with(face)
                VStack(spacing: 7) {
                    HStack(spacing: 0) {
                        EarItemView(item: face.left, side: .left, state: context.store.state, now: context.store.now, memory: ui)
                        Color.clear.frame(width: 26)
                        EarItemView(item: face.right, side: .right, state: context.store.state, now: context.store.now, memory: ui)
                    }
                    .frame(height: ui.notchHeight)
                    .background(MiniNotch())
                    Text(face.title).font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(TileBackground(selected: ui.layout.face == face, trying: ui.preview == candidate))
                .tryOnHover(candidate, ui: ui)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(face.title): \(face.left.title) and \(face.right.title)")
                .accessibilityAddTraits(ui.layout.face == face ? .isSelected : [])
            }
        }
    }
}

/// A short stretch of black notch with its ears, for a tile.
struct MiniNotch: View {
    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
            .fill(Color.black)
            .overlay {
                // The camera housing between the ears.
                Capsule().fill(Color.white.opacity(0.07)).frame(width: 14, height: 2).offset(y: -8)
            }
    }
}

// MARK: - Ear items

struct EarItemGrid: View {
    let context: NotchContext
    let side: NotchLayout.Side

    var body: some View {
        let ui = context.ui
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(EarItem.allCases, id: \.self) { item in
                let candidate = ui.layout.with(item, on: side)
                VStack(spacing: 6) {
                    EarTileDrawing(item: item, side: side, context: context)
                    Text(item.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .lineLimit(1)
                    if let note = note(item) {
                        Text(note)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(item.isWide ? Theme.warning : Color.white.opacity(0.42))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .top)
                .padding(.vertical, 8)
                .background(TileBackground(selected: ui.layout[side] == item, trying: ui.preview == candidate))
                .tryOnHover(candidate, ui: ui)
                .help(item.isWide ? "This ear widens to 46 pt and can cover a menu bar icon." : "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([item.title, note(item)].compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(ui.layout[side] == item ? .isSelected : [])
            }
        }
    }

    private func note(_ item: EarItem) -> String? {
        if item.isWide { return "\(Int(item.earWidth)) pt" }
        if item == .warningDot { return "from \(Int(EarItem.warningDotThreshold))%" }
        return nil
    }
}

/// An item drawn live in its ear, beside a short piece of the notch so its edge shows.
struct EarTileDrawing: View {
    let item: EarItem
    let side: NotchLayout.Side
    let context: NotchContext

    var body: some View {
        let ear = EarItemView(item: item, side: side, state: context.store.state, now: context.store.now, memory: context.ui,
                              showsIdleDot: true)
        let notch = Color.clear.frame(width: 14)
            .overlay(alignment: side == .left ? .leading : .trailing) {
                // The notch's edge, where the camera housing starts.
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1).padding(.vertical, 6)
            }
        HStack(spacing: 0) {
            if side == .left { ear; notch } else { notch; ear }
        }
        .frame(height: context.ui.notchHeight)
        .background {
            UnevenRoundedRectangle(bottomLeadingRadius: side == .left ? 8 : 0, bottomTrailingRadius: side == .right ? 8 : 0, style: .continuous)
                .fill(Color.black)
        }
    }
}

// MARK: - Hover

struct HoverEditor: View {
    let context: NotchContext

    var body: some View {
        let ui = context.ui
        VStack(alignment: .leading, spacing: 10) {
            // A live copy of the peek, as wide as the real one.
            PeekView(context: context, inEditor: true)
                .frame(width: 320)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                option("Time tick on the bars", detail: "How much of each window has passed", \.timeTick)
                divider
                option("Weekly budget line", detail: "How much of the week you can use per day", \.budgetLine)
                divider
                option("Reset times", detail: "The clock time and the time left", \.resetTimes)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .animation(ui.reduceMotion ? Motion.fade : Motion.open, value: ui.layout.hover)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 12)
    }

    private func option(_ title: String, detail: String, _ key: WritableKeyPath<HoverOptions, Bool>) -> some View {
        let ui = context.ui
        let on = ui.layout.hover[keyPath: key]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer(minLength: 6)
            NotchSwitch(isOn: on)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            var layout = ui.layout
            layout.hover[keyPath: key] = !on
            ui.commit(layout)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            var layout = ui.layout
            layout.hover[keyPath: key] = !on
            ui.commit(layout)
        }
    }
}

// MARK: - Open

/// The open panel drawn in place. The 5-hour and weekly rows are fixed; each section below them
/// can be shown or hidden and moved up or down.
struct OpenEditor: View {
    let context: NotchContext

    var body: some View {
        let ui = context.ui
        let now = context.store.now
        let open = ui.layout.open
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                fixedRow(.fiveHour)
                fixedRow(.sevenDay)
            }
            ForEach(open.order, id: \.self) { section in
                let shown = open.isShown(section)
                VStack(alignment: .leading, spacing: 6) {
                    controls(section, shown: shown)
                    Group {
                        if OpenSectionView.hasContent(section, state: context.store.state, now: now) {
                            OpenSectionView(section: section, context: context, now: now)
                        } else {
                            Text("Shows when there's a reading for it")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.35))
                        }
                    }
                    .opacity(shown ? 1 : 0.3)
                    .allowsHitTesting(false)
                }
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .animation(ui.reduceMotion ? Motion.fade : Motion.open, value: open)
    }

    /// A compact copy of a limit row, dimmed: always shown, can't be moved.
    private func fixedRow(_ kind: UsageWindowKind) -> some View {
        let state = context.store.state
        let status = state.window(kind)
        let ready = state.isReady(kind)
        return HStack(spacing: 10) {
            Text(kind == .fiveHour ? "5-hour limit" : "Weekly limit").font(.system(size: 12, weight: .medium))
            HairBar(fraction: ready ? 0 : status?.fraction ?? 0,
                    color: ready ? Theme.ready : Shade.color(status?.level ?? .normal, stale: state.freshness == .stale),
                    height: 3)
            Text(ready ? "Ready" : status.map { UsageFormat.percent($0.percentage) } ?? "--")
                .font(.system(size: 12)).monospacedDigit()
                .frame(width: 36, alignment: .trailing)
            Label("Fixed", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .opacity(0.5)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Always shown")
    }

    private func controls(_ section: OpenLayout.Section, shown: Bool) -> some View {
        let ui = context.ui
        let open = ui.layout.open
        func change(_ edit: (inout OpenLayout) -> Void) {
            var layout = ui.layout
            edit(&layout.open)
            ui.commit(layout)
        }
        return HStack(spacing: 6) {
            Button { change { $0.setShown(section, !shown) } } label: {
                HStack(spacing: 8) {
                    NotchSwitch(isOn: shown)
                    Text(section.title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(shown ? 0.95 : 0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show \(section.title)")
            .accessibilityValue(shown ? "On" : "Off")
            Spacer(minLength: 4)
            arrow("chevron.up", "Move \(section.title) up", enabled: open.canMove(section, by: -1)) { change { $0.move(section, by: -1) } }
            arrow("chevron.down", "Move \(section.title) down", enabled: open.canMove(section, by: 1)) { change { $0.move(section, by: 1) } }
        }
    }

    private func arrow(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(enabled ? 0.75 : 0.2))
                .frame(width: 22, height: 20)
                .background(Color.white.opacity(enabled ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// A small switch drawn in SwiftUI: AppKit's switch greys out in a window that isn't key, and
/// the notch panel never is.
struct NotchSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.accent : Color.white.opacity(0.18))
            .frame(width: 26, height: 15)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(Color.white).frame(width: 12, height: 12).padding(1.5)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

// MARK: - One-time hint

/// After installing: a short note that the notch can be customised. Clicking opens the editor.
struct HintView: View {
    let context: NotchContext

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Theme.accent, lineWidth: 2.5)
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose what the notch shows").font(.system(size: 13, weight: .semibold))
                Text("Right-click the notch, or use the ••• menu")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, context.ui.notchHeight + 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .entrance(0, context.ui.reduceMotion)
        .contentShape(Rectangle())
        .onTapGesture { context.actions.customise() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
