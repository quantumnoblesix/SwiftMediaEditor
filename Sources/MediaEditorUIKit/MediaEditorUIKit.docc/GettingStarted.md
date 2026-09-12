# Getting Started

Present the editor, handle the result, and re-open an edit later.

## Overview

The editor works on one photo or video per session. You create it with a
``MediaItem``, present it, and receive an ``EditorResult`` when the user taps
Done or Cancel.

### Present the editor

```swift
import MediaEditor

let editor = MediaEditorViewController(item: .photo(image)) { [weak self] result in
    self?.dismiss(animated: true)
    switch result {
    case let .saved(output, recipe):
        // Use `output`, and store `recipe` to re-open the edit later.
        break
    case .cancelled:
        break
    }
}
present(editor, animated: true)
```

For a video, pass its file URL: `.video(url)`.

The editor presents full screen and never dismisses itself — dismiss it in the
completion handler.

### Use the output

``EditorOutput/photo(_:)`` carries the rendered image, with every edit applied.

``EditorOutput/video(_:)`` carries a freshly exported file in the temporary
directory. The file is yours once the handler runs: move or copy it somewhere
durable before returning, because the system can purge the temporary directory
at any time.

Exporting a video takes a moment. The editor shows its progress with a Cancel
button and calls your handler only once the file is ready. If the user cancels
the export, or it fails, they stay in the editor.

### Re-open an edit

``EditorResult/saved(output:recipe:)`` also hands back the recipe that produced
the output. Recipes are `Codable`, so you can store one, and passing it back
with the original media resumes the session where it ended, with every edit
still adjustable:

```swift
let data = try JSONEncoder().encode(recipe)

// Later:
let saved = try JSONDecoder().decode(EditRecipe.self, from: data)
let editor = MediaEditorViewController(item: .photo(originalImage), recipe: saved) { result in
    // …
}
```

Always pass the *original* media, not a previous output: a recipe describes
edits relative to the original.

### Choose what the editor offers

Pass an `EditorConfiguration` to pick the tools photos and videos each get, the
crop ratios, and the video export settings. The *Configuring the Editor* article
in the `MediaEditorCore` documentation covers the options.

```swift
var configuration = EditorConfiguration()
configuration.videoTools = [.trim, .audio]

let editor = MediaEditorViewController(item: .video(url), configuration: configuration) { result in
    // …
}
```

### Drive the editor from code

Everything the built-in chrome does is available to your code:
``MediaEditorViewController/perform(_:)`` runs any ``EditorAction``,
``MediaEditorViewController/apply(_:)`` records a recipe change in undo history,
and ``MediaEditorViewController/finish()`` and
``MediaEditorViewController/cancel()`` end the session as Done and Cancel do.

### Localization

The editor's strings ship in English, Italian, French, Spanish, and Brazilian
Portuguese. A translation only appears when your app also supports that
language; otherwise the editor falls back to English. To reword a string, define
the same key in your app's `Localizable.strings`.
