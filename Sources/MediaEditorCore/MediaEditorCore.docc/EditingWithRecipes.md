# Editing with Recipes

Describe edits as values, and render them without any UI.

## Overview

An ``EditRecipe`` is a small `Codable` value describing everything done to one
photo or video. The editor produces recipes, but you can also build them in
code — to batch-process media, or to re-render a stored edit.

### Describe an edit

```swift
var recipe = EditRecipe()
recipe.crop = CropState(rect: NormalizedRect(x: 0, y: 0.25, width: 1, height: 0.5))
recipe.rotation = RotationState(degrees: 90)
recipe.flip = FlipState(horizontal: true)
recipe.filter = .mono                            // photos only
recipe.trim = TrimRange(start: 2, duration: 5)   // videos only
recipe.removeAudio = true                        // videos only
```

Geometry is normalized: rectangles and positions are fractions (0…1) of the
frame, measured from the top-left corner, so a recipe renders the same at any
resolution. Edits apply in a fixed order — flip, rotation, crop, then the
filter, drawing, and overlays — and the crop rectangle is measured in the frame
after flip and rotation.

### Render a photo

``PhotoRenderer`` applies a recipe's geometry and color filter:

```swift
let renderer = PhotoRenderer()
if let output = renderer.renderGeometry(cgImage: source, recipe: recipe) {
    // `output` is cropped, rotated, flipped, and filtered.
}
```

Pass an image whose orientation is already up — bake in any EXIF orientation
first. Keep one renderer around rather than creating one per image: it owns a
Core Image context, which is expensive to create. To stay in Core Image, use
``PhotoRenderer/applyGeometry(to:recipe:)`` and
``PhotoRenderer/applyFilter(_:to:)``.

Drawing and overlays need UIKit to rasterize PencilKit strokes and text, so the
renderer leaves them out. `MediaEditorUIKit` adds them with `DrawingCompositor`
and `OverlayCompositor`.

### Export a video

``VideoComposer`` exports a video with the recipe's crop, rotation, flip, trim,
and audio removal applied. Call it from the main actor:

```swift
let composer = VideoComposer()
try await composer.export(asset: AVURLAsset(url: source), recipe: recipe, to: destination,
                          preset: .h264HighQuality, maximumDimension: 1920) { progress in
    print("\(Int(progress * 100))%")
}
```

The file is written as MPEG-4, and nothing may exist at `destination` yet.
Cancelling the task that runs the export cancels the export and throws
`CancellationError`.

The composer can't rasterize drawing or overlays itself. To burn them in, render
them into one transparent image and return it from `overlayImage`. It's called
with the size of the output frame — after `maximumDimension` — so you can draw at
exactly that resolution:

```swift
try await composer.export(asset: asset, recipe: recipe, to: destination) { progress in
    // …
} overlayImage: { renderSize in
    artwork(for: recipe, size: renderSize)   // a CGImage you draw
}
```

Frames that carry artwork are processed in 8-bit, so an HDR source exported with
artwork comes out SDR. Exports without artwork are unaffected.

### Track undo history

``EditHistory`` is a bounded undo/redo stack of recipe snapshots:

```swift
var history = EditHistory(initial: EditRecipe(), limit: 50)

var next = history.current
next.rotation.rotateClockwise90()
history.push(next)

let previous = history.undo()   // the recipe before the rotation
```

### Store and restore recipes

Recipes are `Codable`, and recipes saved by earlier versions of the package keep
decoding — fields added since fall back to their defaults.

```swift
let data = try JSONEncoder().encode(recipe)
let restored = try JSONDecoder().decode(EditRecipe.self, from: data)
```

An image overlay refers to its image through an ``ImageRef``, which can carry
the encoded image in ``ImageRef/data`` or only an ``ImageRef/id`` that your app
resolves from its own storage.
