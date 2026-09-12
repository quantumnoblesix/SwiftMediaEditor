# ``MediaEditorCore``

The non-destructive editing model and the renderers behind the editor, with no UI.

## Overview

Every edit the editor makes is a value: an ``EditRecipe`` describing crop,
rotation, flip, filter, drawing, overlays, trim, and audio removal. Output is
always the original media plus a recipe, so edits stay reversible, a saved
recipe re-opens exactly where the user left off, and photos and videos share one
model.

This module holds that model and the renderers that apply it — ``PhotoRenderer``
for images and ``VideoComposer`` for videos. It imports no UI framework, so it
builds on iOS, Mac Catalyst, and native macOS. The turnkey editor lives in
`MediaEditorUIKit` and `MediaEditorSwiftUI`; import `MediaEditor` to get all
three.

## Topics

### Essentials

- <doc:EditingWithRecipes>
- ``EditRecipe``
- ``EditHistory``

### Configuring the editor

- <doc:ConfiguringTheEditor>
- ``EditorConfiguration``
- ``EditorTools``
- ``MediaKind``
- ``VideoExportPreset``

### Rendering

- ``PhotoRenderer``
- ``VideoComposer``
- ``PhotoFilter``

### Geometry

- ``CropState``
- ``AspectPreset``
- ``RotationState``
- ``FlipState``
- ``TrimRange``
- ``CropGeometry``
- ``NormalizedPoint``
- ``NormalizedSize``
- ``NormalizedRect``
- ``NormalizedTransform``

### Drawing and overlays

- ``DrawingData``
- ``Overlay``
- ``OverlayContent``
- ``TextStyle``
- ``TextAlignment``
- ``ImageRef``
- ``RGBAColor``
