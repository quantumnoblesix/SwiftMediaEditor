# ``MediaEditorSwiftUI``

The photo and video editor as a SwiftUI view.

## Overview

``MediaEditorView`` wraps the UIKit editor, so SwiftUI and UIKit apps share one
implementation. It takes the same media, recipe, configuration, appearance, and
toolbar options as `MediaEditorViewController`.

```swift
struct EditorScreen: View {
    let image: UIImage
    @State private var isEditing = false
    @State private var edited: UIImage?

    var body: some View {
        Button("Edit") { isEditing = true }
            .fullScreenCover(isPresented: $isEditing) {
                MediaEditorView(item: .photo(image)) { result in
                    if case let .saved(.photo(output), _) = result {
                        edited = output
                    }
                    isEditing = false
                }
                .ignoresSafeArea()
            }
    }
}
```

The editor never dismisses itself: end the presentation in the completion
handler. A video result is a file in the temporary directory — move it somewhere
durable before the handler returns.

If you pass a `toolbarProvider`, the view holds it weakly. Keep your own
reference, for example in a `@State` property of the hosting view.

The `MediaEditorUIKit` documentation covers the result, re-opening edits, and
customizing the chrome; `MediaEditorCore` covers configuration and the recipe
model.

## Topics

### Essentials

- ``MediaEditorView``
