# Configuring the Editor

Choose the tools each kind of media gets, the crop presets, and how videos are
exported.

## Overview

``EditorConfiguration`` is a value you hand to the editor when you create it. It
lives in this module so UIKit and SwiftUI hosts share it. The defaults offer
every tool, the common crop ratios, and HEVC video export at the source's own
resolution.

### Choose tools for photos and videos

Photos and videos take separate tool sets, so each can be trimmed down on its
own:

```swift
var configuration = EditorConfiguration()
configuration.photoTools = [.crop, .filters, .drawing, .overlays]
configuration.videoTools = [.trim, .audio, .overlays]
```

A tool that can't work on a kind of media is ignored — ``EditorTools/filters`` in
`videoTools`, or ``EditorTools/trim`` in `photoTools`.
``EditorConfiguration/tools(for:)`` returns the set the editor actually offers:

```swift
configuration.tools(for: .video)   // [.trim, .audio, .overlays]
```

To give photos and videos the same list, assign it to `tools`:

```swift
configuration.tools = [.crop, .overlays]
```

When crop is enabled, rotate and flip live inside the crop tool, as in Photos.
Without crop, they move to the main tool row.

### Offer crop aspect ratios

``EditorConfiguration/aspectPresets`` lists the ratios the crop tool offers, in
order. A new crop starts locked to the source's own ratio when
``AspectPreset/original`` is in the list, and free otherwise.

```swift
configuration.aspectPresets = [.original, .square, .ratio(width: 9, height: 16)]
```

### Control video export

```swift
configuration.videoExportPreset = .h264HighQuality   // broadest compatibility
configuration.maximumExportDimension = 1920          // cap the longest side
```

Re-encoding a 4K clip at full resolution is the most expensive thing the editor
does. Capping ``EditorConfiguration/maximumExportDimension`` to 1080p or 720p is
the most effective way to keep exports quick on older devices.

### Limit undo history

``EditorConfiguration/historyLimit`` bounds how many edits undo can step back
through. The default is 50.
