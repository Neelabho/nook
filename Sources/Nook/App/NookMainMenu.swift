import AppKit

/// Nook is an accessory app (no menu bar of its own), but macOS routes ⌘A/⌘C/⌘V/⌘X/⌘Z to text fields
/// through the main menu's Edit items. Without this menu those shortcuts did nothing in the AI box,
/// the search field, notes or Settings (reported). The menu is never shown.
///
/// Deliberately no ⌘Q here: with the panel focused it would quit Nook unexpectedly; Quit lives in
/// the menu-bar icon's menu.
enum NookMainMenu {
    struct Entry: Equatable {
        let title: String
        let action: Selector
        let key: String
        let modifiers: NSEvent.ModifierFlags
    }

    static let editEntries: [Entry] = [
        Entry(title: "Undo", action: Selector(("undo:")), key: "z", modifiers: [.command]),
        Entry(title: "Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
        Entry(title: "Cut", action: #selector(NSText.cut(_:)), key: "x", modifiers: [.command]),
        Entry(title: "Copy", action: #selector(NSText.copy(_:)), key: "c", modifiers: [.command]),
        Entry(title: "Paste", action: #selector(NSText.paste(_:)), key: "v", modifiers: [.command]),
        Entry(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), key: "v", modifiers: [.command, .option, .shift]),
        Entry(title: "Delete", action: #selector(NSText.delete(_:)), key: "", modifiers: []),
        Entry(title: "Select All", action: #selector(NSText.selectAll(_:)), key: "a", modifiers: [.command]),
    ]

    @MainActor
    static func make() -> NSMenu {
        let main = NSMenu(title: "Main")

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Nook")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (index, entry) in editEntries.enumerated() {
            if index == 2 || index == 6 { edit.addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: entry.action, keyEquivalent: entry.key)
            item.keyEquivalentModifierMask = entry.modifiers
            item.target = nil      // first responder (the focused text field)
            edit.addItem(item)
        }
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        let close = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(close)
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    @MainActor
    static func install() { NSApp.mainMenu = make() }
}
