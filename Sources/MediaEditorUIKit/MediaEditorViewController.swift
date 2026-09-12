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
/// Photos get the geometry tools (crop / rotate / flip) with a live preview
/// driven by the non-destructive `EditRecipe` + `PhotoRenderer`, plus filters,
/// drawing, overlays, undo/redo, and save. Videos get the crop tool, drawing and
/// overlays over a play/pause preview, trim, and audio removal, all exported
/// through `VideoComposer`.
@MainActor
public final class MediaEditorViewController: UIViewController {

    /// The media being edited.
    public let item: MediaItem
    /// Editor configuration (enabled tools, aspect presets, export settings).
    public let configuration: EditorConfiguration
    /// Called once when the session ends, on the main actor.
    public var onFinish: ((EditorResult) -> Void)?

    /// How the built-in chrome is styled. Set through `init`; changing it after
    /// the view loads has no effect on bars already built.
    public let appearance: EditorAppearance

    /// Supplies a replacement tool row. When it returns a view, the built-in
    /// bar is never created and the host drives the editor through
    /// `perform(_:)`. See ``MediaEditorToolbarProviding``.
    public private(set) weak var toolbarProvider: (any MediaEditorToolbarProviding)?

    /// Undo/redo history over the working recipe.
    private var history: EditHistory<EditRecipe>

    /// The current working recipe.
    public private(set) var recipe: EditRecipe {
        didSet {
            // Overlays are live views over the render, so an overlay-only edit
            // (dragging a sticker) needs no new bitmap at all.
            if recipe.rendersDifferently(from: oldValue) { renderPreview() }
            if case .video = item, isViewLoaded {
                syncVideoState()
            }
        }
    }

    // MARK: - Rendering

