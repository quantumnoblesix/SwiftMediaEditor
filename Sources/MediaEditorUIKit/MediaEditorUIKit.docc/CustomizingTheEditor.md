# Customizing the Editor

Restyle the built-in chrome, lay it out like a chat app with your own bottom
bar, or replace its tool row with your own.

## Overview

By default the chrome has three groups: Cancel and an undo/redo pill at the top
leading edge, Done at the top trailing edge, and a single centered row of tools
at the bottom. Undo and redo appear once there is something to undo. The editor
is always dark, whatever the system appearance, and so is everything it presents
and anything the host puts in it.

``EditorAppearance`` restyles what the editor draws — tints, glyphs, a
per-button hook, and where the tool row sits. A bottom accessory adds a bar of
your own, such as a caption field and a send button.
``MediaEditorToolbarProviding`` replaces the tool row outright, while the editor
keeps providing the behavior.

### Restyle the chrome

```swift
var appearance = EditorAppearance()
appearance.accent = .systemTeal          // Done, Apply, and "on" toggles
appearance.tint = .white                 // everything else
appearance.symbols[.crop] = "crop"       // swap any action's SF Symbol
appearance.destructive = .systemPink     // the sticker delete bin
appearance.trimColor = .systemGreen      // the video trimmer; nil follows accent
appearance.prefersLiquidGlass = false    // one look on every OS version
appearance.toolbarPlacement = .top       // tools in the top bar, or .bottom
appearance.toolbarStyle = .circularButtons   // a circle per tool, or .floatingBar
appearance.styleToolButton = { button, action in
    button.layer.cornerRadius = 8        // runs after the built-in styling
}
```

Pass the appearance when you create the editor — ``MediaEditorViewController``
and `MediaEditorView` both take an `appearance` argument.

### Lay it out like a chat app

``EditorAppearance/messaging`` puts an ✕ and a circular button per tool across
the top, leaving the bottom for a bar of your own. Pass that bar as the
`bottomAccessory`. It spans the full width and runs under the home indicator,
so lay its content out against its `safeAreaLayoutGuide`; the editor lifts it
with the keyboard and hides it while a tool is open. With an accessory
installed the editor shows no Done button, so call
``MediaEditorViewController/finish()`` from your send action:

```swift
let editor = MediaEditorViewController(item: .photo(image),
                                       appearance: .messaging,
                                       bottomAccessory: captionBar)
captionBar.onSend = { [weak editor] in editor?.finish() }
```

`MediaEditorView` takes a `bottomAccessory` view builder instead, which
receives a `MediaEditorProxy` for driving the editor from SwiftUI.

### Replace the tool row

Adopt ``MediaEditorToolbarProviding`` to build the row yourself. The editor tells
you which actions to show, and runs them for you:

```swift
final class BrandToolbar: NSObject, MediaEditorToolbarProviding {
    private var buttons: [EditorAction: UIButton] = [:]

    func makeToolbar(for actions: [EditorAction],
                     editor: MediaEditorViewController) -> UIView? {
        let row = UIStackView()
        for action in actions {
            let button = UIButton(type: .system)
            button.setTitle(action.localizedTitle, for: .normal)
            button.addAction(UIAction { [weak editor] _ in
                editor?.perform(action)
            }, for: .touchUpInside)
            buttons[action] = button
            row.addArrangedSubview(button)
        }
        return row
    }

    func updateToolbar(_ toolbar: UIView, editor: MediaEditorViewController) {
        for (action, button) in buttons {
            button.isEnabled = editor.isEnabled(action)
            button.tintColor = editor.isActive(action) ? .systemTeal : .white
        }
    }
}
```

The editor holds its toolbar provider weakly, so keep your own reference to it.

- ``MediaEditorToolbarProviding/makeToolbar(for:editor:)`` receives the actions
  already filtered by the configuration and the kind of media. Return `nil` to
  keep the built-in row.
- ``MediaEditorToolbarProviding/updateToolbar(_:editor:)`` runs on every state
  change. Read ``MediaEditorViewController/isEnabled(_:)`` and
  ``MediaEditorViewController/isActive(_:)`` there.
- ``MediaEditorToolbarProviding/hidesToolbarInToolMode(_:)`` keeps your row on
  screen while crop or drawing is open when you return `false`.

Undo and redo aren't among the actions: they stay in the top bar, even behind a
custom row. Your row can still offer them by calling
``MediaEditorViewController/perform(_:)`` with ``EditorAction/undo`` or
``EditorAction/redo``.
