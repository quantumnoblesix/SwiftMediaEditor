# Customizing the Editor

Restyle the built-in chrome, or replace its tool row with your own.

## Overview

The chrome has three groups: Cancel and an undo/redo pill at the top leading
edge, Done at the top trailing edge, and a single centered row of tools at the
bottom.

Customization comes in two tiers. ``EditorAppearance`` restyles what the editor
draws — tints, glyphs, and a per-button hook. ``MediaEditorToolbarProviding``
replaces the tool row outright, while the editor keeps providing the behavior.

### Restyle the chrome

```swift
var appearance = EditorAppearance()
appearance.accent = .systemTeal          // Done, Apply, and "on" toggles
appearance.tint = .white                 // everything else
appearance.symbols[.crop] = "crop"       // swap any action's SF Symbol
appearance.destructive = .systemPink     // the sticker delete bin
appearance.trimColor = .systemGreen      // the video trimmer; nil follows accent
appearance.prefersLiquidGlass = false    // one look on every OS version
appearance.styleToolButton = { button, action in
    button.layer.cornerRadius = 8        // runs after the built-in styling
}
```

Pass the appearance when you create the editor — ``MediaEditorViewController``
and `MediaEditorView` both take an `appearance` argument.

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