    private let renderer = PhotoRenderer()
    private let overlayCompositor = OverlayCompositor()
    private let drawingCompositor = DrawingCompositor()
    /// The orientation-normalized source image (photos only).
    private let sourceImage: UIImage?
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
        return v
    }()

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    /// Clips the player layer to the recipe's crop; sized to the rendered output.
    private let videoContainer = UIView()
    /// The recipe's drawing over the playing video, inside the crop clip. Photos
    /// bake strokes into the preview bitmap; a video has no bitmap to bake into.
    /// Internal so tests can check it.
    let videoDrawingView = UIImageView()
    /// The drawing `videoDrawingView` shows, so recipe changes that leave the
    /// strokes alone don't re-rasterize them.
    private var renderedVideoDrawing: DrawingData?
    private let videoArtworkRenderer = VideoArtworkRenderer()
    /// The video's oriented display size, resolved once the asset loads.
    /// Internal so tests can stand in for a real asset.
    var videoOrientedSize: CGSize = .zero
    /// Whether the filmstrip is on offer for this session.
    private var showsTrimScrubber: Bool {
        configuration.tools(for: item.kind).contains(.trim)
    }

    // Video editing state.
    private let composer = VideoComposer()
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
    private let bottomToolbar = UIStackView()
    
    private lazy var bottomToolbarBackground = appearance.makeBarBackground(cornerRadius: appearance.toolbarCornerRadius)
    /// A host-supplied tool row, when `toolbarProvider` returned one.
    private var customToolbar: UIView?

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

    // Crop-mode geometry state (folded into the recipe on apply).
    private var cropRotationBase: Double = 0           // 90° preset steps
    private var cropStraighten: Double = 0             // free dial angle
    private var cropFlip = FlipState.none

    // Draw-mode chrome.
    private let canvasView = PKCanvasView()
    private let toolPicker = PKToolPicker()
    private let drawTopBar = UIStackView()
    /// The tool titles, which VoiceOver moves to when a tool opens.
    private let cropTitleLabel = UILabel()
    private let drawTitleLabel = UILabel()
    private let filterTitleLabel = UILabel()

    // Filter-mode chrome.
    private let filterTopBar = UIStackView()
    private let filterBar = FilterBarView()
    private lazy var filterBarBackground = appearance.makeBarBackground(cornerRadius: 20)
    private var filterWorkingFilter: PhotoFilter = .none

    private lazy var undoButton = makeToolButton(.undo, selector: #selector(undoTapped),
                                                 pointSize: appearance.historySymbolPointSize)
    private lazy var redoButton = makeToolButton(.redo, selector: #selector(redoTapped),
                                                 pointSize: appearance.historySymbolPointSize)
    private lazy var audioButton = makeToolButton(.toggleAudio, selector: #selector(toggleAudioTapped))

    // MARK: - Init

    /// - Parameters:
    ///   - item: media to edit.
    ///   - recipe: a recipe to resume from, or `.identity` for a fresh session.
    ///   - configuration: enabled tools and export settings.
    ///   - appearance: how the built-in chrome is styled.
    ///   - toolbarProvider: supplies a replacement tool row, or `nil` for the
    ///     built-in one. Held weakly — keep your own reference to it.
    ///   - onFinish: completion handler delivering the result.
    public init(
        item: MediaItem,
        recipe: EditRecipe = .identity,
        configuration: EditorConfiguration = .default,
        appearance: EditorAppearance = .default,
        toolbarProvider: (any MediaEditorToolbarProviding)? = nil,
        onFinish: ((EditorResult) -> Void)? = nil
    ) {
        self.item = item
        self.configuration = configuration
        self.appearance = appearance
        self.toolbarProvider = toolbarProvider
        self.recipe = recipe
        self.history = EditHistory(initial: recipe, limit: configuration.historyLimit)
        if case let .photo(image) = item {
            let normalized = image.normalizedUp()
            self.sourceImage = normalized
            self.sourceCGImage = normalized.cgImage
        } else {
            self.sourceImage = nil
            self.sourceCGImage = nil
        }
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        // Restore image-overlay content from a resumed recipe.
        for overlay in recipe.overlays {
            if case let .image(ref) = overlay.content, let data = ref.data,
               let image = UIImage(data: data) {
                overlayImages[ref.id] = image
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupChrome()
        setupCropChrome()
        setupDrawChrome()
        setupFilterChrome()
        setupPreview()
        liftChromeAbovePreview()
        renderPreview()
        overlayContainer.reload(overlays: recipe.overlays, images: overlayImages)
        updateHistoryButtons()
        // Icon buttons show in the large content viewer at accessibility text
        // sizes; the interaction has to live on an ancestor.
        view.addInteraction(UILargeContentViewerInteraction())
        NotificationCenter.default.addObserver(self, selector: #selector(differentiateWithoutColorChanged),
                                               name: UIAccessibility.differentiateWithoutColorDidChangeNotification,
                                               object: nil)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if refreshPreviewSourceIfNeeded(), mode == .normal { renderPreview() }
        layoutVideoPreview()
        // Container shares the image view's frame, so the displayed-image rect
        // (in image-view bounds coordinates) maps directly to container bounds.
        overlayContainer.frame = imageView.frame
        overlayContainer.imageFrame = displayedImageFrame()
        overlayContainer.preferredTrashCenter = trashCenterAboveBottomControls()
        if mode == .crop {
            positionCropOverlay()
        }
        if mode == .draw {
            canvasView.frame = view.convert(displayedImageFrame(), from: imageView)
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        // Photos and video frames keep their colours under Smart Invert.
        imageView.accessibilityIgnoresInvertColors = true
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),
            imageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -88),
        ])

        // Sticker layer floats over the image; positioned in layout passes.
        overlayContainer.delegate = self
        overlayContainer.appearance = appearance
        overlayContainer.clipsToBounds = false
        view.addSubview(overlayContainer)

        if case let .video(url) = item {
            setupVideo(url: url)
        }
    }

    /// The preview and its sticker layer are added after the chrome, and the
    /// sticker layer claims every touch inside the preview rect. The history
    /// pill sits just below the top bar — i.e. *inside* that rect — so the
    /// chrome has to be lifted back above it or its buttons never see a tap.
    private func liftChromeAbovePreview() {
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(historyBarBackground)
        if let customToolbar {
            view.bringSubviewToFront(customToolbar)
        } else {
            view.bringSubviewToFront(bottomToolbarBackground)
        }
    }

    /// Where the sticker delete bin goes: centred just above the bottom controls
    /// — for a video the time readout on top of them, otherwise the tool row —
    /// which is close to where the thumb already is.
    ///
    /// It has to clear that control rather than tuck beneath it: the controls are
    /// layered above the sticker layer the bin lives in. The gap leaves room for
    /// the bin's armed swell, spring overshoot included.
    private func trashCenterAboveBottomControls() -> CGPoint? {
        let controls: UIView? = videoControlsTop ?? (customToolbar ?? bottomToolbarBackground)
        guard let controls, controls.superview != nil else { return nil }
        let controlsTop = view.convert(controls.bounds, from: controls).minY
        guard controlsTop > 0 else { return nil }      // not laid out yet
        let center = CGPoint(x: view.bounds.midX,
                             y: controlsTop - 16 - StickerTrashView.diameter / 2)
        return overlayContainer.convert(center, from: view)
    }

    private func setupChrome() {
        // Top bar: Cancel / Done
        let cancel = makeTextButton(L10n.cancel, role: .dismissing, action: #selector(cancelTapped))
        let done = makeTextButton(L10n.done, role: .confirming, action: #selector(doneTapped))
        historyBar.axis = .horizontal
        historyBar.alignment = .center
        historyBar.spacing = 16
        historyBar.addArrangedSubview(undoButton)
        historyBar.addArrangedSubview(redoButton)
        historyBar.translatesAutoresizingMaskIntoConstraints = false
        historyBarBackground.translatesAutoresizingMaskIntoConstraints = false
        historyBarBackground.contentView.addSubview(historyBar)
        // Its own row under Cancel rather than beside it, so the top bar keeps
        // the familiar Cancel / Done shape.
        view.addSubview(historyBarBackground)

        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.addArrangedSubview(cancel)
        topBar.addArrangedSubview(UIView())          // pushes Done to the trailing edge
        topBar.addArrangedSubview(done)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        // The top bar is identical whoever supplies the tool row, so pin it here
        // rather than in each branch below.
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            historyBarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            historyBarBackground.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),

            historyBar.leadingAnchor.constraint(equalTo: historyBarBackground.contentView.leadingAnchor, constant: 12),
            historyBar.trailingAnchor.constraint(equalTo: historyBarBackground.contentView.trailingAnchor, constant: -12),
            historyBar.topAnchor.constraint(equalTo: historyBarBackground.contentView.topAnchor, constant: 4),
            historyBar.bottomAnchor.constraint(equalTo: historyBarBackground.contentView.bottomAnchor, constant: -4),
        ])

        // A host-supplied row replaces the built-in bar outright.
        if let provider = toolbarProvider,
           let custom = provider.makeToolbar(for: toolbarActions, editor: self) {
            customToolbar = custom
            custom.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(custom)
            NSLayoutConstraint.activate([
                custom.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
                custom.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
                custom.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                custom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            ])
            provider.updateToolbar(custom, editor: self)
            return
        }

        // Bottom toolbar: geometry tools + undo/redo, floating on a glass bar.
        bottomToolbar.axis = .horizontal
        bottomToolbar.distribution = .fill
        bottomToolbar.spacing = 28
        bottomToolbar.alignment = .center
        for v in toolbarButtons() { bottomToolbar.addArrangedSubview(v) }
        bottomToolbar.translatesAutoresizingMaskIntoConstraints = false
        bottomToolbarBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomToolbarBackground)
        bottomToolbarBackground.contentView.addSubview(bottomToolbar)

        NSLayoutConstraint.activate([
            // The row now holds tools only, so it hugs its content and centres
            // rather than stretching the full width.
            bottomToolbarBackground.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomToolbarBackground.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            bottomToolbarBackground.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            bottomToolbarBackground.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            bottomToolbar.leadingAnchor.constraint(equalTo: bottomToolbarBackground.contentView.leadingAnchor, constant: 24),
            bottomToolbar.trailingAnchor.constraint(equalTo: bottomToolbarBackground.contentView.trailingAnchor, constant: -24),
            bottomToolbar.topAnchor.constraint(equalTo: bottomToolbarBackground.contentView.topAnchor, constant: 12),
            bottomToolbar.bottomAnchor.constraint(equalTo: bottomToolbarBackground.contentView.bottomAnchor, constant: -12),
        ])
    }

    private func setupCropChrome() {
        // Crop top bar: Cancel / "Crop" / Apply
        let cancel = makeTextButton(L10n.cancel, role: .dismissing, action: #selector(cancelCropTapped))
        let title = cropTitleLabel
        styleToolTitle(title, text: L10n.cropTitle)
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
        let tools = configuration.tools(for: item.kind)
        cropToolsBar.axis = .horizontal
        cropToolsBar.spacing = 18
        cropToolsBar.alignment = .center
        if tools.contains(.flip) {
            cropToolsBar.addArrangedSubview(makeToolButton(.flipHorizontal, selector: #selector(cropFlipHTapped)))
            cropToolsBar.addArrangedSubview(makeToolButton(.flipVertical, selector: #selector(cropFlipVTapped)))
        }
        if tools.contains(.rotate) {
            cropToolsBar.addArrangedSubview(makeToolButton(.rotate, selector: #selector(cropRotateTapped)))
        }
        cropToolsBar.translatesAutoresizingMaskIntoConstraints = false
        cropToolsBackground.translatesAutoresizingMaskIntoConstraints = false
        cropToolsBackground.isHidden = true
        view.addSubview(cropToolsBackground)
        cropToolsBackground.contentView.addSubview(cropToolsBar)

        // Manual straighten dial, above the aspect bar.
        rotationDial.delegate = self
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
        reset.accessibilityLabel = L10n.resetCrop
        reset.largeContentTitle = L10n.resetCrop
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

    private func setupDrawChrome() {
        let cancel = makeTextButton(L10n.cancel, role: .dismissing, action: #selector(cancelDrawTapped))
        let title = drawTitleLabel
        styleToolTitle(title, text: L10n.drawTitle)
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
        canvasView.accessibilityLabel = L10n.drawingCanvas
        canvasView.accessibilityIgnoresInvertColors = true
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
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
        let title = filterTitleLabel
        styleToolTitle(title, text: L10n.filtersTitle)
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

    /// Builds the enabled geometry tool buttons plus undo/redo.
    private func toolbarButtons() -> [UIView] {
        var buttons: [UIView] = []
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
            // Stays out of the row until the asset is known to carry audio.
            audioButton.isHidden = true
            buttons.append(audioButton)
        }
        return buttons
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

    /// A tool's title in its top bar: a heading VoiceOver can jump to, sized with
    /// Dynamic Type up to what the bar has room for.
    private func styleToolTitle(_ title: UILabel, text: String) {
        title.text = text
        title.textColor = .white
        title.font = EditorAccessibility.scaledFont(.boldSystemFont(ofSize: 16), textStyle: .headline,
                                                   maximumPointSize: 22)
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header
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
        let cap = (max(imageView.bounds.width, imageView.bounds.height) * scale).rounded()
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
        var image = UIImage(cgImage: rendered)
        // Bake the drawing into the preview (overlays stay as live views on top).
        if let drawing = recipe.drawing {
            image = drawingCompositor.composite(base: image, drawing: drawing)
        }
        imageView.image = image
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
        notifyToolbarStateChanged()
    }

    /// Lets a host-supplied tool row refresh itself after any state change.
    private func notifyToolbarStateChanged() {
        guard let customToolbar, let toolbarProvider else { return }
        toolbarProvider.updateToolbar(customToolbar, editor: self)
    }

    /// Shows or hides whichever tool row is in play. A custom row can opt out
    /// of being hidden while a modal tool is open.
    private func setMainToolbarHidden(_ hidden: Bool) {
        if let customToolbar {
            guard toolbarProvider?.hidesToolbarInToolMode(customToolbar) ?? true else { return }
            customToolbar.isHidden = hidden
        } else {
            bottomToolbarBackground.isHidden = hidden
        }
    }

    /// The top of the tool row, whichever one is in play — the trim scrubber
    /// sits above it.
    private var toolbarTopAnchor: NSLayoutYAxisAnchor {
        customToolbar?.topAnchor ?? bottomToolbar.topAnchor
    }

    // MARK: - Crop mode

    @objc private func cropTapped() { enterCropMode() }

    /// Enters crop mode: rotate/flip presets and a straighten dial operate on the
    /// image behind a crop frame, matching the iOS Photos crop tool.
    public func enterCropMode() {
        guard mode == .normal, cropSourceSize.width > 0, cropSourceSize.height > 0 else { return }
        if case .photo = item, sourceCGImage == nil { return }
        mode = .crop

        // A still frame is what you compose a crop against, and the transport
        // and filmstrip would collide with the crop chrome.
        if case .video = item {
            setPlaybackChromeHidden(true)
            // Crop shows the whole uncropped frame; the strokes belong to the
            // cropped one.
            videoDrawingView.isHidden = true
        }

        // Split the recipe's rotation into a 90° preset base and a straighten
        // remainder so the dial reflects the current angle.
        let degrees = recipe.rotation.degrees
        let preset = (degrees / 90).rounded() * 90
        cropRotationBase = preset
        cropStraighten = degrees - preset
        cropFlip = recipe.flip
        rotationDial.setDegrees(cropStraighten)

        overlayContainer.deselect()
        overlayContainer.isHidden = true

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
        UIAccessibility.post(notification: .screenChanged, argument: cropTitleLabel)
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
    }

    @objc private func cropFlipHTapped() {
        cropFlip.horizontal.toggle()
        renderCropPreview()
    }

    @objc private func cropFlipVTapped() {
        cropFlip.vertical.toggle()
        renderCropPreview()
    }

    @objc private func cropRotateTapped() {
        cropRotationBase += 90            // rotate 90° clockwise
        renderCropPreview()
        cropOverlay.reset()
    }

    @objc private func applyCropTapped() {
        var next = recipe
        next.rotation = RotationState(degrees: cropTotalDegrees)
        next.flip = cropFlip
        if cropOverlay.isEffectivelyFull {
            next.crop = nil
        } else {
            next.crop = CropState(rect: cropOverlay.normalizedCropRect(), aspect: cropOverlay.aspect)
        }
        exitCropMode()
        apply(next)
    }

    @objc private func cancelCropTapped() {
        exitCropMode()
        renderPreview()
    }

    @objc private func resetCropTapped() {
        cropStraighten = 0
        rotationDial.setDegrees(0)
        renderCropPreview()
        cropOverlay.reset()
    }

    @objc private func aspectTapped(_ sender: UIButton) {
        guard let match = aspectButtons.first(where: { $0.button === sender }) else { return }
        cropOverlay.aspect = match.preset
        highlightAspectButton(for: match.preset)
    }

    private func highlightAspectButton(for preset: AspectPreset) {
        // Colour marks the choice on screen; VoiceOver hears it as selected, and
        // Differentiate Without Color adds an underline.
        let underlineSelection = UIAccessibility.shouldDifferentiateWithoutColor
        for (p, button) in aspectButtons {
            let title = label(for: p)
            let selected = title == label(for: preset)
            let underline = selected && underlineSelection
            let tint: UIColor = selected ? .systemYellow : .white
            // Configuration-backed (glass) buttons ignore setTitleColor.
            if button.configuration != nil {
                button.configuration?.baseForegroundColor = tint
                if underline {
                    var attributed = AttributedString(title)
                    // Named through the UIKit scope: left implicit, the key can resolve
                    // to SwiftUI's attribute, which this module doesn't link.
                    attributed.uiKit.underlineStyle = .single
                    button.configuration?.attributedTitle = attributed
                } else {
                    button.configuration?.title = title
                }
            } else {
                button.setTitleColor(tint, for: .normal)
                let underlined = NSAttributedString(string: title, attributes: [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: tint,
                    .font: button.titleLabel?.font ?? UIFont.systemFont(ofSize: 15),
                ])
                button.setAttributedTitle(underline ? underlined : nil, for: .normal)
            }
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    private func exitCropMode() {
        mode = .normal
        cropOverlay.removeFromSuperview()
        if case .video = item {
            setPlaybackChromeHidden(false)
            videoDrawingView.isHidden = false
            // Back to the recipe's own geometry, crop included.
            layoutVideoPreview()
        }
        overlayContainer.isHidden = false
        topBar.isHidden = false
        setMainToolbarHidden(false)
        cropTopBar.isHidden = true
        cropToolsBackground.isHidden = true
        rotationDial.isHidden = true
        cropAspectBarBackground.isHidden = true
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    // MARK: - Accessibility gestures

    /// VoiceOver's two-finger double-tap plays or pauses a video from anywhere,
    /// as it does in media apps.
    public override func accessibilityPerformMagicTap() -> Bool {
        guard case .video = item, mode == .normal, player != nil else { return false }
        togglePlayback()
        return true
    }

    /// VoiceOver's two-finger scrub backs out of the open tool, as its Cancel
    /// button does. It never dismisses the editor itself: a stray gesture
    /// shouldn't throw away every edit.
    public override func accessibilityPerformEscape() -> Bool {
        switch mode {
        case .crop:   cancelCropTapped()
        case .draw:   cancelDrawTapped()
        case .filter: cancelFilterTapped()
        case .normal: return false
        }
        return true
    }

    @objc private func differentiateWithoutColorChanged() {
        guard mode == .crop else { return }
        highlightAspectButton(for: cropOverlay.aspect)
    }

    // MARK: - Video

    private func setupVideo(url: URL) {
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
        // Strokes sit above the picture and inside the clip, stretched with it.
        videoDrawingView.contentMode = .scaleToFill
        videoDrawingView.isUserInteractionEnabled = false
        videoContainer.addSubview(videoDrawingView)
        imageView.addSubview(videoContainer)
        self.player = player
        self.playerLayer = layer

        // The filmstrip is a configurable tool, not fixed furniture: a host that
        // leaves `.trim` out gets playback and the other tools without it.
        if showsTrimScrubber {
            trimScrubber.delegate = self
            trimScrubber.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(trimScrubber)
            NSLayoutConstraint.activate([
                trimScrubber.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                trimScrubber.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                trimScrubber.bottomAnchor.constraint(equalTo: toolbarTopAnchor, constant: -12),
                trimScrubber.heightAnchor.constraint(equalToConstant: 60),
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
        // appears; it's measured from the readout's font, which follows Dynamic
        // Type.
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timeLabel)
        NSLayoutConstraint.activate([
            timeLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            timeLabel.bottomAnchor.constraint(equalTo: showsTrimScrubber ? trimScrubber.topAnchor : toolbarTopAnchor,
                                              constant: -8),
            timeLabel.heightAnchor.constraint(equalToConstant: ceil(timeLabel.font.lineHeight)),
        ])

        displayLinkProxy.onTick = { [weak self] in
            guard let self else { return false }   // editor gone — stop the link
            playbackTick()
            return true
        }
        let link = CADisplayLink(target: displayLinkProxy,
                                 selector: #selector(DisplayLinkProxy.tick(_:)))
        // The tick only nudges a playhead and watches for the player stopping;
        // it has no business running at a ProMotion 120 Hz.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 15)
        link.isPaused = true                 // nothing to track until playback starts
        link.add(to: .main, forMode: .common)
        displayLink = link

        Task { @MainActor [weak self] in
            guard let self else { return }
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            videoDuration = duration
            videoTrimStart = recipe.trim?.start ?? 0
            videoTrimEnd = recipe.trim?.end ?? duration
            timeLabel.configure(duration: duration)
            if showsTrimScrubber {
                trimScrubber.configure(asset: asset, duration: duration)
                if let trim = recipe.trim { trimScrubber.setTrim(start: trim.start, end: trim.end) }
            }
            hasAudioTrack = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
            videoOrientedSize = await orientedSize(of: asset)
            syncVideoState()
            // Park on the first frame — unless the user already hit play while
            // the asset was still loading.
            if !isVideoPlaying { park(at: videoTrimStart) } else { refreshTimeReadout() }
        }
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
        trimScrubber.isHidden = hidden
        timeLabel.isHidden = hidden || !timeLabel.isConfigured
    }

    private func syncVideoState() {
        player?.isMuted = recipe.removeAudio
        updateAudioButton()
        // Undo/redo can change the trim without the filmstrip being touched, so
        // the handles, loop range and readout have to follow the recipe.
        syncTrimFromRecipe()
        updateVideoDrawing()
        layoutVideoPreview()
    }

    /// Rasterizes the recipe's drawing for the video preview when it changes.
    ///
    /// Drawn at the authoring canvas size — the frame's on-screen size when the
    /// strokes went down — and stretched with the frame from there, as the export
    /// stretches it to the output size.
    private func updateVideoDrawing() {
        guard recipe.drawing != renderedVideoDrawing else { return }
        renderedVideoDrawing = recipe.drawing
        guard let drawing = recipe.drawing else {
            videoDrawingView.image = nil
            return
        }
        let scale = max(1, traitCollection.displayScale)
        let pixels = CGSize(width: drawing.canvasWidth * scale, height: drawing.canvasHeight * scale)
        videoDrawingView.image = drawingCompositor.strokeImage(for: drawing, outputSize: pixels)
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
    var isVideoPlaying: Bool { player?.timeControlStatus != .paused }

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
        audioButton.isHidden = !hasAudioTrack
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
        audioButton.largeContentTitle = audioButton.accessibilityLabel
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
        let limit = imageView.convert(controls.frame, from: view).minY - 12
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
        videoDrawingView.frame = videoContainer.bounds
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
        overlayContainer.imageFrame = displayedImageFrame()
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

    // MARK: - Video export

    private func exportVideo() {
        guard let asset = videoAsset else { onFinish?(.cancelled); return }
        // Don't leave the preview running behind the export panel.
        player?.pause()
        syncTransport(animated: false)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEditor-\(UUID().uuidString).mp4")
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

        exportTask = Task { @MainActor in
            defer { hud.removeFromSuperview() }
            do {
                try await composer.export(
                    asset: asset, recipe: recipe, to: output,
                    preset: configuration.videoExportPreset,
                    maximumDimension: configuration.maximumExportDimension,
                    onProgress: { progress in hud.setProgress(progress) },
                    overlayImage: { [recipe = self.recipe, images = self.overlayImages,
                                     artwork = self.videoArtworkRenderer] size in
                        // Rendered at the output resolution, so text stays crisp.
                        artwork.render(drawing: recipe.drawing, overlays: recipe.overlays,
                                       images: images, size: size)
                    })
                teardownVideo()
                // Ownership passes to the host here, and only here.
                onFinish?(.saved(output: .video(output), recipe: recipe))
            } catch is CancellationError {
                // Cancelled exports leave a partial file nobody will ever read.
                try? FileManager.default.removeItem(at: output)
                // Stay in the editor; the user cancelled.
            } catch {
                try? FileManager.default.removeItem(at: output)
                let alert = UIAlertController(title: L10n.exportFailedTitle,
                                              message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
                present(alert, animated: true)
            }
        }
    }

    // MARK: - Draw mode

    @objc private func drawTapped() { enterDrawingMode() }

    /// Enters PencilKit drawing mode over the geometry-applied image, or over the
    /// paused video frame.
    public func enterDrawingMode() {
        guard mode == .normal else { return }
        switch item {
        case .photo:
            guard let source = previewSource else { return }
            mode = .draw
            // Show the geometry image only; the canvas renders the strokes itself.
            if let rendered = renderer.renderGeometry(cgImage: source, recipe: recipe) {
                imageView.image = UIImage(cgImage: rendered)
            }
        case .video:
            // No frame on screen yet means no canvas size to author against.
            guard !videoContainer.frame.isEmpty else { return }
            mode = .draw
            setPlaybackChromeHidden(true)
            videoDrawingView.isHidden = true         // the canvas shows the strokes
        }

        overlayContainer.deselect()
        overlayContainer.isHidden = true
        topBar.isHidden = true
        setMainToolbarHidden(true)
        drawTopBar.isHidden = false

        view.layoutIfNeeded()
        canvasView.frame = view.convert(displayedImageFrame(), from: imageView)
        loadDrawingIntoCanvas()
        view.addSubview(canvasView)
        view.bringSubviewToFront(drawTopBar)

        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: drawTitleLabel)
    }

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
        } else {
            next.drawing = DrawingData(
                data: pkDrawing.dataRepresentation(),
                canvasWidth: Double(size.width),
                canvasHeight: Double(size.height)
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
        canvasView.removeFromSuperview()
        mode = .normal
        if case .video = item {
            setPlaybackChromeHidden(false)
            videoDrawingView.isHidden = false
        }
        overlayContainer.isHidden = false
        topBar.isHidden = false
        setMainToolbarHidden(false)
        drawTopBar.isHidden = true
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    // MARK: - Filter mode

    @objc private func filterTapped() { enterFilterMode() }

    /// Enters the filters carousel with a live preview.
    public func enterFilterMode() {
        guard sourceCGImage != nil, mode == .normal else { return }
        mode = .filter
        filterWorkingFilter = recipe.filter

        filterBar.configure(thumbnails: makeFilterThumbnails(), selected: filterWorkingFilter)
        renderFilterPreview()

        topBar.isHidden = true
        setMainToolbarHidden(true)
        filterTopBar.isHidden = false
        filterBarBackground.isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: filterTitleLabel)
    }

    /// Preview with the working filter (geometry + filter + drawing; overlays stay
    /// as live views on top).
    private func renderFilterPreview() {
        guard let source = previewSource else { return }
        var r = recipe
        r.filter = filterWorkingFilter
        guard let rendered = renderer.renderGeometry(cgImage: source, recipe: r) else { return }
        var image = UIImage(cgImage: rendered)
        if let drawing = r.drawing {
            image = drawingCompositor.composite(base: image, drawing: drawing)
        }
        imageView.image = image
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
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    // MARK: - Overlays (stickers)

    private func addText() {
        presentTextEditor(seed: TextStyle(string: "")) { [weak self] style in
            self?.insertOverlay(content: .text(style), image: nil)
        }
    }

    private func addPhoto() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentTextEditor(seed: TextStyle, completion: @escaping (TextStyle) -> Void) {
        let editor = TextEditorViewController(style: seed, appearance: appearance) { style in
            guard let style else { return }
            completion(style)
        }
        present(editor, animated: true)
    }

    /// Appends a new overlay centered on the canvas, on top of the stack.
    private func insertOverlay(content: OverlayContent, image: UIImage?) {
        let nextZ = (recipe.overlays.map(\.zIndex).max() ?? -1) + 1
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
        apply(next)
    }

    @objc private func flipHTapped() {
        var next = recipe
        next.flip.horizontal.toggle()
        apply(next)
    }

    @objc private func flipVTapped() {
        var next = recipe
        next.flip.vertical.toggle()
        apply(next)
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
        let tools = configuration.tools(for: item.kind)
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

    // MARK: - Session end

    /// Cancels the session without saving.
    public func cancel() {
        teardownVideo()
        onFinish?(.cancelled)
    }

    /// Renders the current recipe and finishes with the result.
    ///
    /// Photos render synchronously through `PhotoRenderer`. Videos export
    /// asynchronously through `VideoComposer` behind a progress panel, with the
    /// drawing and overlays burned in; `onFinish` fires once the file is ready.
    public func finish() {
        switch item {
        case .photo:
            guard let sourceCGImage,
                  let rendered = renderer.renderGeometry(cgImage: sourceCGImage, recipe: recipe) else {
                onFinish?(.cancelled)
                return
            }
            var base = UIImage(cgImage: rendered)
            if let drawing = recipe.drawing {
                base = drawingCompositor.composite(base: base, drawing: drawing)
            }
            let output = overlayCompositor.composite(base: base, overlays: recipe.overlays, images: overlayImages)
            onFinish?(.saved(output: .photo(output), recipe: recipe))
        case .video:
            exportVideo()
        }
    }
}

// MARK: - Overlay container delegate

extension MediaEditorViewController: OverlayContainerDelegate {
    func overlayContainerDidCommit(_ container: OverlayContainerView) {
        var next = recipe
        next.overlays = container.currentOverlays()
        apply(next)
    }

    /// A tap on the video preview toggles playback — the only way back to a
    /// paused state once the transport has faded out. A tap that merely clears a
    /// sticker selection is left alone, so dismissing a selection doesn't also
    /// stop the video.
    func overlayContainer(_ container: OverlayContainerView, didTapCanvasWithSelection hadSelection: Bool) {
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
        cropStraighten = degrees
        renderCropPreview()
        cropOverlay.reset()   // keep the frame filling the clean inscribed area
    }

    func rotationDialDidCommit(_ dial: RotationDialView) {
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
