# ``MediaEditorUIKit``

A photo and video editor you present from UIKit.

## Overview

``MediaEditorViewController`` is the turnkey editor: crop, rotate, flip,
filters, PencilKit drawing, text and stickers, video trimming, and audio
removal, with undo/redo and a live preview. Hand it a ``MediaItem``, and it calls
back with an ``EditorResult`` — the rendered output plus the recipe that
produced it, so the edit can be re-opened later.

The editor runs on iOS 17 and Mac Catalyst 17. Its chrome adopts Liquid Glass on
iOS 26 and falls back to a blurred material on earlier versions. SwiftUI apps
use the same editor through `MediaEditorView`, and the model it edits lives in
`MediaEditorCore`.

## Topics

### Essentials

- <doc:GettingStarted>
- ``MediaEditorViewController``
- ``MediaItem``
- ``EditorResult``
- ``EditorOutput``

### Customizing the editor

- <doc:CustomizingTheEditor>
- ``EditorAppearance``
- ``MediaEditorToolbarProviding``
- ``EditorAction``
- ``EditorBarButtonRole``

### Rendering outside the editor

- ``OverlayCompositor``
- ``DrawingCompositor``
