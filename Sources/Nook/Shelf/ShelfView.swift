import AppKit
import NookCore
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @Bindable var shelf: ShelfController
    @Bindable var notch: NotchModel
    var quickLook: ([URL], Int) -> Void

    @State private var composingNote = false
    @State private var noteText = ""
    @FocusState private var noteFocused: Bool
    @FocusState private var gridFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            notices
            ZStack {
                if composingNote {
                    noteComposer
                } else if let reason = shelf.unavailableReason {
                    StatusBadge(text: "Shelf storage is unavailable: \(reason)", tone: .danger)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shelf.items.isEmpty {
                    emptyState
                } else {
                    itemsView
                }
                if notch.dropTargetActive { dropOverlay }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.18), value: shelf.items.map(\.id))
        .animation(.easeOut(duration: 0.18), value: notch.dropTargetActive)
        .background { if !composingNote { keyboardCommands } }
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            if !shelf.items.isEmpty && !composingNote { gridFocused = true }
        }
    }

    /// Keyboard equivalents for every Shelf action (the context menu isn't the only way in).
    private var keyboardCommands: some View {
        ZStack {
            Button("Save a Copy As") { if let item = shelf.selectedItems.first { shelf.presentSaveAs(item) } }
                .keyboardShortcut("s", modifiers: .command)
            Button("Move To") { if !shelf.selection.isEmpty { shelf.presentMoveTo(Array(shelf.selection)) } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Copy") { if let item = shelf.selectedItems.first { shelf.copyToClipboard(item) } }
                .keyboardShortcut("c", modifiers: .command)
            Button("Remove") { shelf.remove(Array(shelf.selection)) }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Undo Remove") { shelf.undoLastRemoval() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Select All") { shelf.selection = Set(shelf.items.map(\.id)); gridFocused = true }
                .keyboardShortcut("a", modifiers: .command)
            Button("Quick Look") { quickLookSelection() }
                .keyboardShortcut("y", modifiers: .command)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Shelf").font(.system(size: 15, weight: .semibold)).foregroundStyle(Nook.Palette.primaryText)
            if !shelf.items.isEmpty {
                Text("\(shelf.items.count) · \(ByteCountFormatter.string(fromByteCount: shelf.storageBytes, countStyle: .file))")
                    .font(.system(size: 11)).foregroundStyle(Nook.Palette.tertiaryText)
                    .accessibilityLabel("\(shelf.items.count) items, \(ByteCountFormatter.string(fromByteCount: shelf.storageBytes, countStyle: .file)) stored")
            }
            if shelf.importsInFlight > 0 {
                StatusBadge(text: "Adding \(shelf.importsInFlight)…", tone: .working)
            }
            Spacer()
            GlassIconButton(systemImage: "plus", label: "Add Files…") { shelf.presentAddFilesPanel() }
            GlassIconButton(systemImage: "doc.on.clipboard", label: "Paste from Clipboard (⌘V)") { shelf.paste() }
                .keyboardShortcut(composingNote ? nil : KeyboardShortcut("v", modifiers: .command))
            GlassIconButton(systemImage: "square.and.pencil", label: "New Note") {
                composingNote = true
                noteFocused = true
            }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if !shelf.selection.isEmpty {
                Button("Move Selected To…") { shelf.presentMoveTo(Array(shelf.selection)) }
                Button("Remove Selected") { shelf.remove(Array(shelf.selection)) }
                Divider()
            }
            Menu("Recently Removed (\(shelf.recentlyRemoved.count))") {
                if shelf.recentlyRemoved.isEmpty {
                    Text("Nothing here")
                } else {
                    ForEach(shelf.recentlyRemoved.prefix(25)) { item in
                        Button("Restore “\(item.displayName)”") { shelf.restore(item.id) }
                    }
                    Divider()
                    Button("Delete All Now…") { shelf.confirmEmptyRecentlyRemoved() }
                }
            }
            Button("Show Shelf Folder in Finder") { shelf.revealStorageFolder() }
            Divider()
            Button("Clear Shelf…", role: .destructive) { shelf.confirmClearShelf() }
                .disabled(shelf.items.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Nook.Palette.primaryText.opacity(0.9))
                .frame(width: 26, height: 26)
                .darkGlass(in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Shelf actions")
        .accessibilityLabel("More Shelf actions")
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if let notice = shelf.reconciliationNotice {
            HStack(spacing: 8) {
                StatusBadge(text: notice, tone: .warning)
                Spacer()
                Button("Show Folder") { shelf.revealStorageFolder() }.buttonStyle(PillButtonStyle())
                Button("Dismiss") { shelf.reconciliationNotice = nil }.buttonStyle(PillButtonStyle())
            }
        }
        if !shelf.cleanupCandidates.isEmpty {
            HStack(spacing: 8) {
                StatusBadge(text: "\(shelf.cleanupCandidates.count) item(s) match your cleanup policy.", tone: .warning)
                Spacer()
                Button("Review…") { shelf.reviewCleanup() }.buttonStyle(PillButtonStyle())
            }
        }
        if let banner = shelf.banner {
            HStack(spacing: 8) {
                StatusBadge(text: banner.text, tone: tone(banner.tone))
                Spacer()
                if !banner.undoItemIDs.isEmpty {
                    Button("Undo") { shelf.undoRemoval(banner.undoItemIDs) }.buttonStyle(PillButtonStyle(prominent: true))
                }
            }
            .transition(.opacity)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func tone(_ t: ShelfController.Banner.Tone) -> StatusBadge.Tone {
        switch t {
        case .info: return .neutral
        case .success: return .success
        case .warning: return .warning
        case .failure: return .danger
        }
    }

    // MARK: Content

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 26, weight: .light))
            Text("Drop files, folders or text here").font(.system(size: 13, weight: .medium))
            Text("Nook keeps its own copy. Your originals stay where they are.")
                .font(.system(size: 11)).foregroundStyle(Nook.Palette.tertiaryText)
        }
        .foregroundStyle(Nook.Palette.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Nook.Palette.hairline, style: StrokeStyle(lineWidth: 1.2, dash: [5, 5])))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var itemsView: some View {
        Group {
            if notch.isLarge {
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) { tiles }
                        .padding(4)
                }
            } else {
                ScrollView(.horizontal) {
                    GlassContainerIfAvailable(spacing: 10) {
                        LazyHStack(alignment: .top, spacing: 10) { tiles }.padding(4)
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) { quickLookSelection(); return .handled }
        .onKeyPress(.leftArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.rightArrow) { moveSelection(1); return .handled }
        .onKeyPress(.delete) { shelf.remove(Array(shelf.selection)); return .handled }
        .onKeyPress(.deleteForward) { shelf.remove(Array(shelf.selection)); return .handled }
        .accessibilityLabel("Shelf items")
    }

    private var tiles: some View {
        ForEach(shelf.items) { item in
            ShelfTile(
                item: item,
                shelf: shelf,
                isSelected: shelf.selection.contains(item.id),
                isDragging: shelf.draggingIDs.contains(item.id),
                quickLook: { openQuickLook(startingAt: item) }
            )
        }
    }

    private func openQuickLook(startingAt item: ShelfItem) {
        let previewable = shelf.items.filter { $0.status != .missing }
        let urls = previewable.compactMap { shelf.contentURL($0) }
        let index = previewable.firstIndex { $0.id == item.id } ?? 0
        quickLook(urls, index)
    }

    private func quickLookSelection() {
        if let first = shelf.items.first(where: { shelf.selection.contains($0.id) }) { openQuickLook(startingAt: first) }
    }

    private func moveSelection(_ delta: Int) {
        guard !shelf.items.isEmpty else { return }
        let current = shelf.items.lastIndex { shelf.selection.contains($0.id) } ?? (delta > 0 ? -1 : shelf.items.count)
        let next = max(0, min(shelf.items.count - 1, current + delta))
        shelf.selection = [shelf.items[next].id]
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Nook.Palette.accent.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Nook.Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line.compact").font(.system(size: 24, weight: .semibold))
                    Text("Release to add to Shelf").font(.system(size: 13, weight: .semibold))
                    Text("A copy is stored; the original isn't moved").font(.system(size: 11)).opacity(0.7)
                }
                .foregroundStyle(Nook.Palette.accent)
            )
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityLabel("Drop target: release to add to Shelf")
    }

    private var noteComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $noteText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .foregroundStyle(Nook.Palette.primaryText)
                .padding(8)
                .glassField(focused: noteFocused)
                .focused($noteFocused)
                .accessibilityLabel("Note text")
            HStack {
                Text("Saved to the Shelf as a UTF-8 text item.").font(.system(size: 11)).foregroundStyle(Nook.Palette.tertiaryText)
                Spacer()
                Button("Cancel") { composingNote = false; noteText = "" }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save Note") {
                    shelf.importText(noteText, origin: .note)
                    noteText = ""
                    composingNote = false
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    let shelf: ShelfController
    let isSelected: Bool
    let isDragging: Bool
    let quickLook: () -> Void

    @State private var hovering = false
    @State private var thumbnail: NSImage?

    private var url: URL? { shelf.contentURL(item) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                preview
                    .frame(width: 64, height: 64)
                VStack(spacing: 1) {
                    Text(item.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Nook.Palette.primaryText)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Nook.Palette.tertiaryText).lineLimit(1)
                }
                .frame(width: 92, height: 42, alignment: .top)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .darkGlass(in: RoundedRectangle(cornerRadius: Nook.Glass.tileRadius, style: .continuous),
                       tint: isSelected ? Nook.Palette.accent.opacity(0.22) : Nook.Glass.tint,
                       highlighted: hovering)
            .overlay(
                RoundedRectangle(cornerRadius: Nook.Glass.tileRadius, style: .continuous)
                    .strokeBorder(Nook.Palette.accent.opacity(isSelected ? 0.75 : 0), lineWidth: 1.4)
                    .allowsHitTesting(false)
            )
            .opacity(isDragging ? 0.45 : 1)
            .overlay(dragSource)

            if hovering && !isDragging {
                HStack(spacing: 4) {
                    miniButton("eye", "Quick Look") { quickLook() }
                    miniButton("xmark", "Remove from Shelf") { shelf.remove([item.id]) }
                }
                .padding(5)
                .transition(.opacity)
            }
            if item.status == .missing {
                badge("exclamationmark.triangle.fill", Nook.Palette.danger, "The stored file is missing")
            } else if item.typeMismatch {
                badge("exclamationmark.shield.fill", Nook.Palette.warning, "This file's contents don't match its extension. Nook never opens files; be careful where you send it.")
            }
        }
        .onHover { hovering = $0 }
        .task(id: item.id) { await loadThumbnail() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.displayName), \(subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Quick Look") { quickLook() }
        .accessibilityAction(named: "Save As") { shelf.presentSaveAs(item) }
        .accessibilityAction(named: "Move To") { shelf.presentMoveTo([item.id]) }
        .accessibilityAction(named: "Remove") { shelf.remove([item.id]) }
    }

    @ViewBuilder
    private var preview: some View {
        if item.kind == .text {
            Text(item.textPreview ?? "")
                .font(.system(size: 7.5))
                .foregroundStyle(Color.black.opacity(0.75))
                .padding(5)
                .frame(width: 54, height: 64, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.94)))
                .clipped()
                .accessibilityHidden(true)
        } else if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
        } else {
            Image(nsImage: fallbackIcon).resizable().aspectRatio(contentMode: .fit).accessibilityHidden(true)
        }
    }

    private var fallbackIcon: NSImage {
        NSWorkspace.shared.icon(for: UTType(item.contentType) ?? .data)
    }

    private var subtitle: String {
        var parts: [String] = []
        if item.kind == .text { parts.append("Text") }
        else if item.kind == .folder { parts.append("Folder") }
        if let bytes = item.byteSize { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        if item.status == .recovered { parts.append("Recovered") }
        return parts.joined(separator: " · ")
    }

    private func loadThumbnail() async {
        guard item.kind != .text, item.status != .missing, let url else { return }
        if let cached = shelf.thumbnails.cached(item.id) { thumbnail = cached; return }
        thumbnail = await shelf.thumbnails.thumbnail(for: item.id, url: url, size: CGSize(width: 64, height: 64))
    }

    private func miniButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(Nook.Palette.primaryText)
        }
        .buttonStyle(GlassDropletButtonStyle(diameter: 18, emphasis: .subtle))
        .help(label)
        .accessibilityLabel(label)
    }

    private func badge(_ symbol: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .help(help)
            .accessibilityLabel(help)
            .allowsHitTesting(false)
    }

    private var dragSource: some View {
        ShelfDragSource(
            accessibilityName: item.displayName,
            payloads: { payloadsForDrag() },
            onClick: { flags in
                if flags.contains(.command) {
                    if shelf.selection.contains(item.id) { shelf.selection.remove(item.id) } else { shelf.selection.insert(item.id) }
                } else if flags.contains(.shift), let anchor = shelf.items.firstIndex(where: { shelf.selection.contains($0.id) }),
                          let here = shelf.items.firstIndex(where: { $0.id == item.id }) {
                    shelf.selection = Set(shelf.items[min(anchor, here)...max(anchor, here)].map(\.id))
                } else {
                    shelf.selection = [item.id]
                }
            },
            onDoubleClick: { quickLook() },
            makeMenu: { contextMenu() },
            onDragBegan: { ids in shelf.dragBegan(ids) },
            onDragEnded: { ids, op, inside in shelf.dragEnded(ids, operation: op, endedInsideNook: inside) }
        )
    }

    /// Dragging a selected tile drags the whole selection.
    private func payloadsForDrag() -> [DragPayload] {
        let targets = shelf.selection.contains(item.id) ? shelf.items.filter { shelf.selection.contains($0.id) } : [item]
        return targets.compactMap { target in
            guard target.status != .missing, let url = shelf.contentURL(target) else { return nil }
            var text: String?
            if target.kind == .text { text = try? String(contentsOf: url, encoding: .utf8) }
            let icon = (target.id == item.id ? thumbnail : shelf.thumbnails.cached(target.id))
                ?? NSWorkspace.shared.icon(for: UTType(target.contentType) ?? .data)
            return DragPayload(id: target.id, kind: target.kind, fileURL: url, text: text, icon: icon)
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye") { quickLook() })
        if item.kind == .text {
            menu.addItem(ClosureMenuItem("Copy Text", symbol: "doc.on.doc") { shelf.copyToClipboard(item) })
            menu.addItem(ClosureMenuItem("Ask Assistant About This", symbol: "sparkles") { shelf.sendTextToAssistant(item) })
            menu.addItem(ClosureMenuItem("Export as .txt…", symbol: "square.and.arrow.down") { shelf.presentSaveAs(item) })
        } else {
            menu.addItem(ClosureMenuItem("Copy", symbol: "doc.on.doc") { shelf.copyToClipboard(item) })
            menu.addItem(ClosureMenuItem("Save a Copy As…", symbol: "square.and.arrow.down") { shelf.presentSaveAs(item) })
        }
        let moveIDs = shelf.selection.contains(item.id) ? Array(shelf.selection) : [item.id]
        menu.addItem(ClosureMenuItem(moveIDs.count > 1 ? "Move \(moveIDs.count) Items To…" : "Move To…", symbol: "folder") { shelf.presentMoveTo(moveIDs) })
        menu.addItem(ClosureMenuItem("Show Nook's Copy in Finder", symbol: "magnifyingglass") { shelf.reveal(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(moveIDs.count > 1 ? "Remove \(moveIDs.count) Items" : "Remove from Shelf", symbol: "trash") { shelf.remove(moveIDs) })
        return menu
    }
}
