# Contributing to SwiftMediaEditor

**Read this before making any change** — to code, tests, docs, or the example
app. It holds the rules and patterns the package is built on. Most of them are
here because breaking them once caused a real bug.

## Before you start

- For anything larger than a small fix, open an issue first so the approach can
  be agreed before you write code.
- Keep pull requests focused: one change, with its tests and docs.
- You need Xcode 26 / Swift 6.3 (see [Requirements](README.md#requirements)).

## How the package is laid out

| Target | What belongs there |
|---|---|
| `MediaEditorCore` | The non-destructive model (`EditRecipe`, `EditHistory`, `EditorConfiguration`) and the renderers (`PhotoRenderer`, `VideoComposer`). No UIKit or SwiftUI: it builds on iOS, Mac Catalyst and native macOS. |
| `MediaEditorUIKit` | The editor UI: `MediaEditorViewController`, the tool surfaces, `EditorAppearance`, localization, and the rasterizers that need UIKit or PencilKit. |
| `MediaEditorSwiftUI` | A thin `UIViewControllerRepresentable` over the UIKit editor. No editing logic. |
| `MediaEditor` | Re-exports the three modules. Nothing else. |

Dependencies only point down: SwiftUI → UIKit → Core. Anything that doesn't need
a UI framework goes in Core, where it's also tested natively on macOS.

Every file in the two UI targets is wrapped in `#if canImport(UIKit)` (with the
standard comment above it), so native macOS builds get empty modules instead of
errors.

## Rules

### The editing model

- **Every edit is a value in `EditRecipe`.** The UI never mutates pixels;
  output is always *original media + recipe*.
- **Edits go through the editor's `apply(_:)`**, so they land in undo history.
  Assign `recipe` directly only when restoring history.
- **Old recipes must keep decoding.** A new field decodes with
  `decodeIfPresent` and a default, and gets a test that decodes a payload saved
  before the field existed.
- **Keep the preview cheap.** If a new field changes how the preview renders,
  include it in `EditRecipe.rendersDifferently(from:)`. If it doesn't — overlays
  are live views — leave it out.
- **Geometry is normalized and y-down.** Positions and sizes in the model are
  fractions (0…1) of the output frame, so a recipe renders the same at any
  resolution. Core Image and Core Graphics are y-up: convert at the boundary and
  test the conversion with an off-centre fixture, so a flipped result can't pass.

### Photo and video parity

- **Preview and export must agree.** Photo previews render the recipe at display
  resolution. Video previews apply geometry with layer transforms and show
  drawing and stickers as views over the player; `VideoComposer` applies the same
  geometry on export.
- **Never give the preview's `AVPlayerItem` a `videoComposition`.** Any video
  composition renders black in the iOS Simulator.
- **Don't use `AVVideoCompositionCoreAnimationTool`.** Its offline renderer
  crashes the iOS Simulator. Drawing and stickers are burned in by
  `ArtworkVideoCompositor`.
- Video render dimensions must be even; `VideoComposer` rounds them.

### Performance

The editor has to stay smooth on older, low-power devices.

- Preview at display resolution; render at full resolution only on save.
- Do no per-frame work while nothing moves — the video display link pauses when
  playback stops.
- Don't re-render the preview for changes that don't affect it.
- Keep large payloads off hot paths: `ImageRef` compares by `id` so undo/redo
  never compares image bytes.
- Keep frame-sized buffers 8-bit unless the content needs more.

### Concurrency

- Swift 6 language mode with strict concurrency. UI types are `@MainActor`.
- Every `@unchecked Sendable` carries a comment saying why it's safe.
- Don't let system callbacks retain the editor: `CADisplayLink` goes through
  `DisplayLinkProxy`. When you add a callback like that, add a test that the
  editor still deallocates.

### Platforms

- Deployment targets are iOS 17, Mac Catalyst 17 and macOS 14 (Core only).
- Newer APIs, such as Liquid Glass on iOS 26, go behind `#available` with a
  fallback that looks right on older systems.

### Public API

- Every public symbol has a doc comment, and new public types are listed in their
  module's DocC catalog (`Sources/<Module>/<Module>.docc`).
- Prefer additive changes. When you add a closure parameter, make sure existing
  trailing-closure calls still bind to the parameter they bound to before.
- Colours, glyphs and styling come from `EditorAppearance`; don't hard-code them
  in the chrome.
- A new tool gets an `EditorTools` option, goes into `allPhoto` and/or
  `allVideo`, and is honoured through `EditorConfiguration.tools(for:)`.

### Text and accessibility

- Every user-facing string goes through `L10n`. Add its key to `L10n.allKeys` and
  to all five `Localizable.strings` files (en, it, fr, es, pt-BR) —
  `LocalizationTests` fail otherwise.
- Icon-only controls need an accessibility label, and icon buttons also need a
  `largeContentTitle` so the large content viewer can show them.
- Anything done with a gesture needs a VoiceOver way in: a custom action (the
  sticker edits), or the adjustable trait for anything slider-like (the straighten
  dial, the crop frame, the trim handles).
- A control that gets out of the way must stay reachable while VoiceOver or Switch
  Control runs (`EditorAccessibility.isAssistiveTechnologyRunning`).
- Show a selection with more than colour: the selected trait for VoiceOver, and a
  change of shape or weight on screen.
- Photos, video frames, thumbnails and stickers set
  `accessibilityIgnoresInvertColors`.
- Animations that scale, spring or fly check
  `EditorAccessibility.prefersReducedMotion` and fall back to a fade.
- Chrome text follows Dynamic Type through `EditorAccessibility.scaledFont`, with a
  cap only where the layout has fixed room. Touch targets are at least 44 points.

## Tests

Tests use Swift Testing (`@Test`, `#expect`, `#require`). Every bug fix comes with
a test that fails without the fix. Prefer checking real output — pixels in a
rendered image, a frame of an exported video — over checking that a method ran.

Run both suites before opening a pull request:

```sh
swift test                                    # Core, natively on macOS

xcodebuild test -scheme MediaEditor-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

- When several simulators share a name, pass `-destination 'id=<UDID>'`.
- If you pipe `xcodebuild` through `grep`, check `xcodebuild`'s own exit status —
  the pipeline's can report success for a failed run.
- UIKit tests run without a host app, and `UIControl.sendActions(for:)` doesn't
  reach the target there: call the control's action directly.

The example app must keep building:

```sh
xcodebuild build -project Examples/MediaEditorExample.xcodeproj \
  -scheme MediaEditorExample -destination 'generic/platform=iOS Simulator'
```

## Code style

- Match the surrounding code: naming, comment density, idioms.
- Comments explain *why* — a constraint, a platform quirk, a trade-off — not
  what the next line does.
- New source files start with the standard header:

  ```swift
  //
  //  FileName.swift
  //  ModuleName
  //
  //  Created by Your Name.
  //  Copyright © 2026 Your Name.
  //  SPDX-License-Identifier: Apache-2.0
  //
  ```

## Docs and changelog

- Update the README and the affected DocC article when behaviour or API changes.
- Add an entry to [CHANGELOG.md](CHANGELOG.md) under **Unreleased**.

## AI coding assistants

Configuration and notes for AI coding tools are never committed: `.claude/`,
`CLAUDE.md`, `CLAUDE.local.md` and `.mcp.json` are ignored by git. This file is
the single set of rules for every contributor. Point your assistant at it
locally — for Claude Code, a `CLAUDE.md` in your checkout containing
`@CONTRIBUTING.md`.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), the license of this project.
