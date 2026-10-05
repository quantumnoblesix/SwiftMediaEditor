//
//  MediaEditorViewController.swift
//  MediaEditorUIKit
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

// The turnkey editor UI is UIKit-based, so it builds for iOS and Mac
// Catalyst. On platforms without UIKit this file compiles to nothing and
// hosts use `MediaEditorCore` directly.
#if canImport(UIKit)

import UIKit
import AVFoundation
import PhotosUI
import PencilKit
import MediaEditorCore

/// The turnkey UIKit editor. Present this, hand it a `MediaItem` (and optionally
/// a previously-saved `EditRecipe` to resume), and receive an `EditorResult`
/// through `onFinish`.
///
/// Or hand it several items — ``init(items:selectedItemID:configuration:appearance:toolbarProvider:bottomAccessory:onFinish:)``
/// — and it edits them as one session: a thumbnail strip moves between them,
/// each keeps its own edits and undo history, and the session ends with one
/// result per item.
///
/// Photos get the geometry tools (crop / rotate / flip) with a live preview
/// driven by the non-destructive `EditRecipe` + `PhotoRenderer`, plus filters,
/// drawing, overlays, undo/redo, and save. Videos get the crop tool, drawing and
/// overlays over a play/pause preview, trim, and audio removal, all exported
/// through `VideoComposer`.
@MainActor
public final class MediaEditorViewController: UIViewController {

    /// The media being edited — in a multi-item session, the selected item's.
    /// A file-backed photo appears here once decoded; passthrough content has
    /// no editable media, so look at ``selectedItem`` for that.
    public private(set) var item: MediaItem
    /// Editor configuration (enabled tools, aspect presets, export settings).
    public let configuration: EditorConfiguration
    /// Called once when a single-item editor ends, on the main actor.
    public var onFinish: ((EditorResult) -> Void)?
    /// Called once when a multi-item session ends, on the main actor.
    public var onSessionFinish: ((MediaEditorSessionResult) -> Void)?

    // MARK: Session

    /// The session's items in strip order, with their current recipes. The
    /// selected item's recipe is its committed working recipe — never the
    /// half-applied state of an open tool.
    public private(set) var items: [MediaEditorItem]
    /// The item on the canvas.
    public private(set) var selectedItemID: UUID
    /// The item on the canvas, with its current recipe.
    public var selectedItem: MediaEditorItem { items[selectedIndex] }

    /// Called after the selection changes — a strip tap, a page turn, a removal or
    /// `select(_:)`.
    public var onSelectionChange: ((UUID) -> Void)?
    /// Called after items are removed, reordered or inserted.
    public var onItemsChange: (([MediaEditorItem]) -> Void)?
    /// Called after every committed change to the selected item's recipe —
    /// an applied tool, a sticker moved, undo or redo — but not for the recipe
    /// an item starts with.
    public var onRecipeChange: ((UUID, EditRecipe) -> Void)?
    /// When set, the strip ends with a "+" cell that calls this, and stays on
    /// screen even for one item. Present your own picker and call
    /// `insert(_:at:)` with what the user picks.
    public var onAddItems: (() -> Void)? {
        didSet { if isViewLoaded { updateStrip() } }
    }

    /// A single-item editor: no strip, and it reports through `onFinish`.
    private let isSingleItemEditor: Bool
    private var selectedIndex: Int { items.firstIndex { $0.id == selectedItemID } ?? 0 }
    /// Undo histories of the items that aren't selected, kept for the session.
    private var histories: [UUID: EditHistory<EditRecipe>] = [:]
    /// Set while an item is being loaded, so restoring its recipe isn't
    /// reported as a change.
    private var isLoadingSelection = false
    /// The selected item can't be edited — its own view is on the canvas.
    private var isPassthrough = false
    private let passthroughHost = UIView()
    private var passthroughView: UIView?
    /// Decodes a file-backed photo off the main actor.
    private var photoLoadTask: Task<Void, Never>?
    /// Loads the selected video's duration, tracks and size.
    private var videoLoadTask: Task<Void, Never>?
    private lazy var thumbnailStrip = ThumbnailStripView(appearance: appearance)
    /// Renders strip thumbnails one at a time.
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailQueue: [UUID] = []
    /// The recipe each strip thumbnail was rendered for.
    private var thumbnailRecipes: [UUID: EditRecipe] = [:]
    private var thumbnailDebounce: Task<Void, Never>?
    /// The page turn in progress, if any.
    private var paging: Paging?
    /// Screen-sized renders of the selected item's neighbours, so a page turn
    /// slides in a sharp picture rather than a stretched strip thumbnail.
    private var pagePreviews: [UUID: (recipe: EditRecipe, image: UIImage)] = [:]
    private var pagePreviewTask: Task<Void, Never>?
    /// The rendering path shared with `EditRenderer`'s hosts.
    private lazy var editRenderer = EditRenderer(configuration: configuration)

    /// How the built-in chrome is styled. Set through `init`; changing it after
    /// the view loads has no effect on bars already built.
    public let appearance: EditorAppearance

    /// Supplies a replacement tool row. When it returns a view, the built-in
    /// bar is never created and the host drives the editor through
    /// `perform(_:)`. See ``MediaEditorToolbarProviding``.
    public private(set) weak var toolbarProvider: (any MediaEditorToolbarProviding)?

    /// A host-supplied bar pinned under everything else — a caption field and a
    /// send button, say. It spans the full width, sizes itself, and rides up
    /// with the keyboard. See ``init(item:recipe:configuration:appearance:toolbarProvider:bottomAccessory:onFinish:)``.
    public let bottomAccessory: UIView?

    /// Whether the editor draws its own Done button. A bottom accessory takes
    /// that job over — its send button calls `finish()` — so the editor drops
    /// its own rather than offering two ways to confirm.
    public var showsDoneButton: Bool { bottomAccessory == nil }

    /// Undo/redo history over the working recipe.
    private var history: EditHistory<EditRecipe>

    /// The current working recipe — the selected item's.
    public private(set) var recipe: EditRecipe {
        didSet {
            // Overlays are live views over the render, so an overlay-only edit
            // (dragging a sticker) needs no new bitmap at all.
            if recipe.rendersDifferently(from: oldValue) { renderPreview() }
            if isViewLoaded { updateDrawingLayer() }
            if case .video = item, isViewLoaded {
                syncVideoState()
            }
            if recipe != oldValue, !isLoadingSelection, items.indices.contains(selectedIndex) {
                items[selectedIndex].recipe = recipe
                onRecipeChange?(selectedItemID, recipe)
                scheduleThumbnailRefresh(for: selectedItemID)
            }
        }
    }

    // MARK: - Rendering

    private let renderer = PhotoRenderer()
    private let drawingCompositor = DrawingCompositor()
    /// The orientation-normalized source image (photos only).
    private var sourceImage: UIImage?
    private var sourceCGImage: CGImage?
    /// `sourceCGImage` scaled down to roughly what the preview can actually
    /// show, and the cap it was built for.
    ///
    /// Editing re-renders on every change. Pushing a 12 MP source through Core
    /// Image to fill a ~2 MP view costs about 50 MB and several milliseconds
    /// each time, for pixels nobody can see. Full resolution is used only by
    /// `finish()`, where it matters.
    private var previewSourceCGImage: CGImage?
    private var previewSourceCap: CGFloat = 0
    /// Decoded images for image overlays, keyed by `ImageRef.id`.
    private var overlayImages: [UUID: UIImage] = [:]

    // MARK: - Mode

    private enum Mode { case normal, crop, draw, filter }
    private var mode: Mode = .normal

    // MARK: - Views

