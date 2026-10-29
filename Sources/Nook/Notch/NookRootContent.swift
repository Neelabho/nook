import NookCore
import SwiftUI

struct NookRootContent: View {
    @Bindable var model: NotchModel
    let env: AppEnvironment

    var body: some View {
        let peeking = !model.isOpen && model.peekVisible
        let size = model.isOpen ? model.openSize : (peeking ? model.peekSize : model.closedSize)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchSurface(isOpen: model.isOpen, transparentWhenClosed: !model.hasNotch && !peeking)
                if peeking {
                    NowPlayingPeekView(music: env.music, settings: env.settings, wing: model.peekWing, height: model.peekSize.height)
                        .transition(.opacity)
                }
                if model.isOpen {
                    ExpandedNookView(model: model, env: env)
                        .transition(env.settings.effectiveReduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(NotchShape(
                topRadius: model.isOpen ? Nook.Metrics.openTopRadius : Nook.Metrics.closedTopRadius,
                bottomRadius: model.isOpen ? Nook.Metrics.openBottomRadius : Nook.Metrics.closedBottomRadius
            ))
            .overlay(
                NotchShape(topRadius: Nook.Metrics.openTopRadius, bottomRadius: Nook.Metrics.openBottomRadius)
                    .stroke(Color.white.opacity(model.isOpen ? 0.08 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.isOpen) { env.featureVisibilityChanged() }
        .onChange(of: model.selectedTab) { env.featureVisibilityChanged() }
    }
}

struct ExpandedNookView: View {
    @Bindable var model: NotchModel
    let env: AppEnvironment

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch model.selectedTab {
                case .shelf:
                    ShelfView(shelf: env.shelf, notch: model) { urls, index in
                        env.coordinator.quickLook.show(urls, selected: index, from: env.coordinator.panelWindow)
                    }
                case .music:
                    MusicView(music: env.music, settings: env.settings, search: env.search, catalog: env.catalog,
                              requestKeyboardFocus: { env.coordinator.panelWindow?.makeKey() },
                              openMusicSettings: { env.openSettings(tab: .music) })
                case .assistant:
                    AssistantView(assistant: env.assistant, notch: model, onLarge: { env.coordinator.setLarge($0) })
                }
            }
            .padding(.horizontal, Nook.Metrics.contentPadding + 6)
            .padding(.top, 8)
            .padding(.bottom, Nook.Metrics.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(Nook.Palette.primaryText)
    }

    /// The header sits in the menu-bar band: tabs on the left "ear", controls on the right,
    /// leaving the physical notch area empty.
    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                tabButton(.assistant, "AI", "sparkles", key: "1")
                tabButton(.music, "Music", "music.note", key: "2")
                tabButton(.shelf, "Shelf", "tray.full", key: "3")
            }
            Spacer(minLength: model.notchWidth + 20)
            HStack(spacing: 6) {
                GlassIconButton(systemImage: model.pinned ? "pin.fill" : "pin", label: model.pinned ? "Unpin (allow auto-collapse)" : "Pin open", isActive: model.pinned, size: 24) {
                    env.coordinator.togglePinned()
                }
                GlassIconButton(systemImage: model.isLarge ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                label: model.isLarge ? "Compact size" : "Larger panel", size: 24) {
                    env.coordinator.setLarge(!model.isLarge)
                }
                GlassIconButton(systemImage: "gearshape", label: "Settings…", size: 24) { env.openSettings() }
                GlassIconButton(systemImage: "xmark", label: "Close (Esc)", size: 24) { env.coordinator.close() }
            }
        }
        .padding(.leading, Nook.Metrics.openTopRadius + 12)
        .padding(.trailing, Nook.Metrics.openTopRadius + 12)
        .frame(height: max(model.headerHeight, 30))
        .padding(.top, 2)
    }

    private func tabButton(_ tab: NookTab, _ title: String, _ symbol: String, key: KeyEquivalent) -> some View {
        let selected = model.selectedTab == tab
        return Button {
            model.selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .foregroundStyle(selected ? Color.white : Nook.Palette.secondaryText)
            .background {
                if selected {
                    Capsule().fill(Color.white.opacity(0.16)).nookGlass(in: Capsule())
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .help("\(title) (⌘\(String(key.character)))")
        .accessibilityLabel(tab == .assistant ? "Assistant" : title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