    private let imageView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.translatesAutoresizingMaskIntoConstraints = false
        // The preview fills whatever the chrome leaves. Left at their defaults,
        // an image view's priorities let a large image — a full-size decode is
        // thousands of points tall — out-bid the bottom accessory's own
        // intrinsic height, and Auto Layout squashes the accessory instead.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            v.setContentHuggingPriority(.init(1), for: axis)
            v.setContentCompressionResistancePriority(.init(1), for: axis)
        }
        return v
    }()

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    /// Clips the player layer to the recipe's crop; sized to the rendered output.
    private let videoContainer = UIView()
    /// The recipe's strokes on screen, for photos and videos alike. They live in
    /// the sticker layer rather than the preview bitmap, so they stack among the
    /// stickers exactly as the export stacks them. Internal so tests can check it.
    var drawingLayerView: UIImageView { overlayContainer.drawingView }
    /// The drawing `drawingLayerView` shows, so recipe changes that leave the
    /// strokes alone don't re-rasterize them.
    private var renderedDrawing: DrawingData?
    /// The pixel size `renderedDrawing` was rasterized at.
    private var renderedDrawingPixels: CGSize = .zero
    /// The drawing on screen — the recipe's, or in crop mode its whole-frame
    /// carry.
    private var shownDrawing: DrawingData?
    /// The video's oriented display size, resolved once the asset loads.
    /// Internal so tests can stand in for a real asset.
    var videoOrientedSize: CGSize = .zero
    /// Whether the filmstrip is on offer for this session.
    private var showsTrimScrubber: Bool {
        configuration.tools(for: item.kind).contains(.trim)
    }

    // Video editing state.
    private var videoAsset: AVURLAsset?
    private lazy var trimScrubber = TrimScrubberView(appearance: appearance)
    private var displayLink: CADisplayLink?
    /// Keeps the display link from retaining `self` — see `DisplayLinkProxy`.
    private let displayLinkProxy = DisplayLinkProxy()
    private var videoTrimStart: Double = 0
    private var videoTrimEnd: Double = .greatestFiniteMagnitude
    private var exportTask: Task<Void, Never>?

    /// The floating transport over the preview. Visible only while paused.
    private lazy var playPauseButton = PlayPauseButton(appearance: appearance)
    /// Whether the source carries audio at all — the mute toggle only shows then.
    private var hasAudioTrack = false
    /// The elapsed / total readout above the filmstrip.
    private lazy var timeLabel = PlaybackTimeLabel(appearance: appearance)
    /// The position the preview, playhead and readout show, in source seconds.
    /// Tracked here because a seek doesn't move the player's reported time until
    /// it lands.
    private var playbackPosition: Double = 0
    /// The source's duration once loaded. Internal so tests can stand in for a
    /// real asset.
    var videoDuration: Double?
    /// Keep the transport centred on the video frame; see `alignTransport(to:)`.
    private var playPauseCenterX: NSLayoutConstraint?
    private var playPauseCenterY: NSLayoutConstraint?

    private let topBar = UIStackView()
    private let historyBar = UIStackView()
    private lazy var historyBarBackground = appearance.makeBarBackground(cornerRadius: 13)
    /// What went into the layout for undo/redo: the glass pill, or — under
    /// ``EditorToolbarStyle/circularButtons`` — the bare row of circles.
    private var historyContainer: UIView = UIView()
    /// The built-in tool buttons, laid out in a row.
    private let toolRow = UIStackView()
    private lazy var toolRowBackground = appearance.makeBarBackground(cornerRadius: appearance.toolbarCornerRadius)
    /// A host-supplied tool row, when `toolbarProvider` returned one.
    private var customToolbar: UIView?
    /// Whatever went into the layout for the tool row — the custom row, the
    /// glass bar, or the bare row of circular buttons.
    private var toolRowContainer: UIView?
    /// The Done button, when `toolbarPlacement` is `.top` and pushes it down to
    /// the bottom trailing corner.
    private var floatingDoneButton: UIButton?
    /// Everything reserved along the bottom: the accessory's resting height
    /// and, above it, the thumbnail strip. The accessory itself follows the
    /// keyboard; the preview and video controls lay out against this instead,
    /// so they stay put while the user types.
    private let bottomChromeGuide = UILayoutGuide()
    /// The accessory's share of `bottomChromeGuide`.
    private let accessoryGuide = UILayoutGuide()
    /// The strip's share of `bottomChromeGuide`, directly above the accessory.
    private let stripGuide = UILayoutGuide()
    private var stripHeightConstraint: NSLayoutConstraint?
    /// Tracks the accessory's content height while the keyboard is down…
    private var accessoryLiveHeight: NSLayoutConstraint?
    /// …and holds it while the keyboard is up, so a bar that grows as the user
    /// types — more caption lines, a list of suggestions — draws over the media
    /// instead of shrinking it, and nothing behind it jumps or re-renders.
    private var accessoryFrozenHeight: NSLayoutConstraint?
    private var isKeyboardUp = false
    /// Whether the session shows its strip at all: two or more items, or a "+"
    /// cell to reach.
    private var stripIsInUse = false
    /// A tool (crop, drawing, filters) has the screen.
    private var isToolOpen = false

    // Overlay (sticker) layer, above the image preview.
    private let overlayContainer = OverlayContainerView()

    // Crop-mode chrome.
    private let cropOverlay = CropOverlayView()
    private let cropTopBar = UIStackView()
    private let cropToolsBar = UIStackView()          // flip / rotate presets
    private lazy var cropToolsBackground = appearance.makeBarBackground(cornerRadius: 20)
    private let rotationDial = RotationDialView()      // manual straighten
    private let cropAspectBar = UIStackView()
    private let cropAspectScroll = UIScrollView()
    private lazy var cropAspectBarBackground = appearance.makeBarBackground(cornerRadius: 24)
    private var aspectButtons: [(preset: AspectPreset, button: UIButton)] = []

    /// Whether crop mode is showing the stickers and drawing over the frame
    /// they belong to. They step aside while the user moves the frame, rotates
    /// or straightens, and come back laid over the new frame once they let go.
    private var cropShowsEdits = false

    // Crop-mode geometry state (folded into the recipe on apply).
    private var cropRotationBase: Double = 0           // 90° preset steps
    private var cropStraighten: Double = 0             // free dial angle
    private var cropFlip = FlipState.none

    // Draw-mode chrome.
    private let canvasView = PKCanvasView()
    private let toolPicker = PKToolPicker()
    private let drawTopBar = UIStackView()

    // Filter-mode chrome.
    private let filterTopBar = UIStackView()
    private let filterBar = FilterBarView()
    private lazy var filterBarBackground = appearance.makeBarBackground(cornerRadius: 20)
    private var filterWorkingFilter: PhotoFilter = .none

    private lazy var undoButton = makeToolButton(.undo, selector: #selector(undoTapped),
                                                 pointSize: historySymbolPointSize)
    private lazy var redoButton = makeToolButton(.redo, selector: #selector(redoTapped),
                                                 pointSize: historySymbolPointSize)
    /// Undo/redo glyphs match the tool row's when they get circles of their
    /// own; on the shared pill they stay smaller.
    private var historySymbolPointSize: CGFloat {
        appearance.toolbarStyle == .circularButtons ? appearance.toolSymbolPointSize
                                                     : appearance.historySymbolPointSize
    }
    private lazy var audioButton = makeToolButton(.toggleAudio, selector: #selector(toggleAudioTapped))
    /// What to hide to take the audio toggle out of the row — its circular
    /// backing under that style, otherwise the button itself.
    private var audioButtonHost: UIView?

    // MARK: - Init

    /// - Parameters:
    ///   - item: media to edit.
    ///   - recipe: a recipe to resume from, or `.identity` for a fresh session.
    ///   - configuration: enabled tools and export settings.
    ///   - appearance: how the built-in chrome is styled.
    ///   - toolbarProvider: supplies a replacement tool row, or `nil` for the
    ///     built-in one. Held weakly — keep your own reference to it.
    ///   - bottomAccessory: a bar the host owns, pinned full-width to the
    ///     bottom edge and lifted by the keyboard — typically a caption field and
    ///     a send button. Its background runs under the home indicator, so lay
    ///     its content out against its `safeAreaLayoutGuide` (or its layout
    ///     margins) and let the height follow. Call `finish()` from its send
    ///     action: with an accessory installed the editor shows no Done button of
    ///     its own. It is hidden while a tool (crop, drawing, filters) is open.
    ///   - onFinish: completion handler delivering the result.
    public convenience init(
        item: MediaItem,
        recipe: EditRecipe = .identity,
        configuration: EditorConfiguration = .default,
        appearance: EditorAppearance = .default,
        toolbarProvider: (any MediaEditorToolbarProviding)? = nil,
        bottomAccessory: UIView? = nil,
        onFinish: ((EditorResult) -> Void)? = nil
    ) {
        self.init(items: [MediaEditorItem(source: MediaSource(item), recipe: recipe)], selectedItemID: nil,
                  configuration: configuration, appearance: appearance, toolbarProvider: toolbarProvider,
                  bottomAccessory: bottomAccessory, isSingleItemEditor: true)
        self.onFinish = onFinish
    }

    /// Edits several items as one session — say, the photos and videos picked
    /// for a chat message. A thumbnail strip moves between them; each keeps its
    /// own edits and undo history.
    ///
    /// Confirming renders every edited item, or with
    /// `EditorConfiguration.finishMode` set to `.recipesOnly` hands back the
    /// recipes straight away for the host to render later with
    /// ``EditRenderer``. Removing the last item ends the session with
    /// `.cancelled`.
    ///
    /// - Parameters:
    ///   - items: what to edit, in strip order. Must not be empty.
    ///   - selectedItemID: the item shown first; `nil` for the first one.
    ///   - configuration: enabled tools, export settings and the finish mode.
    ///   - appearance: how the chrome and the strip are styled.
    ///   - toolbarProvider: supplies a replacement tool row; it's offered the
    ///     actions of every kind of media in the session and should reflect
    ///     `isEnabled(_:)` for the selected one.
    ///   - bottomAccessory: a bar the host owns, as for the single-item editor.
    ///     The strip sits directly above it.
    ///   - onFinish: called once with the session's result.
    public convenience init(
        items: [MediaEditorItem],
        selectedItemID: UUID? = nil,
        configuration: EditorConfiguration = .default,
        appearance: EditorAppearance = .default,
        toolbarProvider: (any MediaEditorToolbarProviding)? = nil,
        bottomAccessory: UIView? = nil,
        onFinish: ((MediaEditorSessionResult) -> Void)? = nil
    ) {
        self.init(items: items, selectedItemID: selectedItemID, configuration: configuration,
                  appearance: appearance, toolbarProvider: toolbarProvider,
                  bottomAccessory: bottomAccessory, isSingleItemEditor: false)
        self.onSessionFinish = onFinish
    }

    private init(
        items: [MediaEditorItem],
        selectedItemID: UUID?,
        configuration: EditorConfiguration,
        appearance: EditorAppearance,
        toolbarProvider: (any MediaEditorToolbarProviding)?,
        bottomAccessory: UIView?,
        isSingleItemEditor: Bool
    ) {
        precondition(!items.isEmpty, "A media editor session needs at least one item.")
        let selected = items.first { $0.id == selectedItemID } ?? items[0]
        self.items = items
        self.selectedItemID = selected.id
        self.isSingleItemEditor = isSingleItemEditor
        self.item = .photo(UIImage())                 // replaced by `prepareSelectedMedia`
        self.configuration = configuration
        self.appearance = appearance
        self.toolbarProvider = toolbarProvider
        self.bottomAccessory = bottomAccessory
        self.recipe = selected.recipe
        self.history = EditHistory(initial: selected.recipe, limit: configuration.historyLimit)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        // The editor is dark whatever the system setting — media reads best on
        // black, and the chrome is designed for it. The override flows down to
        // the host's accessory and toolbar, and `present` extends it to sheets.
        overrideUserInterfaceStyle = .dark
        // The tool palette floats in its own window, out of the override's reach.
        toolPicker.overrideUserInterfaceStyle = .dark
        // …but its swatches show ink as it will really come out. In dark mode
        // PencilKit would otherwise adapt them (black shown as white), and the
        // user would pick a colour the result doesn't have.
        toolPicker.colorUserInterfaceStyle = .light
        prepareSelectedMedia()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    public override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    /// Keeps whatever the editor presents — the text editor, the photo picker,
    /// an alert — as dark as the editor itself. A modal gets its traits from the
    /// window rather than from the presenter, so the override doesn't reach it
    /// on its own.
    public override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool,
                                 completion: (() -> Void)? = nil) {
        viewControllerToPresent.overrideUserInterfaceStyle = .dark
        super.present(viewControllerToPresent, animated: flag, completion: completion)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupChrome()
        setupCropChrome()
        setupDrawChrome()
        setupFilterChrome()
        setupPreview()
        setupStrip()
        liftChromeAbovePreview()
        renderPreview()
        overlayContainer.reload(overlays: recipe.overlays, images: overlayImages)
        updateDrawingLayer()
        updateHistoryButtons()
        updateHistoryVisibility(animated: false)
        refreshMainChrome()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving the screen shouldn't leave a video playing behind it. Only
        // pause: a host that pops back to the editor finds it as it was.
        player?.pause()
        syncTransport(animated: false)
        if mode == .draw { toolPicker.setVisible(false, forFirstResponder: canvasView) }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if refreshPreviewSourceIfNeeded(), mode == .normal { renderPreview() }
        layoutVideoPreview()
        // Container shares the image view's frame, so the displayed-image rect
        // (in image-view bounds coordinates) maps directly to container bounds.
        // Bounds and centre rather than frame: while zoomed both views carry
        // the same transform, and a frame would be the zoomed outline.
        overlayContainer.bounds = imageView.bounds
        overlayContainer.center = imageView.center
        syncOverlayCanvas()
        if mode == .crop {
            positionCropOverlay()
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if mode == .draw {
            toolPicker.setVisible(true, forFirstResponder: canvasView)
            canvasView.becomeFirstResponder()
        }
        // UI-test / demo affordance: auto-enter crop for screenshotting. Inert
        // unless the host launches with this argument.
        if ProcessInfo.processInfo.arguments.contains("-MEStartInCrop"),
           mode == .normal, sourceCGImage != nil {
            enterCropMode()
            // Demo: apply a straighten so the dial + inscribed crop are visible.
            if ProcessInfo.processInfo.arguments.contains("-MEStraighten") {
                rotationDial.setDegrees(12)
                rotationDial(rotationDial, didChangeTo: 12)
            }
            if ProcessInfo.processInfo.arguments.contains("-MERotate90") {
                cropRotateTapped()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-MEStartInDraw"),
           mode == .normal, sourceCGImage != nil {
            enterDrawingMode()
        }
        if ProcessInfo.processInfo.arguments.contains("-MEStartInFilters"),
           mode == .normal, sourceCGImage != nil {
            enterFilterMode()
        }
        if ProcessInfo.processInfo.arguments.contains("-MEAddText"), sourceCGImage != nil {
            addText()
        }
        if ProcessInfo.processInfo.arguments.contains("-MESelectSticker") {
            overlayContainer.selectFirst()
        }
    }

    // MARK: - Layout

    private func setupPreview() {
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),
            previewBottomConstraint(),
        ])

        // Passthrough content — a GIF, a document — fills the preview area in
        // place of the image.
        passthroughHost.translatesAutoresizingMaskIntoConstraints = false
        passthroughHost.isHidden = true
        view.addSubview(passthroughHost)
        NSLayoutConstraint.activate([
            passthroughHost.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            passthroughHost.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            passthroughHost.topAnchor.constraint(equalTo: imageView.topAnchor),
            passthroughHost.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
        ])

        // Sticker layer floats over the image; positioned in layout passes.
        overlayContainer.delegate = self
        overlayContainer.appearance = appearance
        // Asked at drag time rather than stored at layout: the accessory's
        // height can settle after the first pass, and the keyboard moves it.
        overlayContainer.trashCenterProvider = { [weak self] in self?.trashCenterAboveBottomControls() }
        overlayContainer.clipsToBounds = false
        view.addSubview(overlayContainer)

        overlayContainer.onCanvasPan = { [weak self] pan in self?.handleCanvasPan(pan) }
        overlayContainer.onCanvasPinch = { [weak self] pinch in self?.handleCanvasPinch(pinch) }
        overlayContainer.onCanvasDoubleTap = { [weak self] location in self?.handleCanvasDoubleTap(at: location) }
        if allowsPaging {
            passthroughHost.addGestureRecognizer(
                PagingPanGestureRecognizer(target: self, action: #selector(handlePagingPan(_:))))
        }
        updateCanvasPan()

        loadSelectedMediaViews()
    }

    /// Where the preview stops. Under a bottom tool row it leaves the row's
    /// height plus breathing room; with the row at the top it only has to clear
    /// the floating Done button or the accessory.
    private func previewBottomConstraint() -> NSLayoutConstraint {
        switch appearance.toolbarPlacement {
        case .bottom:
            return imageView.bottomAnchor.constraint(equalTo: bottomChromeGuide.topAnchor, constant: -88)
        case .top:
            let anchor = floatingDoneButton?.topAnchor ?? bottomChromeGuide.topAnchor
            return imageView.bottomAnchor.constraint(equalTo: anchor, constant: -16)
        }
    }

    /// The preview and its sticker layer are added after the chrome, and the
    /// sticker layer claims every touch inside the preview rect. The history
    /// pill sits just below the top bar — i.e. *inside* that rect — so the
    /// chrome has to be lifted back above it or its buttons never see a tap.
    ///
    /// The accessory goes last: the keyboard lifts it over the preview and the
    /// video controls, and it has to stay on top of both while it does.
    private func liftChromeAbovePreview() {
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(historyContainer)
        let strip: UIView? = isSingleItemEditor ? nil : thumbnailStrip
        for chrome in [toolRowContainer, floatingDoneButton, strip, bottomAccessory] {
            if let chrome, chrome.superview === view { view.bringSubviewToFront(chrome) }
        }
    }

    /// Where the sticker delete bin goes: centred just above the highest control
    /// along the bottom — the video's time readout or filmstrip, the tool row,
    /// the floating Done button, the accessory — which is close to where the
    /// thumb already is.
    ///
    /// It has to clear all of them rather than tuck beneath one: they are
    /// layered above the sticker layer the bin lives in, and with a bottom tool
    /// row stacked on an accessory, or the keyboard lifting the accessory over
    /// the video controls, the lowest one alone isn't enough. The gap leaves
    /// room for the bin's armed swell, spring overshoot included.
    private func trashCenterAboveBottomControls() -> CGPoint? {
        let filmstrip: UIView? = showsTrimScrubber ? trimScrubber : nil
        let strip: UIView? = stripIsInUse ? thumbnailStrip : nil
        let candidates = [videoControlsTop, filmstrip, toolRowAtBottom, floatingDoneButton, strip, bottomAccessory]
        let tops = candidates.compactMap { control -> CGFloat? in
            // Hidden controls count too: the time readout stays hidden until the
            // clip loads, and the bin should already clear the spot it takes.
            guard let control, control.superview != nil else { return nil }
            let frame = view.convert(control.bounds, from: control)
            return frame.height > 0 ? frame.minY : nil        // not laid out yet
        }
        guard let controlsTop = tops.min(), controlsTop > 0 else { return nil }
        let center = CGPoint(x: view.bounds.midX,
                             y: controlsTop - 16 - StickerTrashView.diameter / 2)
        return overlayContainer.convert(center, from: view)
    }

    /// The tool row, when it sits along the bottom rather than in the top bar.
    private var toolRowAtBottom: UIView? {
        appearance.toolbarPlacement == .bottom ? toolRowContainer : nil
    }

    private func setupChrome() {
        // Top bar: Cancel / Done
        let cancel = makeCancelButton()
        setupHistoryBar()

        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 8
        topBar.addArrangedSubview(cancel)
        topBar.addArrangedSubview(UIView())          // pushes the rest to the trailing edge
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        // The top bar is identical whoever supplies the tool row, so pin it here
        // rather than in each branch below.
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            historyContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            historyContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
        ])

        setupBottomAccessory()

        let row = makeToolRow()
        toolRowContainer = row
        switch appearance.toolbarPlacement {
        case .top:
            // Tools trail the close button; Done, if the editor shows one, drops
            // to the bottom trailing corner where a send button would be.
            if let row {
                row.setContentCompressionResistancePriority(.required, for: .horizontal)
                topBar.addArrangedSubview(row)
            }
            if showsDoneButton {
                let done = makeTextButton(L10n.done, role: .confirming, action: #selector(doneTapped))
                done.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(done)
                NSLayoutConstraint.activate([
                    done.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                    done.bottomAnchor.constraint(equalTo: bottomChromeGuide.topAnchor, constant: -12),
                ])
                floatingDoneButton = done
            }
        case .bottom:
            if showsDoneButton {
                topBar.addArrangedSubview(makeTextButton(L10n.done, role: .confirming, action: #selector(doneTapped)))
            }
            if let row {
                row.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(row)
                NSLayoutConstraint.activate([
                    // The row holds tools only, so it hugs its content and
                    // centres rather than stretching the full width.
                    row.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    row.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
                    row.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
                    row.bottomAnchor.constraint(equalTo: bottomChromeGuide.topAnchor, constant: -12),
                ])
            }
        }

        if let customToolbar, let toolbarProvider {
            toolbarProvider.updateToolbar(customToolbar, editor: self)
        }
    }

    /// Undo and redo, on their own row under Cancel rather than beside it, so
    /// the top bar keeps its shape. Drawn like the tool row: two glyphs sharing
    /// a small glass pill, or a circle each.
    private func setupHistoryBar() {
        historyBar.axis = .horizontal
        historyBar.alignment = .center
        historyBar.translatesAutoresizingMaskIntoConstraints = false
        switch appearance.toolbarStyle {
        case .circularButtons:
            historyBar.spacing = 8
            historyBar.addArrangedSubview(appearance.makeCircularBacking(for: undoButton))
            historyBar.addArrangedSubview(appearance.makeCircularBacking(for: redoButton))
            historyContainer = historyBar
        case .floatingBar:
            historyBar.spacing = 16
            historyBar.addArrangedSubview(undoButton)
            historyBar.addArrangedSubview(redoButton)
            historyBarBackground.translatesAutoresizingMaskIntoConstraints = false
            historyBarBackground.contentView.addSubview(historyBar)
            NSLayoutConstraint.activate([
                historyBar.leadingAnchor.constraint(equalTo: historyBarBackground.contentView.leadingAnchor, constant: 12),
                historyBar.trailingAnchor.constraint(equalTo: historyBarBackground.contentView.trailingAnchor, constant: -12),
                historyBar.topAnchor.constraint(equalTo: historyBarBackground.contentView.topAnchor, constant: 4),
                historyBar.bottomAnchor.constraint(equalTo: historyBarBackground.contentView.bottomAnchor, constant: -4),
            ])
            historyContainer = historyBarBackground
        }
        view.addSubview(historyContainer)
    }

    /// Pins the host's accessory full-width to the keyboard, and sizes
    /// `bottomChromeGuide` to match.
    ///
    /// Like a toolbar, the accessory runs to the physical bottom edge so its
    /// background fills the home-indicator strip, and keeps its content clear
    /// of that strip through its own `safeAreaInsets`. Those follow the bar: on
    /// top of the keyboard it no longer overlaps the strip, so the inset drops to
    /// zero and there is no gap above the keys.
    private func setupBottomAccessory() {
        for guide in [accessoryGuide, stripGuide, bottomChromeGuide] { view.addLayoutGuide(guide) }
        let stripHeight = stripGuide.heightAnchor.constraint(equalToConstant: 0)
        stripHeightConstraint = stripHeight
        NSLayoutConstraint.activate([
            accessoryGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accessoryGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            accessoryGuide.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stripGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stripGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stripGuide.bottomAnchor.constraint(equalTo: accessoryGuide.topAnchor),
            stripHeight,

            bottomChromeGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomChromeGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomChromeGuide.topAnchor.constraint(equalTo: stripGuide.topAnchor),
            bottomChromeGuide.bottomAnchor.constraint(equalTo: accessoryGuide.bottomAnchor),
        ])
        guard let accessory = bottomAccessory else {
            accessoryGuide.heightAnchor.constraint(equalToConstant: 0).isActive = true
            return
        }
        // With the keyboard down the guide rests on the bottom edge rather than
        // the safe area, which the accessory handles itself.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        accessory.translatesAutoresizingMaskIntoConstraints = false
        // Slack never goes to the bar, whatever the canvas's content reports.
        accessory.setContentHuggingPriority(.defaultHigh + 1, for: .vertical)
        view.addSubview(accessory)
        // The bar's content height, above the safe area: resting, the bar also
        // covers the home-indicator strip; lifted by the keyboard it doesn't.
        // Measuring its content keeps the guide — and everything laid out on
        // it — still while the user types.
        let live = accessoryGuide.heightAnchor.constraint(equalTo: accessory.safeAreaLayoutGuide.heightAnchor)
        accessoryLiveHeight = live
        NSLayoutConstraint.activate([
            accessory.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accessory.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            accessory.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            live,
        ])
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// The keyboard is coming up: hold the space reserved for the accessory at
    /// its resting height, and fade the strip if the appearance asks.
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard !isKeyboardUp, let live = accessoryLiveHeight else { return }
        isKeyboardUp = true
        let frozen = accessoryGuide.heightAnchor.constraint(equalToConstant: accessoryGuide.layoutFrame.height)
        live.isActive = false
        frozen.isActive = true
        accessoryFrozenHeight = frozen
        applyStripVisibility(animated: true)
    }

    /// The keyboard is gone: follow the accessory's content height again —
    /// animated, in case it changed while the user typed.
    @objc private func keyboardWillHide(_ notification: Notification) {
        guard isKeyboardUp else { return }
        isKeyboardUp = false
        accessoryFrozenHeight?.isActive = false
        accessoryFrozenHeight = nil
        accessoryLiveHeight?.isActive = true
        applyStripVisibility(animated: true)
        UIView.animate(withDuration: 0.25) { [weak self] in self?.view.layoutIfNeeded() }
    }

    /// Builds the tool row — the provider's, when it supplies one — without
    /// placing it; `setupChrome` decides where it goes.
    private func makeToolRow() -> UIView? {
        if let provider = toolbarProvider,
           let custom = provider.makeToolbar(for: isSingleItemEditor ? toolbarActions : sessionToolbarActions,
                                             editor: self) {
            customToolbar = custom
            return custom
        }
        let buttons = toolbarButtons()
        // A session may move on to media with tools even if this one has none.
        guard !buttons.isEmpty || !isSingleItemEditor else { return nil }

        toolRow.axis = .horizontal
        toolRow.distribution = .fill
        toolRow.alignment = .center
        for v in buttons { toolRow.addArrangedSubview(v) }

        switch appearance.toolbarStyle {
        case .circularButtons:
            // Each button carries its own backing, so the row itself is bare.
            toolRow.spacing = appearance.toolbarPlacement == .top ? 8 : 12
            return toolRow
        case .floatingBar:
            // Tighter in the top bar, where it shares the width with Cancel.
            toolRow.spacing = appearance.toolbarPlacement == .top ? 20 : 28
            let inset: CGFloat = appearance.toolbarPlacement == .top ? 16 : 24
            toolRow.translatesAutoresizingMaskIntoConstraints = false
            toolRowBackground.contentView.addSubview(toolRow)
            NSLayoutConstraint.activate([
                toolRow.leadingAnchor.constraint(equalTo: toolRowBackground.contentView.leadingAnchor, constant: inset),
                toolRow.trailingAnchor.constraint(equalTo: toolRowBackground.contentView.trailingAnchor, constant: -inset),
                toolRow.topAnchor.constraint(equalTo: toolRowBackground.contentView.topAnchor, constant: 12),
                toolRow.bottomAnchor.constraint(equalTo: toolRowBackground.contentView.bottomAnchor, constant: -12),
            ])
            return toolRowBackground
        }
    }

    /// Cancel as a titled bar button, or as an ✕ on a circular backing to match
    /// ``EditorToolbarStyle/circularButtons``.
    private func makeCancelButton() -> UIView {
        switch appearance.toolbarStyle {
        case .floatingBar:
            return makeTextButton(L10n.cancel, role: .dismissing, action: #selector(cancelTapped))
        case .circularButtons:
            let button = makeSymbolButton(symbol: appearance.symbols[.cancel] ?? "xmark",
                                          selector: #selector(cancelTapped))
            button.accessibilityLabel = L10n.cancel
            appearance.styleToolButton?(button, .cancel)
            return appearance.makeCircularBacking(for: button)
        }
    }

    private func setupCropChrome() {
        // Crop top bar: Cancel / "Crop" / Apply
        let cancel = makeTextButton(L10n.cancel, role: .dismissing, action: #selector(cancelCropTapped))
        let title = UILabel()
        title.text = L10n.cropTitle
        title.textColor = .white
        title.font = .boldSystemFont(ofSize: 16)
        let apply = makeTextButton(L10n.apply, role: .confirming, action: #selector(applyCropTapped))
        cropTopBar.axis = .horizontal
        cropTopBar.alignment = .center
        cropTopBar.distribution = .equalCentering
        cropTopBar.addArrangedSubview(cancel)
        cropTopBar.addArrangedSubview(title)
        cropTopBar.addArrangedSubview(apply)
        cropTopBar.translatesAutoresizingMaskIntoConstraints = false
        cropTopBar.isHidden = true
        view.addSubview(cropTopBar)

        // Crop tools bar (flip / rotate presets), leading under the top bar.
        cropToolsBar.axis = .horizontal
        cropToolsBar.spacing = 18
        cropToolsBar.alignment = .center
        for button in cropToolButtons() { cropToolsBar.addArrangedSubview(button) }
        cropToolsBar.translatesAutoresizingMaskIntoConstraints = false
        cropToolsBackground.translatesAutoresizingMaskIntoConstraints = false
        cropToolsBackground.isHidden = true
        view.addSubview(cropToolsBackground)
        cropToolsBackground.contentView.addSubview(cropToolsBar)

        // Manual straighten dial, above the aspect bar.
        rotationDial.delegate = self
        cropOverlay.onAdjustmentBegan = { [weak self] in self?.cropAdjustmentBegan() }
        cropOverlay.onAdjustmentEnded = { [weak self] in self?.cropAdjustmentEnded() }
        rotationDial.translatesAutoresizingMaskIntoConstraints = false
        rotationDial.isHidden = true
        view.addSubview(rotationDial)

        // Crop aspect bar: one button per configured preset + Reset.
        cropAspectBar.axis = .horizontal
        cropAspectBar.distribution = .equalSpacing
        cropAspectBar.alignment = .center
        for preset in configuration.aspectPresets {
            let button = makeTextButton(label(for: preset), role: .dismissing, action: #selector(aspectTapped(_:)))
            aspectButtons.append((preset, button))
            cropAspectBar.addArrangedSubview(button)
        }
        let reset = makeSymbolButton(symbol: "arrow.counterclockwise", selector: #selector(resetCropTapped))
        cropAspectBar.addArrangedSubview(reset)
        cropAspectBar.translatesAutoresizingMaskIntoConstraints = false
        // More presets than fit the width (Original + Free + four ratios + reset
        // already overflow a narrow phone), so the row scrolls.
        cropAspectScroll.showsHorizontalScrollIndicator = false
        cropAspectScroll.translatesAutoresizingMaskIntoConstraints = false
        cropAspectBarBackground.translatesAutoresizingMaskIntoConstraints = false
        cropAspectBarBackground.isHidden = true
        view.addSubview(cropAspectBarBackground)
        cropAspectBarBackground.contentView.addSubview(cropAspectScroll)
        cropAspectScroll.addSubview(cropAspectBar)

        NSLayoutConstraint.activate([
            cropTopBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            cropTopBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            cropTopBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            cropToolsBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            cropToolsBackground.topAnchor.constraint(equalTo: cropTopBar.bottomAnchor, constant: 10),
            cropToolsBar.leadingAnchor.constraint(equalTo: cropToolsBackground.contentView.leadingAnchor, constant: 16),
            cropToolsBar.trailingAnchor.constraint(equalTo: cropToolsBackground.contentView.trailingAnchor, constant: -16),
            cropToolsBar.topAnchor.constraint(equalTo: cropToolsBackground.contentView.topAnchor, constant: 8),
            cropToolsBar.bottomAnchor.constraint(equalTo: cropToolsBackground.contentView.bottomAnchor, constant: -8),

            rotationDial.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            rotationDial.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            rotationDial.heightAnchor.constraint(equalToConstant: 44),
            rotationDial.bottomAnchor.constraint(equalTo: cropAspectBarBackground.topAnchor, constant: -10),

            cropAspectBarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            cropAspectBarBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            cropAspectBarBackground.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            cropAspectScroll.leadingAnchor.constraint(equalTo: cropAspectBarBackground.contentView.leadingAnchor, constant: 18),
            cropAspectScroll.trailingAnchor.constraint(equalTo: cropAspectBarBackground.contentView.trailingAnchor, constant: -18),
            cropAspectScroll.topAnchor.constraint(equalTo: cropAspectBarBackground.contentView.topAnchor, constant: 10),
            cropAspectScroll.bottomAnchor.constraint(equalTo: cropAspectBarBackground.contentView.bottomAnchor, constant: -10),

            cropAspectBar.leadingAnchor.constraint(equalTo: cropAspectScroll.contentLayoutGuide.leadingAnchor),
            cropAspectBar.trailingAnchor.constraint(equalTo: cropAspectScroll.contentLayoutGuide.trailingAnchor),
            cropAspectBar.topAnchor.constraint(equalTo: cropAspectScroll.contentLayoutGuide.topAnchor),
            cropAspectBar.bottomAnchor.constraint(equalTo: cropAspectScroll.contentLayoutGuide.bottomAnchor),
            cropAspectBar.heightAnchor.constraint(equalTo: cropAspectScroll.frameLayoutGuide.heightAnchor),
            // At least the full width, so a short row stays spread and centred
            // instead of bunching up at the leading edge.
            cropAspectBar.widthAnchor.constraint(greaterThanOrEqualTo: cropAspectScroll.frameLayoutGuide.widthAnchor),
        ])
    }

    /// The crop tool's flip and rotate presets the selected media offers.
    private func cropToolButtons() -> [UIButton] {
        let tools = configuration.tools(for: item.kind)
        var buttons: [UIButton] = []
        if tools.contains(.flip) {
            buttons.append(makeToolButton(.flipHorizontal, selector: #selector(cropFlipHTapped)))
            buttons.append(makeToolButton(.flipVertical, selector: #selector(cropFlipVTapped)))
        }
        if tools.contains(.rotate) {
            buttons.append(makeToolButton(.rotate, selector: #selector(cropRotateTapped)))
        }
        return buttons
    }

    private func setupDrawChrome() {
        let cancel = makeTextButton(L10n.cancel, role: .dismissing, action: #selector(cancelDrawTapped))
        let title = UILabel()
        title.text = L10n.drawTitle
        title.textColor = .white
        title.font = .boldSystemFont(ofSize: 16)
        let done = makeTextButton(L10n.done, role: .confirming, action: #selector(applyDrawTapped))
        drawTopBar.axis = .horizontal
        drawTopBar.alignment = .center
        drawTopBar.distribution = .equalCentering
        drawTopBar.addArrangedSubview(cancel)
        drawTopBar.addArrangedSubview(title)
        drawTopBar.addArrangedSubview(done)
        drawTopBar.translatesAutoresizingMaskIntoConstraints = false
        drawTopBar.isHidden = true
        view.addSubview(drawTopBar)

        canvasView.drawingPolicy = .anyInput          // allow finger drawing (and simulator)
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        // Strokes are drawn straight onto the media, so show their true colours
        // rather than PencilKit's dark-mode adaptation — the canvas is clear, so
        // nothing else about it looks light.
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.alwaysBounceVertical = false
        canvasView.alwaysBounceHorizontal = false

        NSLayoutConstraint.activate([
            drawTopBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            drawTopBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            drawTopBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
    }

    private func setupFilterChrome() {
        let cancel = makeTextButton(L10n.cancel, role: .dismissing, action: #selector(cancelFilterTapped))
        let title = UILabel()
        title.text = L10n.filtersTitle
        title.textColor = .white
        title.font = .boldSystemFont(ofSize: 16)
        let done = makeTextButton(L10n.done, role: .confirming, action: #selector(applyFilterTapped))
        filterTopBar.axis = .horizontal
        filterTopBar.alignment = .center
        filterTopBar.distribution = .equalCentering
        filterTopBar.addArrangedSubview(cancel)
        filterTopBar.addArrangedSubview(title)
        filterTopBar.addArrangedSubview(done)
        filterTopBar.translatesAutoresizingMaskIntoConstraints = false
        filterTopBar.isHidden = true
        view.addSubview(filterTopBar)

        filterBar.delegate = self
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBarBackground.translatesAutoresizingMaskIntoConstraints = false
        filterBarBackground.isHidden = true
        view.addSubview(filterBarBackground)
        filterBarBackground.contentView.addSubview(filterBar)

        NSLayoutConstraint.activate([
            filterTopBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            filterTopBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            filterTopBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            filterBarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            filterBarBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            filterBarBackground.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            filterBar.leadingAnchor.constraint(equalTo: filterBarBackground.contentView.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: filterBarBackground.contentView.trailingAnchor),
            filterBar.topAnchor.constraint(equalTo: filterBarBackground.contentView.topAnchor, constant: 10),
            filterBar.bottomAnchor.constraint(equalTo: filterBarBackground.contentView.bottomAnchor, constant: -10),
            filterBar.heightAnchor.constraint(equalToConstant: 92),
        ])
    }

    /// Builds the enabled tool buttons, each on its circular backing when the
    /// appearance asks for one.
    private func toolbarButtons() -> [UIView] {
        var buttons: [UIButton] = []
        let tools = configuration.tools(for: item.kind)
        if tools.contains(.crop) {
            buttons.append(makeToolButton(.crop, selector: #selector(cropTapped)))
        }
        // Rotate/flip live inside the crop tool (like iOS Photos) when crop is
        // available; otherwise they stay in the main toolbar.
        if !tools.contains(.crop) {
            if tools.contains(.rotate) {
                buttons.append(makeToolButton(.rotate, selector: #selector(rotateTapped)))
            }
            if tools.contains(.flip) {
                buttons.append(makeToolButton(.flipHorizontal, selector: #selector(flipHTapped)))
                buttons.append(makeToolButton(.flipVertical, selector: #selector(flipVTapped)))
            }
        }
        if tools.contains(.filters) {
            buttons.append(makeToolButton(.filters, selector: #selector(filterTapped)))
        }
        if tools.contains(.drawing) {
            buttons.append(makeToolButton(.drawing, selector: #selector(drawTapped)))
        }
        if tools.contains(.overlays) {
            buttons.append(makeToolButton(.addText, selector: #selector(addTextTapped)))
            buttons.append(makeToolButton(.addPhoto, selector: #selector(addPhotoTapped)))
        }
        if tools.contains(.audio) {
            buttons.append(audioButton)
        }
        let views: [UIView] = buttons.map { button in
            let host = appearance.toolbarStyle == .circularButtons
                ? appearance.makeCircularBacking(for: button)
                : button
            if button === audioButton {
                // Stays out of the row until the asset is known to carry audio.
                audioButtonHost = host
                host.isHidden = true
            }
            return host
        }
        return views
    }

    /// A tool-row button for `action`, styled through the appearance so a host
    /// can re-skin it or swap its glyph.
    private func makeToolButton(_ action: EditorAction, selector: Selector,
                                pointSize: CGFloat? = nil) -> UIButton {
        let button = UIButton(type: .system)
        appearance.styleToolButton(button, action: action, pointSize: pointSize)
        button.addTarget(self, action: selector, for: .touchUpInside)
        return button
    }

    /// A symbol button that isn't one of the editor's actions — the crop tool's
    /// reset control, for instance.
    private func makeSymbolButton(symbol: String, selector: Selector) -> UIButton {
        let button = UIButton(type: .system)
        appearance.styleSymbolButton(button, symbol: symbol)
        button.addTarget(self, action: selector, for: .touchUpInside)
        return button
    }

    private func makeTextButton(_ title: String, role: EditorBarButtonRole, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        appearance.styleBarButton(button, title: title, role: role)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func label(for preset: AspectPreset) -> String {
        switch preset {
        case .original: return L10n.aspectOriginal
        case .free: return L10n.aspectFree
        case .square: return "1:1"
        case let .ratio(w, h): return "\(Int(w)):\(Int(h))"
        }
    }

    // MARK: - Rendering

    /// The image edits are previewed from — downscaled to the display, falling
    /// back to the full source until the view has been laid out.
    private var previewSource: CGImage? { previewSourceCGImage ?? sourceCGImage }

    /// Rebuilds `previewSourceCGImage` when the preview's pixel size changes.
    /// Returns whether it changed, so the caller can re-render.
    @discardableResult
    private func refreshPreviewSourceIfNeeded() -> Bool {
        guard let sourceCGImage, isViewLoaded else { return false }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        // Zoomed in, the preview shows more pixels per point — up to the
        // source's own, which the check below caps it at.
        let cap = (max(imageView.bounds.width, imageView.bounds.height) * scale * zoomScale).rounded()
        guard cap > 0, abs(cap - previewSourceCap) > 1 else { return false }
        previewSourceCap = cap

        // Nothing to gain if the source is already smaller than the preview.
        if CGFloat(max(sourceCGImage.width, sourceCGImage.height)) <= cap {
            previewSourceCGImage = sourceCGImage
        } else {
            previewSourceCGImage = downscaled(cgImage: sourceCGImage, maxDimension: cap) ?? sourceCGImage
        }
        return true
    }

    private func renderPreview() {
        guard mode == .normal else { return }        // crop/draw modes manage their own image
        guard let source = previewSource, isViewLoaded else { return }
        guard let rendered = renderer.renderGeometry(cgImage: source, recipe: recipe) else { return }
        // The drawing and overlays are live layers on top, not baked in.
        imageView.image = UIImage(cgImage: rendered)
        syncOverlayCanvas()
    }

    /// Where the stickers and the drawing are laid out, in the image view's
    /// coordinates: over the displayed media. In crop mode that's the whole
    /// rotated frame, and the edits are carried onto it (see
    /// `showEditsOverCropPreview`).
    private func overlayCanvasFrame() -> CGRect {
        displayedImageFrame()
    }

    /// Rasterizes the recipe's drawing when it changes, and stacks it where the
    /// recipe says among the stickers.
    private func updateDrawingLayer() {
        showDrawing(recipe.drawing)
    }

    /// Puts `drawing` on screen, re-rasterizing only when it changed.
    ///
    /// Drawn at the authoring canvas size — the media's on-screen size when the
    /// strokes went down — and stretched with the media from there, as the
    /// export stretches it to the output size.
    private func showDrawing(_ drawing: DrawingData?) {
        overlayContainer.drawingZIndex = drawing?.zIndex ?? .min
        shownDrawing = drawing
        rasterizeDrawingIfNeeded()
    }

    /// Rasterizes the shown drawing at the size it's displayed at — not its
    /// canvas size, which after a crop can be far smaller (blurry) or, carried
    /// onto a wider frame, far larger (tens of megabytes) than the screen.
    private func rasterizeDrawingIfNeeded() {
        guard let drawing = shownDrawing else {
            renderedDrawing = nil
            drawingLayerView.image = nil
            return
        }
        let scale = max(1, traitCollection.displayScale)
        let frame = overlayContainer.imageFrame.size
        let points = frame.width > 0 && frame.height > 0
            ? frame : CGSize(width: drawing.canvasWidth, height: drawing.canvasHeight)
        let pixels = CGSize(width: (points.width * scale).rounded(), height: (points.height * scale).rounded())
        guard pixels != renderedDrawingPixels || drawing != renderedDrawing else { return }
        renderedDrawing = drawing
        renderedDrawingPixels = pixels
        drawingLayerView.image = drawingCompositor.strokeImage(for: drawing, outputSize: pixels)
    }

    /// Lays the stickers and drawing over the displayed media, re-rasterizing
    /// the drawing if its on-screen size changed.
    private func syncOverlayCanvas() {
        overlayContainer.imageFrame = overlayCanvasFrame()
        rasterizeDrawingIfNeeded()
    }

    /// The rect within `imageView.bounds` where the image is actually displayed
    /// under aspect-fit — the frame the crop overlay constrains itself to.
    private func displayedImageFrame() -> CGRect {
        if case .video = item {
            // The visible video rect, so overlays anchor to the frame rather
            // than to the letterboxing around it.
            return videoContainer.frame.isEmpty ? imageView.bounds : videoContainer.frame
        }
        guard let image = imageView.image, image.size.width > 0 else { return imageView.bounds }
        return AVMakeRect(aspectRatio: image.size, insideRect: imageView.bounds)
    }

    private func updateHistoryButtons() {
        undoButton.isEnabled = history.canUndo
        redoButton.isEnabled = history.canRedo
        undoButton.alpha = history.canUndo ? 1 : 0.35
        redoButton.alpha = history.canRedo ? 1 : 0.35
        updateHistoryVisibility(animated: isViewLoaded && view.window != nil)
        notifyToolbarStateChanged()
    }

    /// Undo/redo stay out of sight until there is something to undo or redo,
    /// and while a tool is open — it has its own Cancel.
    private func updateHistoryVisibility(animated: Bool) {
        let show = mode == .normal && !isPassthrough && (history.canUndo || history.canRedo)
        let target: CGFloat = show ? 1 : 0
        guard animated else {
            historyContainer.layer.removeAllAnimations()
            historyContainer.alpha = target
            historyContainer.isHidden = !show
            return
        }
        guard historyContainer.isHidden == show || historyContainer.alpha != target else { return }
        if show && historyContainer.isHidden {
            historyContainer.alpha = 0
            historyContainer.isHidden = false
        }
        UIView.animate(withDuration: 0.2, animations: { [weak self] in
            self?.historyContainer.alpha = target
        }, completion: { [weak self] _ in
            // A later call may have brought it back mid-fade.
            guard let self, historyContainer.alpha == 0 else { return }
            historyContainer.isHidden = true
        })
    }

    /// Lets a host-supplied tool row refresh itself after any state change.
    private func notifyToolbarStateChanged() {
        guard let customToolbar, let toolbarProvider else { return }
        toolbarProvider.updateToolbar(customToolbar, editor: self)
    }

    /// Shows or hides the main-mode chrome while a tool has the screen.
    private func setMainToolbarHidden(_ hidden: Bool) {
        if hidden { bottomAccessory?.endEditing(true) }     // a tool is taking over the screen
        isToolOpen = hidden
        refreshMainChrome()
    }

    /// Brings the main-mode chrome in line with the editor's state: hidden
    /// while a tool is open — the tool row, the floating Done button, the strip
    /// and the accessory — and the tool row also for media it has nothing to
    /// offer, such as passthrough content. A custom row can opt out of hiding
    /// while a tool is open — though at the top it lives in the top bar, which
    /// every tool swaps out for its own.
    private func refreshMainChrome() {
        updateHistoryVisibility(animated: false)
        bottomAccessory?.isHidden = isToolOpen
        floatingDoneButton?.isHidden = isToolOpen
        let nothingToOffer = isPassthrough || (customToolbar == nil && toolRow.arrangedSubviews.isEmpty)
        if let customToolbar {
            let hidesForTool = isToolOpen && (toolbarProvider?.hidesToolbarInToolMode(customToolbar) ?? true)
            customToolbar.isHidden = hidesForTool || isPassthrough
        } else {
            toolRowContainer?.isHidden = isToolOpen || nothingToOffer
        }
        applyStripVisibility(animated: false)
    }

    /// What the video controls stack above — the tool row when it sits at the
    /// bottom (the buttons themselves, for the glass bar), otherwise the floating
    /// Done button or the accessory's resting place.
    private var bottomChromeTopAnchor: NSLayoutYAxisAnchor {
        if appearance.toolbarPlacement == .bottom, let toolRowContainer {
            return toolRowContainer === toolRowBackground ? toolRow.topAnchor : toolRowContainer.topAnchor
        }
        return floatingDoneButton?.topAnchor ?? bottomChromeGuide.topAnchor
    }

    // MARK: - Geometry changes

    /// `next`, with `old`'s stickers and drawing moved so they stay on the same
    /// part of the media under `next`'s flip, rotation and crop — rather than
    /// riding along with the frame.
    private func carryingEdits(into next: EditRecipe, from old: EditRecipe) -> EditRecipe {
        let size = cropSourceSize
        guard size.width > 0, size.height > 0,
              next.rotation != old.rotation || next.flip != old.flip || next.crop?.rect != old.crop?.rect
        else { return next }
        var carried = next.carryingOverlays(from: old, sourceSize: size)
        if let drawing = old.drawing {
            let before = MediaGeometry(recipe: old, sourceSize: size)
            let after = MediaGeometry(recipe: next, sourceSize: size)
            carried.drawing = drawingCompositor.carried(drawing, by: before.transform(to: after),
                                                        from: before.outputSize, to: after.outputSize)
        }
        return carried
    }

    /// Records a flip, rotation or crop, carrying the edits along with the
    /// media.
    private func applyGeometry(_ next: EditRecipe) {
        apply(carryingEdits(into: next, from: recipe))
        reloadOverlaysFromRecipe()
    }

    // MARK: - Crop mode

    @objc private func cropTapped() { enterCropMode() }

    /// Enters crop mode: rotate/flip presets and a straighten dial operate on the
    /// image behind a crop frame, matching the iOS Photos crop tool.
    public func enterCropMode() {
        guard mode == .normal, cropSourceSize.width > 0, cropSourceSize.height > 0 else { return }
        if case .photo = item, sourceCGImage == nil { return }
        resetZoom()
        mode = .crop

        // A still frame is what you compose a crop against, and the transport
        // and filmstrip would collide with the crop chrome.
        if case .video = item {
            setPlaybackChromeHidden(true)
        }

        // Split the recipe's rotation into a 90° preset base and a straighten
        // remainder so the dial reflects the current angle.
        let degrees = recipe.rotation.degrees
        let preset = (degrees / 90).rounded() * 90
        cropRotationBase = preset
        cropStraighten = degrees - preset
        cropFlip = recipe.flip
        rotationDial.setDegrees(cropStraighten)

        // The edits stay in view, on the part of the media they belong to, and
        // step aside only while the user adjusts. They're for looking at only.
        overlayContainer.deselect()
        overlayContainer.isUserInteractionEnabled = false
        // The whole frame is on show; the crop overlay dims what the crop
        // leaves out, stickers included.
        overlayContainer.clipsToCanvas = false
        cropShowsEdits = true

        // A fresh crop starts locked to the source's own ratio, so the frame
        // opens on the whole media rather than a freeform rect.
        let aspect = recipe.crop?.aspect ?? (configuration.aspectPresets.contains(.original) ? .original : .free)
        cropOverlay.aspect = aspect
        highlightAspectButton(for: aspect)
        view.addSubview(cropOverlay)

        renderCropPreview()
        if let existing = recipe.crop {
            cropOverlay.setCrop(normalized: existing.rect)
        } else {
            cropOverlay.reset()
        }
        showEditsOverCropPreview()

        topBar.isHidden = true
        setMainToolbarHidden(true)
        cropTopBar.isHidden = false
        cropToolsBackground.isHidden = false
        rotationDial.isHidden = false
        cropAspectBarBackground.isHidden = false

        // The crop overlay (dimming + grid) was just added on top of everything;
        // lift the chrome back above it so its dimming mask never covers the
        // presets bar or the dial.
        for chrome in [cropTopBar, cropToolsBackground, rotationDial, cropAspectBarBackground] {
            view.bringSubviewToFront(chrome)
        }
    }

    /// Total crop rotation, preset + straighten, in degrees.
    private var cropTotalDegrees: Double { cropRotationBase + cropStraighten }

    /// The un-rotated source size the crop geometry is measured against: the
    /// normalized photo for photos, the oriented frame for videos.
    private var cropSourceSize: CGSize {
        if case .video = item { return videoOrientedSize }
        return sourceImage?.size ?? .zero
    }

    /// Re-renders the preview with the current crop geometry and repositions the
    /// crop overlay + its clean (inscribed) allowed area.
    private func renderCropPreview() {
        if case .video = item {
            // The player shows the whole rotated frame; the overlay picks the region.
            view.layoutIfNeeded()
            layoutVideoPreview()
            positionCropOverlay()
            return
        }
        guard let source = previewSource else { return }
        var geo = EditRecipe()
        geo.rotation = RotationState(degrees: cropTotalDegrees)
        geo.flip = cropFlip
        geo.filter = recipe.filter          // the look stays; only geometry is being edited
        if let rendered = renderer.renderGeometry(cgImage: source, recipe: geo) {
            imageView.image = UIImage(cgImage: rendered)
        }
        view.layoutIfNeeded()
        positionCropOverlay()
    }

    private func positionCropOverlay() {
        cropOverlay.frame = imageView.frame
        let bbox = displayedImageFrame()
        cropOverlay.imageFrame = bbox
        let source = cropSourceSize
        let srcW = Double(source.width > 0 ? source.width : 1)
        let srcH = Double(source.height > 0 ? source.height : 1)
        let frac = CropGeometry.inscribedFraction(width: srcW, height: srcH,
                                                  angle: cropTotalDegrees * .pi / 180)
        let aw = bbox.width * CGFloat(frac.width)
        let ah = bbox.height * CGFloat(frac.height)
        cropOverlay.allowedRect = CGRect(x: bbox.midX - aw / 2, y: bbox.midY - ah / 2, width: aw, height: ah)
        syncOverlayCanvas()
    }

    /// The user started changing the crop: fade the edits out while the frame
    /// moves under them. A tap-sized change (rotate, flip, an aspect preset)
    /// hides them at once, since the frame jumps straight to its new place.
    private func cropAdjustmentBegan(instant: Bool = false) {
        guard mode == .crop, cropShowsEdits else { return }
        cropShowsEdits = false
        overlayContainer.layer.removeAllAnimations()
        UIView.animate(withDuration: instant ? 0 : 0.15) { [weak self] in self?.overlayContainer.alpha = 0 }
    }

    /// The change is done: bring the edits back, still on the same spot of the
    /// media — turned or mirrored with it if it was, and wherever the crop frame
    /// now happens to be.
    private func cropAdjustmentEnded() {
        guard mode == .crop, !cropShowsEdits else { return }
        cropShowsEdits = true
        showEditsOverCropPreview()
        UIView.animate(withDuration: 0.25) { [weak self] in self?.overlayContainer.alpha = 1 }
    }

    /// Lays the edits over the crop tool's preview — the whole frame under the
    /// working rotation and flip — by carrying them from the recipe's geometry.
    private func showEditsOverCropPreview() {
        var whole = recipe
        whole.rotation = RotationState(degrees: cropTotalDegrees)
        whole.flip = cropFlip
        whole.crop = nil
        let shown = carryingEdits(into: whole, from: recipe)
        syncOverlayCanvas()
        overlayContainer.reload(overlays: shown.overlays, images: overlayImages)
        showDrawing(shown.drawing)
    }

    /// Wraps a one-tap change to the crop — the frame jumps, the edits follow.
    private func adjustCrop(_ change: () -> Void) {
        cropAdjustmentBegan(instant: true)
        change()
        cropAdjustmentEnded()
    }

    @objc private func cropFlipHTapped() {
        adjustCrop {
            cropFlip.horizontal.toggle()
            renderCropPreview()
        }
    }

    @objc private func cropFlipVTapped() {
        adjustCrop {
            cropFlip.vertical.toggle()
            renderCropPreview()
        }
    }

    @objc private func cropRotateTapped() {
        adjustCrop {
            cropRotationBase += 90            // rotate 90° clockwise
            renderCropPreview()
            cropOverlay.reset()
        }
    }

    @objc private func applyCropTapped() {
        var next = recipe
        // Four quarter turns are no turn at all, not a 360° edit.
        next.rotation = RotationState(degrees: cropTotalDegrees.truncatingRemainder(dividingBy: 360))
        next.flip = cropFlip
        if cropOverlay.isEffectivelyFull {
            next.crop = nil
        } else {
            let rect = cropOverlay.normalizedCropRect()
            // Opening crop and applying straight away round-trips the rect
            // through screen points; keep the recipe's own rather than record
            // floating-point noise as an edit (and move every sticker for it).
            if let current = recipe.crop, current.aspect == cropOverlay.aspect,
               current.rect.isClose(to: rect) {
                next.crop = current
            } else {
                next.crop = CropState(rect: rect, aspect: cropOverlay.aspect)
            }
        }
        let changed = next.rendersDifferently(from: recipe)
        // `applyGeometry` lays the edits out for the new recipe itself.
        exitCropMode(restoringEdits: false)
        applyGeometry(next)
        // An unchanged recipe doesn't re-render, and the preview still shows
        // the whole uncropped frame from crop mode.
        if !changed { renderPreview() }
    }

    @objc private func cancelCropTapped() {
        exitCropMode()
        renderPreview()
    }

    @objc private func resetCropTapped() {
        adjustCrop {
            cropStraighten = 0
            rotationDial.setDegrees(0)
            renderCropPreview()
            cropOverlay.reset()
        }
    }

    @objc private func aspectTapped(_ sender: UIButton) {
        guard let match = aspectButtons.first(where: { $0.button === sender }) else { return }
        adjustCrop { cropOverlay.aspect = match.preset }
        highlightAspectButton(for: match.preset)
    }

    private func highlightAspectButton(for preset: AspectPreset) {
        for (p, button) in aspectButtons {
            let selected = label(for: p) == label(for: preset)
            let tint: UIColor = selected ? .systemYellow : .white
            // Configuration-backed (glass) buttons ignore setTitleColor.
            if button.configuration != nil {
                button.configuration?.baseForegroundColor = tint
            } else {
                button.setTitleColor(tint, for: .normal)
            }
        }
    }

    /// Leaves crop mode. `restoringEdits` puts the recipe's own sticker and
    /// drawing layout back; Apply skips it, since it lays them out anew.
    private func exitCropMode(restoringEdits: Bool = true) {
        mode = .normal
        cropOverlay.removeFromSuperview()
        if case .video = item {
            setPlaybackChromeHidden(false)
            // Back to the recipe's own geometry, crop included.
            layoutVideoPreview()
        }
        cropShowsEdits = false
        overlayContainer.layer.removeAllAnimations()
        overlayContainer.alpha = 1
        overlayContainer.isUserInteractionEnabled = true
        overlayContainer.clipsToCanvas = true
        // Back to the recipe's own layout of the edits.
        syncOverlayCanvas()
        if restoringEdits {
            reloadOverlaysFromRecipe()
            updateDrawingLayer()
        }
        topBar.isHidden = false
        setMainToolbarHidden(false)
        cropTopBar.isHidden = true
        cropToolsBackground.isHidden = true
        rotationDial.isHidden = true
        cropAspectBarBackground.isHidden = true
    }

    // MARK: - Video

    /// Whether the session offers the filmstrip for its videos.
    private var offersTrim: Bool { configuration.tools(for: .video).contains(.trim) }

    // The video controls' layout, shared with the page turn, which has to
    // know where a video will sit before its controls exist.
    private static let filmstripHeight: CGFloat = 60
    private static let filmstripBottomGap: CGFloat = 12
    private static let timeLabelHeight: CGFloat = 16
    private static let timeLabelBottomGap: CGFloat = 8
    /// The space between the video's box and the controls under it.
    private static let videoControlsGap: CGFloat = 12
    /// The transport, filmstrip and readout have been added to the view.
    private var hasVideoChrome = false

    /// Adds the transport, filmstrip and time readout — once: a session reuses
    /// them for every video it shows, and hides them for everything else.
    private func installVideoChromeIfNeeded() {
        guard !hasVideoChrome else { return }
        hasVideoChrome = true

        // The filmstrip is a configurable tool, not fixed furniture: a host that
        // leaves `.trim` out gets playback and the other tools without it.
        if offersTrim {
            trimScrubber.delegate = self
            trimScrubber.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(trimScrubber)
            NSLayoutConstraint.activate([
                trimScrubber.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                trimScrubber.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                trimScrubber.bottomAnchor.constraint(equalTo: bottomChromeTopAnchor, constant: -Self.filmstripBottomGap),
                trimScrubber.heightAnchor.constraint(equalToConstant: Self.filmstripHeight),
            ])
        }

        // The transport floats over the preview, above the sticker layer.
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        view.addSubview(playPauseButton)
        // Anchored to the preview area, then offset onto the video's own centre by
        // `alignTransport(to:)` — the video is fitted into a box that stops above
        // the controls under it, so the two centres differ.
        let centerX = playPauseButton.centerXAnchor.constraint(equalTo: imageView.centerXAnchor)
        let centerY = playPauseButton.centerYAnchor.constraint(equalTo: imageView.centerYAnchor)
        playPauseCenterX = centerX
        playPauseCenterY = centerY
        NSLayoutConstraint.activate([
            centerX, centerY,
            playPauseButton.widthAnchor.constraint(equalToConstant: PlayPauseButton.diameter),
            playPauseButton.heightAnchor.constraint(equalToConstant: PlayPauseButton.diameter),
        ])

        // Elapsed / total, just above the filmstrip — or the tool row when trim is
        // off. A fixed height keeps the video from shifting when the text first
        // appears.
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timeLabel)
        NSLayoutConstraint.activate([
            timeLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            timeLabel.bottomAnchor.constraint(equalTo: offersTrim ? trimScrubber.topAnchor : bottomChromeTopAnchor,
                                              constant: -Self.timeLabelBottomGap),
            timeLabel.heightAnchor.constraint(equalToConstant: Self.timeLabelHeight),
        ])

        displayLinkProxy.onTick = { [weak self] in
            guard let self else { return false }   // editor gone — stop the link
            playbackTick()
            return true
        }
        liftChromeAbovePreview()
    }

    /// Puts the video at `url` on the canvas: a player clipped to the recipe's
    /// crop, a display link for the playhead, and the asset's duration, tracks
    /// and size loaded in the background.
    private func loadVideo(url: URL) {
        installVideoChromeIfNeeded()
        let asset = AVURLAsset(url: url)
        videoAsset = asset

        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .none
        let layer = AVPlayerLayer(player: player)
        // The layer is sized to the video's own aspect by `layoutVideoPreview`,
        // and the container crops it, so the layer itself fills exactly.
        layer.videoGravity = .resize
        videoContainer.clipsToBounds = true
        videoContainer.layer.addSublayer(layer)
        imageView.addSubview(videoContainer)
        self.player = player
        self.playerLayer = layer
        setPlaybackChromeHidden(isToolOpen)

        let link = CADisplayLink(target: displayLinkProxy,
                                 selector: #selector(DisplayLinkProxy.tick(_:)))
        // The tick only nudges a playhead and watches for the player stopping;
        // it has no business running at a ProMotion 120 Hz.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 15)
        link.isPaused = true                 // nothing to track until playback starts
        link.add(to: .main, forMode: .common)
        displayLink = link

        videoLoadTask = Task { @MainActor [weak self] in
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            guard let self, !Task.isCancelled, videoAsset === asset else { return }
            videoDuration = duration
            videoTrimStart = recipe.trim?.start ?? 0
            videoTrimEnd = recipe.trim?.end ?? duration
            timeLabel.configure(duration: duration)
            timeLabel.isHidden = isToolOpen
            if showsTrimScrubber {
                trimScrubber.configure(asset: asset, duration: duration)
                if let trim = recipe.trim { trimScrubber.setTrim(start: trim.start, end: trim.end) }
            }
            let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
            let size = await orientedSize(of: asset)
            guard !Task.isCancelled, videoAsset === asset else { return }
            hasAudioTrack = hasAudio
            videoOrientedSize = size
            syncVideoState()
            // Park on the first frame — unless the user already hit play while
            // the asset was still loading.
            if !isVideoPlaying { park(at: videoTrimStart) } else { refreshTimeReadout() }
        }
    }

    /// Takes the selected video off the canvas: stops and releases its player,
    /// invalidates its display link, and hides the controls until the next one.
    private func unloadVideo() {
        videoLoadTask?.cancel()
        videoLoadTask = nil
        displayLink?.invalidate()
        displayLink = nil
        player?.pause()
        if playPauseButton.isPlaying { playPauseButton.setPlaying(false, animated: false) }
        playerLayer?.removeFromSuperlayer()
        videoContainer.removeFromSuperview()
        player = nil
        playerLayer = nil
        videoAsset = nil
        videoDuration = nil
        videoOrientedSize = .zero
        hasAudioTrack = false
        playbackPosition = 0
        videoTrimStart = 0
        videoTrimEnd = .greatestFiniteMagnitude
        playPauseButton.isHidden = true
        trimScrubber.isHidden = true
        timeLabel.isHidden = true
    }

    /// Mirrors the recipe onto the live preview: mute state, the audio toggle,
    /// and the preview geometry.
    /// Parks playback and tucks the transport, filmstrip and time readout away
    /// while a tool works on a still frame (crop, drawing) — or brings them back.
    private func setPlaybackChromeHidden(_ hidden: Bool) {
        if hidden {
            player?.pause()
            syncTransport(animated: false)
        }
        playPauseButton.isHidden = hidden
        trimScrubber.isHidden = hidden || !showsTrimScrubber
        timeLabel.isHidden = hidden || videoDuration == nil
    }

    private func syncVideoState() {
        player?.isMuted = recipe.removeAudio
        updateAudioButton()
        // Undo/redo can change the trim without the filmstrip being touched, so
        // the handles, loop range and readout have to follow the recipe.
        syncTrimFromRecipe()
        layoutVideoPreview()
    }

    private func syncTrimFromRecipe() {
        guard let videoDuration else { return }          // asset not loaded yet
        let start = recipe.trim?.start ?? 0
        let end = recipe.trim?.end ?? videoDuration
        // A committed drag round-trips through `TrimRange(start:duration:)`, so
        // compare with a tolerance instead of re-seeking on floating-point noise.
        guard abs(start - videoTrimStart) > 0.001 || abs(end - videoTrimEnd) > 0.001 else { return }
        videoTrimStart = start
        videoTrimEnd = end
        if showsTrimScrubber { trimScrubber.setTrim(start: start, end: end) }
        park(at: min(max(playbackPosition, start), end))
    }

    /// Moves the preview, playhead and readout to `seconds` together.
    private func park(at seconds: Double) {
        playbackPosition = seconds
        seek(to: seconds)
        if showsTrimScrubber { trimScrubber.updatePlayhead(time: seconds) }
        refreshTimeReadout()
    }

    /// Elapsed position on the source timeline / where the kept range ends.
    private func refreshTimeReadout() {
        guard videoTrimEnd < .greatestFiniteMagnitude else { return }   // not loaded yet
        timeLabel.show(current: playbackPosition, total: videoTrimEnd)
    }

    /// The video's display size once the track's own `preferredTransform` is
    /// applied — the space the recipe's geometry is expressed in.
    private func orientedSize(of asset: AVAsset) async -> CGSize {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let preferred = try? await track.load(.preferredTransform) else { return .zero }
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    // MARK: - Playback transport

    @objc private func playPauseTapped() { togglePlayback() }

    /// Whether the player is playing, or actively trying to. The player is the
    /// single source of truth here — it also stops on its own, and the asset
    /// loads asynchronously, so a separate flag drifts out of step with it.
    var isVideoPlaying: Bool {
        guard let player else { return false }        // no video on the canvas
        return player.timeControlStatus != .paused
    }

    /// Whether the frame callback is currently idle. Exposed for tests, which
    /// assert the editor isn't waking every frame for a parked video.
    var displayLinkIsPaused: Bool? { displayLink?.isPaused }

    private func togglePlayback() {
        guard let player else { return }
        if isVideoPlaying { player.pause() } else { player.play() }
        syncTransport(animated: true)
    }

    /// Animates the control to match the player: out of the way while playing,
    /// back in when paused.
    func syncTransport(animated: Bool) {
        let playing = isVideoPlaying
        // Parked video needs no frame callbacks at all. Kept outside the guard
        // below so the link still stops when the player ends on its own.
        displayLink?.isPaused = !playing
        guard playPauseButton.isPlaying != playing else { return }
        playPauseButton.setPlaying(playing, animated: animated)
    }

    // MARK: - Audio

    @objc private func toggleAudioTapped() {
        var next = recipe
        next.removeAudio.toggle()
        apply(next)
    }

    /// Mirrors `recipe.removeAudio` onto the toggle, and keeps it out of the
    /// toolbar entirely for a source that has no audio to remove.
    private func updateAudioButton() {
        // Hide whatever sits in the row: the circular backing, or the button
        // itself. The button inside a backing must stay visible — a session
        // may have hidden it before the row was rebuilt around a new backing.
        if let host = audioButtonHost, host !== audioButton {
            host.isHidden = !hasAudioTrack
            audioButton.isHidden = false
        } else {
            audioButton.isHidden = !hasAudioTrack
        }
        let muted = recipe.removeAudio
        // The "on" state gets its own glyph; a host overriding the symbol for
        // `.toggleAudio` keeps control of the "off" one.
        if muted {
            appearance.styleSymbolButton(audioButton, symbol: "speaker.slash.fill")
        } else {
            appearance.styleToolButton(audioButton, action: .toggleAudio)
        }
        audioButton.tintColor = muted ? appearance.accent : appearance.tint
        audioButton.accessibilityLabel = muted ? L10n.restoreAudio : L10n.removeAudio
        notifyToolbarStateChanged()
    }

    /// The topmost control stacked under a video — the time readout, else the
    /// filmstrip — or `nil` for a photo.
    private var videoControlsTop: UIView? {
        guard case .video = item else { return nil }
        if timeLabel.superview != nil { return timeLabel }
        if showsTrimScrubber, trimScrubber.superview != nil { return trimScrubber }
        return nil
    }

    /// Keeps the play/pause button centred on the video frame — `display`, in the
    /// image view's coordinates — rather than on the taller preview area.
    private func alignTransport(to display: CGRect) {
        guard let playPauseCenterX, let playPauseCenterY else { return }
        let dx = display.midX - imageView.bounds.midX
        let dy = display.midY - imageView.bounds.midY
        // Only write on a real change: this runs during layout, and every write
        // schedules another pass.
        if abs(playPauseCenterX.constant - dx) > 0.5 { playPauseCenterX.constant = dx }
        if abs(playPauseCenterY.constant - dy) > 0.5 { playPauseCenterY.constant = dy }
    }

    /// The box the preview is fitted into. In normal mode it stops above the
    /// controls under the video — the time readout and filmstrip — so a tall crop
    /// doesn't run underneath them; crop mode hides those and gets the whole area.
    private var videoPreviewBounds: CGRect {
        let box = imageView.bounds
        guard mode != .crop, let controls = videoControlsTop, controls.frame.height > 0 else { return box }
        let limit = imageView.convert(controls.frame, from: view).minY - Self.videoControlsGap
        guard limit > box.minY, limit < box.maxY else { return box }
        return CGRect(x: box.minX, y: box.minY, width: box.width, height: limit - box.minY)
    }

    /// Lays the player out so the preview shows what the export will render:
    /// rotation and flip as a layer transform, crop as clipping by `videoContainer`.
    ///
    /// Deliberately does *not* go through `AVPlayerItem.videoComposition`. Routing
    /// preview playback through a compositor renders a black frame in the iOS
    /// Simulator — Apple's own `AVMutableVideoComposition(propertiesOf:)` does it
    /// too — and a layer transform is cheaper than a per-frame compositor besides.
    /// The export still applies the same geometry through `VideoComposer`, and the
    /// math here mirrors `geometryTransform` so the two agree.
    private func layoutVideoPreview() {
        guard let playerLayer, videoOrientedSize.width > 0, videoOrientedSize.height > 0 else { return }
        let w = videoOrientedSize.width, h = videoOrientedSize.height
        // Crop mode previews the working rotation over the *whole* frame — the
        // overlay is what picks the region — so it drives the geometry there.
        let inCrop = mode == .crop
        let degrees = inCrop ? cropTotalDegrees : recipe.rotation.degrees
        let radians = CGFloat(degrees * .pi / 180)

        // Bounding box of the oriented frame once rotated — the space the crop
        // rect is expressed in, exactly as in the composer.
        let rotated = CGSize(width: abs(w * cos(radians)) + abs(h * sin(radians)),
                             height: abs(w * sin(radians)) + abs(h * cos(radians)))
        let crop = inCrop ? .full : (recipe.crop?.rect ?? .full)
        let output = CGSize(width: rotated.width * CGFloat(crop.size.width),
                            height: rotated.height * CGFloat(crop.size.height))
        guard output.width > 0, output.height > 0 else { return }

        // Fit the rendered output into the preview box; the container clips to it.
        let display = AVMakeRect(aspectRatio: output, insideRect: videoPreviewBounds)
        let scale = display.width / output.width

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // geometry tracks the recipe, it isn't an animation
        videoContainer.frame = display
        playerLayer.bounds = CGRect(origin: .zero, size: CGSize(width: w * scale, height: h * scale))
        // Centre the rotated frame in the container, offset by the crop origin.
        playerLayer.position = CGPoint(
            x: (rotated.width / 2 - CGFloat(crop.origin.x) * rotated.width) * scale,
            y: (rotated.height / 2 - CGFloat(crop.origin.y) * rotated.height) * scale)
        let flipState = inCrop ? cropFlip : recipe.flip
        let flip = CGAffineTransform(scaleX: flipState.horizontal ? -1 : 1,
                                     y: flipState.vertical ? -1 : 1)
        // Flip then rotate, matching the recipe's order of operations.
        playerLayer.setAffineTransform(flip.concatenating(CGAffineTransform(rotationAngle: radians)))
        CATransaction.commit()

        alignTransport(to: display)
        syncOverlayCanvas()
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Drives looping within the trim range and the scrubber playhead.
    @objc private func playbackTick() {
        guard let player, let current = player.currentItem else { return }
        // The player also stops without us — an interruption, or running off the
        // end of the asset — so mirror it rather than assuming we did it.
        syncTransport(animated: true)
        let t = current.currentTime().seconds
        if t.isFinite {
            if t >= videoTrimEnd - 0.02 || t < videoTrimStart - 0.05 {
                park(at: videoTrimStart)             // loop back to the in-point
            } else {
                playbackPosition = t
                if showsTrimScrubber { trimScrubber.updatePlayhead(time: t) }
                refreshTimeReadout()
            }
        }
    }

    private func teardownVideo() {
        displayLink?.invalidate()
        displayLink = nil
        player?.pause()
        syncTransport(animated: false)
        exportTask?.cancel()
    }

    // MARK: - Draw mode

    @objc private func drawTapped() { enterDrawingMode() }

    /// Enters PencilKit drawing mode over the geometry-applied image, or over the
    /// paused video frame.
    public func enterDrawingMode() {
        guard mode == .normal else { return }
        resetZoom()
        switch item {
        case .photo:
            guard previewSource != nil else { return }
            mode = .draw
        case .video:
            // No frame on screen yet means no canvas size to author against.
            guard !videoContainer.frame.isEmpty else { return }
            mode = .draw
            setPlaybackChromeHidden(true)
        }

        topBar.isHidden = true
        setMainToolbarHidden(true)
        drawTopBar.isHidden = false

        // The canvas takes the drawing's place among the stickers — over the
        // picture ones, under the text — so every other edit stays in view.
        view.layoutIfNeeded()
        overlayContainer.beginDrawing(with: canvasView)
        loadDrawingIntoCanvas()
        drawingAtEntry = canvasView.drawing
        view.bringSubviewToFront(drawTopBar)

        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()
    }

    /// The strokes as the pencil tool opened, to tell an edit from a look.
    private var drawingAtEntry = PKDrawing()

    /// Loads the recipe's drawing into the canvas, scaling it from its authoring
    /// canvas to the current canvas size if they differ.
    private func loadDrawingIntoCanvas() {
        guard let drawing = recipe.drawing,
              let pkDrawing = try? PKDrawing(data: drawing.data) else {
            canvasView.drawing = PKDrawing()
            return
        }
        let currentWidth = canvasView.bounds.width
        if drawing.canvasWidth > 0, abs(currentWidth - CGFloat(drawing.canvasWidth)) > 0.5 {
            let scale = currentWidth / CGFloat(drawing.canvasWidth)
            canvasView.drawing = pkDrawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            canvasView.drawing = pkDrawing
        }
    }

    @objc private func applyDrawTapped() {
        let pkDrawing = canvasView.drawing
        let size = canvasView.bounds.size
        var next = recipe
        if pkDrawing.bounds.isNull || pkDrawing.strokes.isEmpty {
            next.drawing = nil
        } else if pkDrawing.dataRepresentation() == drawingAtEntry.dataRepresentation() {
            // Opened and closed without a stroke: leave it where it stacks.
        } else {
            // Fresh strokes go over every sticker already on the media; anything
            // added afterwards lands on top of them.
            next.drawing = DrawingData(
                data: pkDrawing.dataRepresentation(),
                canvasWidth: Double(size.width),
                canvasHeight: Double(size.height),
                zIndex: recipe.nextZIndex
            )
        }
        exitDrawingMode()
        apply(next)
    }

    @objc private func cancelDrawTapped() {
        exitDrawingMode()
        renderPreview()
    }

    private func exitDrawingMode() {
        toolPicker.setVisible(false, forFirstResponder: canvasView)
        toolPicker.removeObserver(canvasView)
        canvasView.resignFirstResponder()
        overlayContainer.endDrawing()
        mode = .normal
        if case .video = item {
            setPlaybackChromeHidden(false)
        }
        topBar.isHidden = false
        setMainToolbarHidden(false)
        drawTopBar.isHidden = true
    }

    // MARK: - Filter mode

    @objc private func filterTapped() { enterFilterMode() }

    /// Enters the filters carousel with a live preview.
    public func enterFilterMode() {
        guard sourceCGImage != nil, mode == .normal else { return }
        resetZoom()
        mode = .filter
        filterWorkingFilter = recipe.filter

        filterBar.configure(thumbnails: makeFilterThumbnails(), selected: filterWorkingFilter)
        renderFilterPreview()

        topBar.isHidden = true
        setMainToolbarHidden(true)
        filterTopBar.isHidden = false
        filterBarBackground.isHidden = false
    }

    /// Preview with the working filter (geometry + filter; the drawing and
    /// overlays stay as live layers on top).
    private func renderFilterPreview() {
        guard let source = previewSource else { return }
        var r = recipe
        r.filter = filterWorkingFilter
        guard let rendered = renderer.renderGeometry(cgImage: source, recipe: r) else { return }
        imageView.image = UIImage(cgImage: rendered)
    }

    /// Renders a small thumbnail of the geometry-applied image for each filter.
    private func makeFilterThumbnails() -> [(filter: PhotoFilter, image: UIImage)] {
        guard let source = previewSource else { return [] }
        var geometryOnly = recipe
        geometryOnly.filter = .none
        geometryOnly.drawing = nil
        geometryOnly.overlays = []
        guard let baseCG = renderer.renderGeometry(cgImage: source, recipe: geometryOnly),
              let smallCG = downscaled(cgImage: baseCG, maxDimension: 160) else { return [] }
        return PhotoFilter.allCases.map { filter in
            let out = renderer.renderGeometry(cgImage: smallCG, recipe: EditRecipe(filter: filter)) ?? smallCG
            return (filter, UIImage(cgImage: out))
        }
    }

    private func downscaled(cgImage: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let scale = min(1, maxDimension / max(w, h))
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }

    @objc private func applyFilterTapped() {
        var next = recipe
        next.filter = filterWorkingFilter
        exitFilterMode()
        apply(next)
    }

    @objc private func cancelFilterTapped() {
        exitFilterMode()
        renderPreview()
    }

    private func exitFilterMode() {
        mode = .normal
        topBar.isHidden = false
        setMainToolbarHidden(false)
        filterTopBar.isHidden = true
        filterBarBackground.isHidden = true
    }

    // MARK: - Overlays (stickers)

    /// Stickers need media on the canvas: a decoded photo or a video.
    private var canAddOverlays: Bool {
        !isPassthrough && (item.kind == .video || sourceCGImage != nil)
    }

    private func addText() {
        guard canAddOverlays else { return }
        presentTextEditor(seed: TextStyle(string: "")) { [weak self] style in
            self?.insertOverlay(content: .text(style), image: nil)
        }
    }

    private func addPhoto() {
        guard canAddOverlays else { return }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentTextEditor(seed: TextStyle, completion: @escaping (TextStyle) -> Void) {
        // The text editor brings up the keyboard, which would lift the caption
        // bar into view behind its translucent backdrop.
        bottomAccessory?.isHidden = true
        let editor = TextEditorViewController(style: seed, appearance: appearance) { [weak self] style in
            if let self, mode == .normal { bottomAccessory?.isHidden = false }
            guard let style else { return }
            completion(style)
        }
        present(editor, animated: true)
    }

    /// Appends a new overlay centered on the canvas, on top of the stack.
    private func insertOverlay(content: OverlayContent, image: UIImage?) {
        // Above everything already placed, the drawing included.
        let nextZ = recipe.nextZIndex
        if case let .image(ref) = content, let image { overlayImages[ref.id] = image }
        let overlay = Overlay(content: content, transform: .identity, zIndex: nextZ)
        var next = recipe
        next.overlays.append(overlay)
        apply(next)
        overlayContainer.reload(overlays: recipe.overlays, images: overlayImages)
    }

    /// Downscales an image to a sensible sticker resolution to bound memory and
    /// the size of a persisted recipe.
    /// Off-main variant of `downscaled(_:maxDimension:)`.
    ///
    /// `UIGraphicsImageRenderer` renders offscreen and is safe away from the
    /// main thread, but `UIGraphicsImageRendererFormat.preferred()` consults the
    /// current trait collection, so the format is built explicitly here.
    nonisolated static func downscaledOffscreen(_ image: UIImage,
                                                maxDimension: CGFloat = 1024) -> UIImage {
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func downscaled(_ image: UIImage, maxDimension: CGFloat = 1024) -> UIImage {
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Tool actions

    @objc private func rotateTapped() {
        var next = recipe
        next.rotation.rotateClockwise90()
        applyGeometry(next)
    }

    @objc private func flipHTapped() {
        var next = recipe
        next.flip.horizontal.toggle()
        applyGeometry(next)
    }

    @objc private func flipVTapped() {
        var next = recipe
        next.flip.vertical.toggle()
        applyGeometry(next)
    }

    @objc private func addTextTapped() { addText() }
    @objc private func addPhotoTapped() { addPhoto() }
    @objc private func undoTapped() { undo() }
    @objc private func redoTapped() { redo() }
    @objc private func cancelTapped() { cancel() }
    @objc private func doneTapped() { finish() }

    // MARK: - Edit state

    /// Records a recipe edit onto the history stack.
    public func apply(_ newRecipe: EditRecipe) {
        history.push(newRecipe)
        recipe = history.current
        updateHistoryButtons()
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    // MARK: - Actions

    /// The actions the tool row offers, after filtering by `configuration` and
    /// the media kind. This is what a custom toolbar should render.
    ///
    /// Undo and redo are deliberately absent: they live in the editor's top bar,
    /// outside the tool row, and stay there even when a host supplies its own
    /// toolbar. A custom row can still show them — `perform(.undo)` and
    /// `isEnabled(.undo)` work regardless.
    ///
    /// `addText` and `addPhoto` are listed separately here; the built-in bar
    /// collapses them into one "+" menu, but a custom row is free to surface
    /// them however it likes.
    public var toolbarActions: [EditorAction] {
        guard !isPassthrough else { return [] }
        return actions(for: item.kind)
    }

    /// The tool-row actions `configuration` offers for `kind`.
    private func actions(for kind: MediaKind) -> [EditorAction] {
        let tools = configuration.tools(for: kind)
        var actions: [EditorAction] = []
        if tools.contains(.crop) {
            actions.append(.crop)
        } else {
            // Rotate/flip live inside the crop tool when it's available.
            if tools.contains(.rotate) { actions.append(.rotate) }
            if tools.contains(.flip) { actions += [.flipHorizontal, .flipVertical] }
        }
        if tools.contains(.filters) { actions.append(.filters) }
        if tools.contains(.drawing) { actions.append(.drawing) }
        if tools.contains(.overlays) { actions += [.addText, .addPhoto] }
        if tools.contains(.audio) { actions.append(.toggleAudio) }
        return actions
    }

    /// Runs `action` exactly as the built-in chrome would. Safe to call for an
    /// action the configuration doesn't offer — it simply does nothing when the
    /// underlying tool is unavailable.
    public func perform(_ action: EditorAction) {
        // Passthrough content has nothing to edit.
        if isPassthrough, ![.undo, .redo, .cancel, .done].contains(action) { return }
        switch action {
        case .crop:           enterCropMode()
        case .rotate:         rotateTapped()
        case .flipHorizontal: flipHTapped()
        case .flipVertical:   flipVTapped()
        case .filters:        enterFilterMode()
        case .drawing:        enterDrawingMode()
        case .addText:        addText()
        case .addPhoto:       addPhoto()
        case .toggleAudio:    toggleAudioTapped()
        case .undo:           undo()
        case .redo:           redo()
        case .cancel:         cancel()
        case .done:           finish()
        }
    }

    /// Whether `action` can be run right now — undo/redo depend on history, the
    /// audio toggle on the source actually having a track.
    public func isEnabled(_ action: EditorAction) -> Bool {
        if isPassthrough, ![.cancel, .done].contains(action) { return false }
        switch action {
        case .undo:        return history.canUndo
        case .redo:        return history.canRedo
        case .toggleAudio: return hasAudioTrack
        case .crop:        return cropSourceSize.width > 0 && cropSourceSize.height > 0
        case .cancel, .done: return true
        default:           return toolbarActions.contains(action)
        }
    }

    /// Whether `action` is currently *on*: its tool is open, or its toggle is
    /// engaged. Use it to draw a selected state in a custom toolbar.
    public func isActive(_ action: EditorAction) -> Bool {
        switch action {
        case .toggleAudio: return recipe.removeAudio
        case .crop:        return mode == .crop
        case .filters:     return mode == .filter
        case .drawing:     return mode == .draw
        default:           return false
        }
    }

    /// Whether a tool — crop, drawing or filters — has the screen.
    public var isToolActive: Bool { mode != .normal }

    // Internal so tests can check what the session holds in memory.
    /// The selected photo is decoded at full size.
    var hasFullSizeDecode: Bool { sourceCGImage != nil }
    /// A video player is loaded.
    var hasVideoPlayer: Bool { player != nil }
    /// The thumbnail strip, for a session.
    var strip: ThumbnailStripView? { isSingleItemEditor ? nil : thumbnailStrip }
    /// An export is running.
    var isExporting: Bool { exportTask != nil }

    public func undo() {
        if let state = history.undo() {
            recipe = state
            reloadOverlaysFromRecipe()
            updateHistoryButtons()
        }
    }

    public func redo() {
        if let state = history.redo() {
            recipe = state
            reloadOverlaysFromRecipe()
            updateHistoryButtons()
        }
    }

    /// Rebuilds the sticker views to match `recipe.overlays` — needed after
    /// undo/redo, since the sticker views are live and don't otherwise track the
    /// recipe. Decodes any image overlays not already cached.
    private func reloadOverlaysFromRecipe() {
        for overlay in recipe.overlays {
            if case let .image(ref) = overlay.content, overlayImages[ref.id] == nil,
               let data = ref.data, let image = UIImage(data: data) {
                overlayImages[ref.id] = image
            }
        }
        overlayContainer.reload(overlays: recipe.overlays, images: overlayImages)
    }

    // MARK: - Session

    /// Points the editor at the selected item's media: decodes a photo held in
    /// memory, notes a video's URL, or marks passthrough content. The views
    /// follow in `loadSelectedMediaViews()` once there is a view to put them in.
    private func prepareSelectedMedia() {
        let selected = items[selectedIndex]
        isPassthrough = false
        sourceImage = nil
        sourceCGImage = nil
        previewSourceCGImage = nil
        previewSourceCap = 0
        switch selected.source {
        case let .photo(image):
            let normalized = image.normalizedUp()
            sourceImage = normalized
            sourceCGImage = normalized.cgImage
            item = .photo(image)
        case .photoFile:
            // Decoded off the main actor when shown; nothing to edit until then.
            item = .photo(UIImage())
        case let .video(url):
            item = .video(url)
        case .passthrough:
            item = .photo(UIImage())
            isPassthrough = true
        }
        // Restore image-overlay content from a resumed recipe.
        for overlay in selected.recipe.overlays {
            if case let .image(ref) = overlay.content, overlayImages[ref.id] == nil,
               let data = ref.data, let image = UIImage(data: data) {
                overlayImages[ref.id] = image
            }
        }
    }

    /// Puts the selected media on the canvas.
    private func loadSelectedMediaViews() {
        switch items[selectedIndex].source {
        case .photo:
            break                                    // rendered by the layout pass
        case let .photoFile(url):
            loadPhotoFile(url: url)
        case let .video(url):
            loadVideo(url: url)
        case let .passthrough(_, preview):
            let content = preview()
            content.translatesAutoresizingMaskIntoConstraints = false
            // Like `imageView`, the content fills whatever the chrome leaves. A
            // hosting view reports its SwiftUI content's ideal size — a few
            // points for a document viewer — and at default priorities that
            // ties with the accessory, so Auto Layout could squash the canvas
            // and stretch the bar instead.
            for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
                content.setContentHuggingPriority(.init(1), for: axis)
                content.setContentCompressionResistancePriority(.init(1), for: axis)
            }
            passthroughHost.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: passthroughHost.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: passthroughHost.trailingAnchor),
                content.topAnchor.constraint(equalTo: passthroughHost.topAnchor),
                content.bottomAnchor.constraint(equalTo: passthroughHost.bottomAnchor),
            ])
            passthroughView = content
            passthroughHost.isHidden = false
            overlayContainer.isHidden = true
        }
    }

    /// Decodes a photo file at full size off the main actor. Until it lands,
    /// the strip's thumbnail stands in, scaled up, so the switch feels instant —
    /// it already shows the edits, so the live sticker layer waits for the
    /// real image.
    private func loadPhotoFile(url: URL) {
        let id = selectedItemID
        imageView.image = pagePreview(for: id)
        overlayContainer.isHidden = true
        photoLoadTask = Task { @MainActor [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                EditRenderer.decodeUpright(url: url, maxPixelSize: nil)
            }.value
            guard let self, !Task.isCancelled, selectedItemID == id, let decoded else { return }
            let image = UIImage(cgImage: decoded)
            sourceImage = image
            sourceCGImage = decoded
            item = .photo(image)
            previewSourceCap = 0
            overlayContainer.isHidden = false
            view.setNeedsLayout()
            view.layoutIfNeeded()
            refreshPreviewSourceIfNeeded()
            renderPreview()
            reloadOverlaysFromRecipe()
            notifyToolbarStateChanged()
        }
    }

    /// Takes the selected item's media off the canvas and lets go of its
    /// full-size decode.
    private func unloadSelectedMedia() {
        photoLoadTask?.cancel()
        photoLoadTask = nil
        if player != nil || videoAsset != nil { unloadVideo() }
        passthroughView?.removeFromSuperview()
        passthroughView = nil
        passthroughHost.isHidden = true
        overlayContainer.deselect()
        overlayContainer.isHidden = false
        imageView.image = nil
    }

    /// Whether the selected item's media is a photo, a video, or not editable.
    private var selectedKind: MediaKind? { isPassthrough ? nil : item.kind }

    /// Shows item `id` on the canvas. Its edits and undo history are as the
    /// user left them; whatever was selected keeps its own. An open tool is
    /// cancelled first.
    public func select(_ id: UUID) {
        guard id != selectedItemID, items.contains(where: { $0.id == id }) else { return }
        switchSelection(to: id)
        onSelectionChange?(id)
    }

    private func switchSelection(to id: UUID) {
        abandonPaging()
        resetZoom()
        switch mode {
        case .crop:   cancelCropTapped()
        case .draw:   cancelDrawTapped()
        case .filter: cancelFilterTapped()
        case .normal: break
        }
        histories[selectedItemID] = history
        if isViewLoaded { unloadSelectedMedia() }
        let previousKind = selectedKind

        selectedItemID = id
        let selected = items[selectedIndex]
        isLoadingSelection = true
        history = histories.removeValue(forKey: id)
            ?? EditHistory(initial: selected.recipe, limit: configuration.historyLimit)
        prepareSelectedMedia()
        recipe = history.current
        isLoadingSelection = false

        guard isViewLoaded else { return }
        if selectedKind != previousKind { rebuildToolRows() }
        loadSelectedMediaViews()
        reloadOverlaysFromRecipe()
        updateDrawingLayer()
        updateHistoryButtons()
        refreshMainChrome()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        renderPreview()
        updateStrip()
    }

    /// Removes item `id` from the session. Removing the selected item selects
    /// its neighbour; removing the last one ends the session with `.cancelled`.
    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items.count > 1 else {
            items.removeAll()
            histories.removeAll()
            onItemsChange?(items)
            endSession(.cancelled)
            return
        }
        let removingSelected = id == selectedItemID
        if removingSelected {
            switchSelection(to: items[index + 1 < items.count ? index + 1 : index - 1].id)
        }
        items.remove(at: index)
        histories[id] = nil
        thumbnailRecipes[id] = nil
        thumbnailQueue.removeAll { $0 == id }
        if isViewLoaded { updateStrip() }
        onItemsChange?(items)
        if removingSelected { onSelectionChange?(selectedItemID) }
    }

    /// Adds items to the session — at `index`, or at the end — and selects the
    /// first of them. Items already in the session are skipped.
    public func insert(_ newItems: [MediaEditorItem], at index: Int? = nil) {
        let fresh = newItems.filter { new in !items.contains { $0.id == new.id } }
        guard let first = fresh.first else { return }
        let position = min(max(0, index ?? items.count), items.count)
        items.insert(contentsOf: fresh, at: position)
        if isViewLoaded { updateStrip() }
        onItemsChange?(items)
        select(first.id)
    }

    /// Moves an item within the strip.
    private func moveItem(from source: Int, to destination: Int) {
        guard items.indices.contains(source), items.indices.contains(destination), source != destination else { return }
        let moved = items.remove(at: source)
        items.insert(moved, at: destination)
        if isViewLoaded { updateStrip() }
        onItemsChange?(items)
    }

    /// Rebuilds the tool rows for the selected media — photos and videos offer
    /// different tools.
    private func rebuildToolRows() {
        if customToolbar == nil {
            toolRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
            audioButtonHost = nil
            for button in toolbarButtons() { toolRow.addArrangedSubview(button) }
        }
        cropToolsBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for button in cropToolButtons() { cropToolsBar.addArrangedSubview(button) }
        notifyToolbarStateChanged()
    }

    /// The actions a custom row is offered in a session: those of every kind of
    /// media in it, so the row can serve whichever item is selected.
    private var sessionToolbarActions: [EditorAction] {
        let kinds = Set(items.compactMap(\.source.kind))
        let all = kinds.flatMap { actions(for: $0) }
        return EditorAction.allCases.filter { all.contains($0) }
    }

    // MARK: - Strip

    /// Adds the thumbnail strip, directly above the accessory, for a session.
    private func setupStrip() {
        guard !isSingleItemEditor else { return }
        thumbnailStrip.delegate = self
        thumbnailStrip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumbnailStrip)
        NSLayoutConstraint.activate([
            thumbnailStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnailStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailStrip.heightAnchor.constraint(equalToConstant: ThumbnailStripView.height(for: appearance)),
            // Rides on the accessory, so a strip left up with the keyboard
            // stays attached to the bar.
            thumbnailStrip.bottomAnchor.constraint(equalTo: bottomAccessory?.topAnchor ?? accessoryGuide.topAnchor),
        ])
        updateStrip()
    }

    /// Refreshes the strip's cells and whether it's on screen, and queues
    /// thumbnails it doesn't have yet.
    private func updateStrip() {
        guard !isSingleItemEditor, isViewLoaded, !items.isEmpty else { return }
        stripIsInUse = items.count >= 2 || onAddItems != nil
        thumbnailStrip.showsAddCell = onAddItems != nil
        thumbnailStrip.update(items: items, selectedID: selectedItemID)
        stripHeightConstraint?.constant = stripIsInUse ? ThumbnailStripView.height(for: appearance) : 0
        applyStripVisibility(animated: view.window != nil)
        for item in items where thumbnailRecipes[item.id] != item.recipe { enqueueThumbnail(item.id) }
        prefetchPagePreviews()
    }

    /// Fades the strip in or out: shown while it's in use, no tool is open, and
    /// — unless the appearance says otherwise — the keyboard is down. Its space
    /// stays reserved either way, so the media doesn't move.
    private func applyStripVisibility(animated: Bool) {
        guard !isSingleItemEditor, isViewLoaded else { return }
        let visible = stripIsInUse && !isToolOpen
            && !(isKeyboardUp && appearance.hidesThumbnailStripWithKeyboard)
        thumbnailStrip.isUserInteractionEnabled = visible
        if visible { thumbnailStrip.isHidden = false }
        let changes = { [weak self] in
            guard let self else { return }
            thumbnailStrip.alpha = visible ? 1 : 0
            view.layoutIfNeeded()
        }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self, thumbnailStrip.alpha == 0 else { return }
            thumbnailStrip.isHidden = true
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: changes, completion: completion)
        } else {
            changes()
            completion(true)
        }
    }

    /// Re-renders an item's thumbnail once its edits settle.
    private func scheduleThumbnailRefresh(for id: UUID) {
        guard !isSingleItemEditor else { return }
        thumbnailDebounce?.cancel()
        thumbnailDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.enqueueThumbnail(id)
        }
    }

    private func enqueueThumbnail(_ id: UUID) {
        guard !isSingleItemEditor else { return }
        if !thumbnailQueue.contains(id) { thumbnailQueue.append(id) }
        pumpThumbnails()
    }

    /// Renders queued thumbnails one at a time, so a large session never holds
    /// more than one decode at once.
    private func pumpThumbnails() {
        guard thumbnailTask == nil, !thumbnailQueue.isEmpty else { return }
        let id = thumbnailQueue.removeFirst()
        guard let item = items.first(where: { $0.id == id }) else { pumpThumbnails(); return }
        let maxPixelSize = appearance.thumbnailSize * max(1, traitCollection.displayScale)
        let images = overlayImages.merging(editRenderer.stickerImages(for: item.recipe)) { cached, _ in cached }
        thumbnailTask = Task { @MainActor [weak self] in
            guard let renderer = self?.editRenderer else { return }
            let image = await renderer.thumbnail(for: item, maxPixelSize: maxPixelSize, images: images)
            var duration: Double?
            if case let .video(url) = item.source {
                let total = (try? await AVURLAsset(url: url).load(.duration))?.seconds
                duration = item.recipe.trim?.duration ?? total
            }
            guard let self, !Task.isCancelled else { return }
            thumbnailTask = nil
            if items.contains(where: { $0.id == id }) {
                thumbnailRecipes[id] = item.recipe
                thumbnailStrip.setThumbnail(image, duration: duration, for: id)
                // Edited again while this one rendered.
                if items.first(where: { $0.id == id })?.recipe != item.recipe { enqueueThumbnail(id) }
            }
            pumpThumbnails()
        }
    }

    // MARK: - Zoom

    /// How far the media is magnified, and where it has been moved to, in
    /// points from where it sits unzoomed. The image view and the sticker
    /// layer carry it as one transform, so the edits zoom with the media.
    private(set) var zoomScale: CGFloat = 1
    private var zoomOffset: CGPoint = .zero
    private static let maximumZoom: CGFloat = 4
    /// Where the pinch's fingers were last, from the canvas centre.
    private var pinchAnchor: CGPoint?
    /// Whether the drag in progress pans zoomed-in media rather than paging.
    private var panMovesZoom = false

    /// Whether the media is zoomed in.
    var isZoomed: Bool { zoomScale > 1.01 }

    /// Photos and videos zoom in the main mode. Passthrough content is the
    /// host's own view, with its own gestures.
    private var canZoom: Bool { mode == .normal && !isPassthrough && paging == nil }

    private func applyZoom() {
        let transform = CGAffineTransform(translationX: zoomOffset.x, y: zoomOffset.y)
            .scaledBy(x: zoomScale, y: zoomScale)
        imageView.transform = transform
        overlayContainer.transform = transform
        updateCanvasPan()
    }

    /// Zoomed in, a drag pans in any direction; otherwise it pages, where the
    /// session allows it.
    private func updateCanvasPan() {
        let pan = overlayContainer.canvasPan
        pan.pagesItems = !isZoomed
        pan.isEnabled = isZoomed || allowsPaging
    }

    /// `point` in the view, measured from the unzoomed canvas centre.
    private func fromCanvasCenter(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - imageView.center.x, y: point.y - imageView.center.y)
    }

    private func handleCanvasPinch(_ pinch: UIPinchGestureRecognizer) {
        guard canZoom || pinchAnchor != nil else { return }
        let location = fromCanvasCenter(pinch.location(in: view))
        switch pinch.state {
        case .began:
            pinchAnchor = location
        case .changed:
            // A finger lifted mid-pinch moves the centroid; start over from
            // the one left rather than jump.
            guard let anchor = pinchAnchor, pinch.numberOfTouches >= 2 else {
                pinchAnchor = location
                return
            }
            // Keeps the media point under the fingers there as they spread
            // and move. A little give past the limits; `settleZoom` takes it
            // back.
            let scale = min(max(zoomScale * pinch.scale, 0.7), Self.maximumZoom * 1.25)
            let content = CGPoint(x: (anchor.x - zoomOffset.x) / zoomScale,
                                  y: (anchor.y - zoomOffset.y) / zoomScale)
            zoomOffset = CGPoint(x: location.x - content.x * scale, y: location.y - content.y * scale)
            zoomScale = scale
            pinch.scale = 1
            pinchAnchor = location
            applyZoom()
        default:
            pinchAnchor = nil
            settleZoom(animated: true)
        }
    }

    private func handleZoomPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .changed:
            let translation = pan.translation(in: view)
            pan.setTranslation(.zero, in: view)
            guard pinchAnchor == nil else { return }       // the pinch moves it
            zoomOffset.x += translation.x
            zoomOffset.y += translation.y
            applyZoom()
        case .ended:
            // Carried on a little by the flick, then kept inside the media.
            let velocity = pan.velocity(in: view)
            zoomOffset.x += velocity.x * 0.15
            zoomOffset.y += velocity.y * 0.15
            settleZoom(animated: true)
        case .cancelled, .failed:
            settleZoom(animated: true)
        default:
            break
        }
    }

    /// Zooms in on the double-tapped spot, or back out. `location` is in the
    /// sticker layer. Internal so tests can zoom without a real touch.
    func handleCanvasDoubleTap(at location: CGPoint) {
        guard canZoom else { return }
        if isZoomed {
            resetZoom(animated: true)
            return
        }
        // The sticker layer isn't transformed yet, so this is from the centre.
        let point = CGPoint(x: location.x - overlayContainer.bounds.midX,
                            y: location.y - overlayContainer.bounds.midY)
        zoomScale = 2.5
        zoomOffset = CGPoint(x: -point.x * zoomScale, y: -point.y * zoomScale)
        settleZoom(animated: true)
    }

    /// Brings the zoom back within its limits — no smaller than fitting, no
    /// bigger than `maximumZoom`, and no further aside than the media's own
    /// edges — and sharpens a photo for the magnification it lands on.
    private func settleZoom(animated: Bool) {
        zoomScale = min(max(zoomScale, 1), Self.maximumZoom)
        if zoomScale <= 1.01 {
            zoomScale = 1
            zoomOffset = .zero
        } else {
            zoomOffset = clampedZoomOffset(zoomOffset, scale: zoomScale)
        }
        let changes: () -> Void = { [weak self] in self?.applyZoom() }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
        } else {
            changes()
        }
        if refreshPreviewSourceIfNeeded() { renderPreview() }
    }

    /// The offset nearest `offset` that keeps the zoomed media covering the
    /// preview area, or centred along an axis where it's narrower than it.
    private func clampedZoomOffset(_ offset: CGPoint, scale: CGFloat) -> CGPoint {
        let bounds = imageView.bounds
        let media = displayedImageFrame()
        func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat, half: CGFloat) -> CGFloat {
            if high - low <= 2 * half { return -(low + high) / 2 }
            return min(max(value, half - high), -half - low)
        }
        return CGPoint(
            x: clamp(offset.x, low: (media.minX - bounds.midX) * scale, high: (media.maxX - bounds.midX) * scale,
                     half: bounds.width / 2),
            y: clamp(offset.y, low: (media.minY - bounds.midY) * scale, high: (media.maxY - bounds.midY) * scale,
                     half: bounds.height / 2))
    }

    /// Back to fitting the preview area.
    func resetZoom(animated: Bool = false) {
        pinchAnchor = nil
        guard zoomScale != 1 || zoomOffset != .zero else { return }
        zoomScale = 1
        zoomOffset = .zero
        settleZoom(animated: animated)
    }

    // MARK: - Paging

    /// A page turn between items, tab-view style: a track over the canvas
    /// holding a still of the selected item flanked by its neighbours, which
    /// follows the finger and settles on a page. The live canvas stays put
    /// underneath and only switches once the turn lands.
    private struct Paging {
        /// Covers the live canvas — it stays put, so the canvas never shows
        /// at an edge the moving pages have left.
        let cover: UIView
        /// The pages, side by side; this is what moves.
        let track: UIView
        /// The pages on the track, keyed by their offset from the selected item.
        let pages: [Int: UUID]
        let pageWidth: CGFloat
        /// Whether the video was playing when the turn began, to resume it if
        /// the turn springs back.
        let resumesPlayback: Bool
        /// The finger is still on it; once it lets go — or for a strip tap,
        /// from the start — the track is animating and a new drag leaves it be.
        var isTracking: Bool
    }

    /// Whether a page turn is under way — for tests.
    var isPaging: Bool { paging != nil }

    /// Whether a drag on the canvas may turn pages at all.
    private var allowsPaging: Bool { !isSingleItemEditor && appearance.allowsSwipeBetweenItems }

    /// A one-finger drag on empty canvas pans zoomed-in media, and otherwise
    /// turns the page.
    private func handleCanvasPan(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { panMovesZoom = isZoomed }
        if panMovesZoom {
            handleZoomPan(pan)
        } else {
            handlePagingPan(pan)
        }
    }

    @objc private func handlePagingPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            beginPaging()
        case .changed:
            updatePaging(translation: pan.translation(in: view).x)
        case .ended:
            endPaging(velocity: pan.velocity(in: view).x)
        case .cancelled, .failed:
            endPaging(velocity: 0, cancelled: true)
        default:
            break
        }
    }

    /// Lays the track over the canvas with the selected item's neighbours on
    /// either side. Internal so tests can turn pages without a real touch.
    func beginPaging() {
        guard paging == nil else { return }
        let index = selectedIndex
        var pages: [Int: UUID] = [:]
        for offset in [-1, 1] where items.indices.contains(index + offset) {
            pages[offset] = items[index + offset].id
        }
        startPaging(pages: pages, tracking: true)
    }

    /// Moves the track with the finger; past the first or last item it gives
    /// way only grudgingly.
    func updatePaging(translation: CGFloat) {
        guard let paging, paging.isTracking else { return }
        let offset = translation < 0 ? 1 : -1
        let x = paging.pages[offset] == nil ? translation * 0.3 : translation
        paging.track.transform = CGAffineTransform(translationX: x, y: 0)
    }

    /// Settles the turn: on the neighbour when the drag — carried on by its
    /// speed — passed halfway, otherwise back where it started.
    func endPaging(velocity: CGFloat, cancelled: Bool = false) {
        guard let paging, paging.isTracking else { return }
        let x = paging.track.transform.tx
        let projected = x + velocity * 0.2
        var offset = 0
        if !cancelled, abs(projected) > paging.pageWidth / 2 {
            let candidate = projected < 0 ? 1 : -1
            if paging.pages[candidate] != nil { offset = candidate }
        }
        settlePaging(on: offset, velocity: velocity)
    }

    /// Selects a strip tap's target straight away — the strip and
    /// `onSelectionChange` follow at once — and slides it in over the canvas
    /// from the side it sits on, whichever item it is.
    private func turnPage(to id: UUID) {
        guard id != selectedItemID, let target = items.firstIndex(where: { $0.id == id }) else { return }
        let offset = target > selectedIndex ? 1 : -1
        guard view.window != nil, startPaging(pages: [offset: id], tracking: false), let paging else {
            select(id)
            return
        }
        // The track is on its own from here: the selection it shows has
        // already happened underneath.
        self.paging = nil
        select(id)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            paging.track.transform = CGAffineTransform(translationX: -CGFloat(offset) * paging.pageWidth, y: 0)
        } completion: { [weak self] _ in
            self?.retire(paging.cover)
        }
    }

    @discardableResult
    private func startPaging(pages: [Int: UUID], tracking: Bool) -> Bool {
        guard paging == nil, mode == .normal, items.count > 1, !imageView.bounds.isEmpty else { return false }
        resetZoom()
        overlayContainer.deselect()
        let wasPlaying = isVideoPlaying
        if wasPlaying {
            player?.pause()
            syncTransport(animated: false)
        }

        // An opaque cover hides the live canvas, which would otherwise show
        // through wherever the pages have moved off; it sits below the
        // chrome, which stays where it is. The pages move on a track over it.
        let cover = UIView(frame: view.bounds)
        cover.backgroundColor = view.backgroundColor
        cover.isUserInteractionEnabled = false
        let track = UIView(frame: cover.bounds)
        cover.addSubview(track)
        let pageWidth = view.bounds.width
        let canvas = [imageView, passthroughHost, overlayContainer].filter { !$0.isHidden }
        for live in canvas {
            guard let still = live.snapshotView(afterScreenUpdates: false) else { continue }
            still.frame = live.frame
            track.addSubview(still)
        }
        for (offset, id) in pages {
            let page = pageView(for: id)
            page.frame = pageFrame(for: id).offsetBy(dx: CGFloat(offset) * pageWidth, dy: 0)
            track.addSubview(page)
        }
        view.insertSubview(cover, aboveSubview: overlayContainer)
        setVideoControlsFaded(true)
        paging = Paging(cover: cover, track: track, pages: pages, pageWidth: pageWidth, resumesPlayback: wasPlaying,
                        isTracking: tracking)
        return true
    }

    /// Animates the track onto the page `offset` from the selected item — `0`
    /// springs back — and selects that page's item once it lands.
    private func settlePaging(on offset: Int, velocity: CGFloat) {
        self.paging?.isTracking = false
        guard let paging else { return }
        let target = -CGFloat(offset) * paging.pageWidth
        let distance = target - paging.track.transform.tx
        let springVelocity = abs(distance) > 1 ? velocity / distance : 0
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: springVelocity, options: [.allowUserInteraction]) {
            paging.track.transform = CGAffineTransform(translationX: target, y: 0)
        } completion: { [weak self] _ in
            guard let self, self.paging?.cover === paging.cover else { return }
            guard let id = paging.pages[offset] else {
                self.abandonPaging()
                if paging.resumesPlayback {
                    self.player?.play()
                    self.syncTransport(animated: false)
                }
                return
            }
            self.paging = nil
            self.select(id)
            self.retire(paging.cover)
        }
    }

    /// Fades a landed turn off the canvas it now matches. It keeps covering
    /// the new item for a moment while it loads — a video's first frame takes
    /// one.
    private func retire(_ cover: UIView) {
        setVideoControlsFaded(false)
        UIView.animate(withDuration: 0.2, delay: 0.05, options: [.allowUserInteraction]) {
            cover.alpha = 0
        } completion: { _ in
            cover.removeFromSuperview()
        }
    }

    /// Drops a page turn on the spot, leaving the canvas as it is.
    private func abandonPaging() {
        guard let paging else { return }
        self.paging = nil
        paging.track.layer.removeAllAnimations()
        paging.cover.removeFromSuperview()
        setVideoControlsFaded(false)
    }

    /// The transport, filmstrip and readout belong to the item on the canvas,
    /// so they step out of a page turn and come back with whatever it lands on.
    private func setVideoControlsFaded(_ faded: Bool) {
        UIView.animate(withDuration: faded ? 0.15 : 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            for control in [self.playPauseButton, self.trimScrubber, self.timeLabel] as [UIView] {
                control.alpha = faded ? 0 : 1
            }
        }
    }

    /// Where item `id` sits when it's on the canvas, in the view: the preview
    /// area, or for a video the box above its controls — the same box
    /// `videoPreviewBounds` fits the player into, worked out even before any
    /// video has put its controls on screen.
    private func pageFrame(for id: UUID) -> CGRect {
        let area = imageView.frame
        guard let item = items.first(where: { $0.id == id }), case .video = item.source else { return area }
        let controlsTop: CGFloat
        if timeLabel.superview != nil, timeLabel.frame.height > 0 {
            controlsTop = timeLabel.frame.minY
        } else {
            controlsTop = bottomChromeTopY - Self.timeLabelBottomGap - Self.timeLabelHeight
                - (offersTrim ? Self.filmstripBottomGap + Self.filmstripHeight : 0)
        }
        let limit = controlsTop - Self.videoControlsGap
        guard limit > area.minY, limit < area.maxY else { return area }
        return CGRect(x: area.minX, y: area.minY, width: area.width, height: limit - area.minY)
    }

    /// Where `bottomChromeTopAnchor` is, in the view.
    private var bottomChromeTopY: CGFloat {
        if appearance.toolbarPlacement == .bottom, let toolRowContainer {
            let row = toolRowContainer === toolRowBackground ? toolRow : toolRowContainer
            return view.convert(row.bounds, from: row).minY
        }
        if let floatingDoneButton { return floatingDoneButton.frame.minY }
        return bottomChromeGuide.layoutFrame.minY
    }

    /// What a page turn shows for item `id`: the host's own view for
    /// passthrough content without a thumbnail — a document has nothing else
    /// to show — and otherwise the best picture on hand.
    private func pageView(for id: UUID) -> UIView {
        if let item = items.first(where: { $0.id == id }),
           case let .passthrough(thumbnail, preview) = item.source, thumbnail == nil {
            return preview()
        }
        let page = UIImageView(image: pagePreview(for: id))
        page.contentMode = .scaleAspectFit
        return page
    }

    /// The best picture of item `id` on hand: its screen-sized render, or else
    /// its strip thumbnail.
    private func pagePreview(for id: UUID) -> UIImage? {
        pagePreviews[id]?.image ?? thumbnailStrip.thumbnail(for: id)
    }

    /// Renders the selected item's neighbours at screen size, one at a time,
    /// and forgets everyone else's.
    private func prefetchPagePreviews() {
        guard !isSingleItemEditor, isViewLoaded else { return }
        let index = selectedIndex
        let neighbours = [index - 1, index + 1].filter(items.indices.contains).map { items[$0] }
        let wanted = Set(neighbours.map(\.id))
        pagePreviews = pagePreviews.filter { wanted.contains($0.key) }
        let stale = neighbours.filter { pagePreviews[$0.id]?.recipe != $0.recipe }
        pagePreviewTask?.cancel()
        guard !stale.isEmpty else { pagePreviewTask = nil; return }
        let size = imageView.bounds.isEmpty ? view.bounds.size : imageView.bounds.size
        let maxPixelSize = max(size.width, size.height) * max(1, traitCollection.displayScale)
        let renderer = editRenderer
        let jobs = stale.map { item in
            (item, overlayImages.merging(renderer.stickerImages(for: item.recipe)) { cached, _ in cached })
        }
        pagePreviewTask = Task { @MainActor [weak self] in
            for (item, images) in jobs {
                let image = await renderer.thumbnail(for: item, maxPixelSize: maxPixelSize, images: images)
                guard let self, !Task.isCancelled else { return }
                if let image { pagePreviews[item.id] = (item.recipe, image) }
            }
        }
    }

    /// Stops everything the editor runs in the background: pauses playback,
    /// invalidates the display link, cancels an in-flight export (its partial
    /// file is removed) and puts away the PencilKit tool picker.
    ///
    /// Call it when the editor leaves the screen for good — `MediaEditorView`
    /// does so when SwiftUI removes it. Ending a session does it too.
    public func tearDown() {
        exportTask?.cancel()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailDebounce?.cancel()
        pagePreviewTask?.cancel()
        pagePreviewTask = nil
        abandonPaging()
        photoLoadTask?.cancel()
        videoLoadTask?.cancel()
        teardownVideo()
        if mode == .draw {
            toolPicker.setVisible(false, forFirstResponder: canvasView)
            toolPicker.removeObserver(canvasView)
        }
    }

    /// Ends the session, reporting through whichever handler the editor was
    /// created with.
    private func endSession(_ result: MediaEditorSessionResult) {
        tearDown()
        if isSingleItemEditor {
            switch result {
            case .cancelled:
                onFinish?(.cancelled)
            case let .saved(results):
                guard let first = results.first, let output = first.output else { onFinish?(.cancelled); return }
                onFinish?(.saved(output: output, recipe: first.item.recipe))
            }
        } else {
            onSessionFinish?(result)
        }
    }

    // MARK: - Session end

    /// Cancels the session without saving.
    public func cancel() {
        endSession(.cancelled)
    }

    /// Confirms the edits.
    ///
    /// A single-item editor renders and reports through `onFinish`: photos
    /// synchronously, videos exported behind a progress panel with the drawing
    /// and overlays burned in. A multi-item session follows
    /// `EditorConfiguration.finishMode` — rendering every edited item behind
    /// the panel, or handing back the recipes straight away. Either way the
    /// output is exactly what ``EditRenderer`` produces.
    ///
    /// Cancelling the panel returns to the editor. If a render fails, an alert
    /// says so, anything already rendered for the session is deleted, and the
    /// user stays in the editor to try again.
    public func finish() {
        guard exportTask == nil else { return }              // already rendering
        if isSingleItemEditor {
            finishSingleItem()
            return
        }
        switch configuration.finishMode {
        case .recipesOnly:
            endSession(.saved(items.map { MediaEditorItemResult(item: $0, output: nil) }))
        case .render:
            renderSession()
        }
    }

    private func finishSingleItem() {
        switch item {
        case .photo:
            guard let sourceCGImage,
                  let rendered = renderer.renderGeometry(cgImage: sourceCGImage, recipe: recipe) else {
                onFinish?(.cancelled)
                return
            }
            let output = editRenderer.composite(base: UIImage(cgImage: rendered), recipe: recipe, images: overlayImages)
            onFinish?(.saved(output: .photo(output), recipe: recipe))
        case .video:
            renderSession()
        }
    }

    /// Renders every item that has edits, one after another, behind the
    /// progress panel — never in parallel, which would multiply peak memory.
    private func renderSession() {
        // Don't leave the preview running behind the export panel.
        player?.pause()
        syncTransport(animated: false)
        let snapshot = items
        let pending = snapshot.filter { item in
            // A single-item editor always renders; a session skips what has
            // nothing to render.
            item.source.isEditable && (isSingleItemEditor || !item.recipe.isIdentity)
        }
        guard !pending.isEmpty else {
            endSession(.saved(snapshot.map { MediaEditorItemResult(item: $0, output: nil) }))
            return
        }

        let hud = ExportProgressView(appearance: appearance)
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.onCancel = { [weak self] in self?.exportTask?.cancel() }
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hud.topAnchor.constraint(equalTo: view.topAnchor),
            hud.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var outputs: [UUID: EditorOutput] = [:]
            do {
                for (step, item) in pending.enumerated() {
                    try Task.checkCancellation()
                    let report: (Float) -> Void = { progress in
                        if pending.count == 1 {
                            hud.setProgress(progress)
                        } else {
                            hud.setProgress((Float(step) + progress) / Float(pending.count),
                                            item: step + 1, of: pending.count)
                        }
                    }
                    report(0)
                    let images = overlayImages.merging(editRenderer.stickerImages(for: item.recipe)) { cached, _ in cached }
                    if item.id == selectedItemID, item.source.kind == .photo, let sourceCGImage {
                        // Already decoded for editing — don't decode it twice.
                        outputs[item.id] = .photo(try await editRenderer.renderPhoto(
                            upright: sourceCGImage, recipe: item.recipe, images: images))
                    } else {
                        outputs[item.id] = try await editRenderer.render(
                            source: item.source, recipe: item.recipe, images: images, onProgress: report)
                    }
                    report(1)
                }
                hud.removeFromSuperview()
                exportTask = nil
                // Ownership of video files passes to the host here, and only here.
                endSession(.saved(snapshot.map { MediaEditorItemResult(item: $0, output: outputs[$0.id]) }))
            } catch {
                hud.removeFromSuperview()
                exportTask = nil
                // Whatever was rendered before the failure is thrown away; the
                // next attempt renders everything again.
                for case let .video(url) in outputs.values { try? FileManager.default.removeItem(at: url) }
                guard !(error is CancellationError) else { return }      // stay; the user cancelled
                let alert = UIAlertController(title: L10n.exportFailedTitle,
                                              message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
                present(alert, animated: true)
            }
        }
    }
}

// MARK: - Thumbnail strip delegate

extension MediaEditorViewController: ThumbnailStripDelegate {
    func thumbnailStrip(_ strip: ThumbnailStripView, didSelect id: UUID) {
        turnPage(to: id)
    }

    func thumbnailStrip(_ strip: ThumbnailStripView, didRemove id: UUID) {
        remove(id)
    }

    func thumbnailStrip(_ strip: ThumbnailStripView, didMoveItemFrom source: Int, to destination: Int) {
        moveItem(from: source, to: destination)
    }

    func thumbnailStripDidTapAdd(_ strip: ThumbnailStripView) {
        onAddItems?()
    }
}

// MARK: - Overlay container delegate

extension MediaEditorViewController: OverlayContainerDelegate {
    func overlayContainerDidCommit(_ container: OverlayContainerView) {
        // In crop mode the container shows the edits carried onto the whole
        // frame; a gesture that began before must not write those back.
        guard mode != .crop else { return }
        var next = recipe
        next.overlays = container.currentOverlays()
        apply(next)
    }

    /// A tap on the video preview toggles playback — the only way back to a
    /// paused state once the transport has faded out. A tap that merely clears a
    /// sticker selection is left alone, so dismissing a selection doesn't also
    /// stop the video.
    ///
    /// While the accessory is being typed into, a tap on the media only puts the
    /// keyboard away, the way a chat composer behaves.
    func overlayContainer(_ container: OverlayContainerView, didTapCanvasWithSelection hadSelection: Bool) {
        if let bottomAccessory, bottomAccessory.containsFirstResponder {
            bottomAccessory.endEditing(true)
            return
        }
        guard case .video = item, mode == .normal, !hadSelection else { return }
        togglePlayback()
    }

    /// The delete bin sits just above the filmstrip while a sticker moves, which
    /// on a wide video can overlap the centred transport — so step it aside.
    func overlayContainer(_ container: OverlayContainerView, isDraggingSticker dragging: Bool) {
        guard case .video = item else { return }
        UIView.transition(with: playPauseButton, duration: 0.2, options: .transitionCrossDissolve,
                          animations: { self.playPauseButton.isHidden = dragging })
    }

    func overlayContainer(_ container: OverlayContainerView, requestsTextEditFor id: UUID) {
        guard let overlay = recipe.overlays.first(where: { $0.id == id }),
              case let .text(style) = overlay.content else { return }
        presentTextEditor(seed: style) { [weak self] newStyle in
            guard let self else { return }
            var next = recipe
            if let index = next.overlays.firstIndex(where: { $0.id == id }) {
                next.overlays[index].content = .text(newStyle)
            }
            apply(next)
            overlayContainer.reload(overlays: recipe.overlays, images: overlayImages)
        }
    }
}

private extension UIView {
    /// Whether this view or anything inside it holds the keyboard.
    var containsFirstResponder: Bool {
        isFirstResponder || subviews.contains { $0.containsFirstResponder }
    }
}

// MARK: - Filter bar delegate

extension MediaEditorViewController: FilterBarDelegate {
    func filterBar(_ bar: FilterBarView, didSelect filter: PhotoFilter) {
        filterWorkingFilter = filter
        renderFilterPreview()
    }
}

// MARK: - Rotation dial delegate

extension MediaEditorViewController: RotationDialDelegate {
    func rotationDial(_ dial: RotationDialView, didChangeTo degrees: Double) {
        cropAdjustmentBegan()
        cropStraighten = degrees
        renderCropPreview()
        cropOverlay.reset()   // keep the frame filling the clean inscribed area
    }

    func rotationDialDidCommit(_ dial: RotationDialView) {
        cropAdjustmentEnded()
        // The angle is committed to the recipe on Apply.
    }
}

// MARK: - Trim scrubber delegate

extension MediaEditorViewController: TrimScrubberDelegate {
    func trimScrubber(_ scrubber: TrimScrubberView, didChangeTrimFrom start: Double, to end: Double,
                      movingEdge edge: TrimScrubberView.Edge) {
        videoTrimStart = start
        videoTrimEnd = end
        switch edge {
        case .start:
            // Choosing the in-point: preview it, so the elapsed time follows the
            // handle.
            park(at: start)
        case .end:
            // Only the out-point — the total — moves. Stay put unless that's now
            // past the end; the playhead still re-clamps against the moving grip.
            if playbackPosition > end {
                park(at: end)
            } else {
                scrubber.updatePlayhead(time: playbackPosition)
                refreshTimeReadout()
            }
        }
    }

    func trimScrubberDidCommit(_ scrubber: TrimScrubberView) {
        var next = recipe
        next.trim = TrimRange(start: scrubber.trimStart, duration: scrubber.trimEnd - scrubber.trimStart)
        apply(next)
    }

    func trimScrubber(_ scrubber: TrimScrubberView, didScrubTo time: Double) {
        // Scrubbing previews the kept range only: the playhead can't leave the
        // grips, and the readout shouldn't show a time the clip won't include.
        park(at: min(max(time, videoTrimStart), videoTrimEnd))
    }
}

// MARK: - Photo picker delegate

extension MediaEditorViewController: PHPickerViewControllerDelegate {
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            // This callback is already off the main thread. Downscaling a
            // camera-sized image and PNG-encoding the result costs tens of
            // milliseconds — do both here rather than hitching the editor, and
            // hop to the main actor only to insert the finished overlay.
            let scaled = Self.downscaledOffscreen(image)
            let data = scaled.pngData()
            Task { @MainActor in
                guard let self else { return }
                self.insertOverlay(content: .image(ImageRef(id: UUID(), data: data)),
                                   image: scaled)
            }
        }
    }
}

#endif
