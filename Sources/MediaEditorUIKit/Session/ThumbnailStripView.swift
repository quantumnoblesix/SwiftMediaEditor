//
//  ThumbnailStripView.swift
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
import MediaEditorCore

@MainActor
protocol ThumbnailStripDelegate: AnyObject {
    func thumbnailStrip(_ strip: ThumbnailStripView, didSelect id: UUID)
    func thumbnailStrip(_ strip: ThumbnailStripView, didRemove id: UUID)
    func thumbnailStrip(_ strip: ThumbnailStripView, didMoveItemFrom source: Int, to destination: Int)
    func thumbnailStripDidTapAdd(_ strip: ThumbnailStripView)
}

/// The row of thumbnails a multi-item session moves between.
///
/// Tapping a thumbnail selects its item. Tapping the *selected* one arms it — a
/// trash overlay appears — and tapping it again removes the item, so a removal
/// always takes a deliberate second tap. Long-press-and-drag reorders when the
/// appearance allows it, and an optional trailing "+" cell asks for more items.
/// VoiceOver gets the same through custom actions.
@MainActor
final class ThumbnailStripView: UIView {

    weak var delegate: ThumbnailStripDelegate?

    /// The items in strip order.
    private(set) var items: [MediaEditorItem] = []
    private(set) var selectedID: UUID?
    /// The selected item, when its trash overlay is showing.
    private(set) var armedID: UUID?
    /// Whether the trailing "+" cell is shown.
    var showsAddCell = false {
        didSet { if showsAddCell != oldValue { collectionView.reloadData() } }
    }

    private var thumbnails: [UUID: UIImage] = [:]
    private var durations: [UUID: Double] = [:]
    private let appearance: EditorAppearance
    private let collectionView: UICollectionView

    /// The strip's height for `appearance`: a cell plus padding.
    static func height(for appearance: EditorAppearance) -> CGFloat {
        appearance.thumbnailSize + 16
    }

    init(appearance: EditorAppearance) {
        self.appearance = appearance
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: appearance.thumbnailSize, height: appearance.thumbnailSize)
        layout.minimumLineSpacing = appearance.thumbnailSpacing
        layout.sectionInset = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        backgroundColor = appearance.thumbnailStripBackground

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ThumbnailCell.self, forCellWithReuseIdentifier: ThumbnailCell.reuseID)
        collectionView.register(AddCell.self, forCellWithReuseIdentifier: AddCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if appearance.allowsReordering {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handleReorder(_:)))
            collectionView.addGestureRecognizer(press)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    /// Replaces the items and the selection, and scrolls the selection into
    /// the middle.
    func update(items: [MediaEditorItem], selectedID: UUID) {
        let selectionChanged = selectedID != self.selectedID
        self.items = items
        self.selectedID = selectedID
        if selectionChanged || !items.contains(where: { $0.id == armedID }) { armedID = nil }
        let ids = Set(items.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        durations = durations.filter { ids.contains($0.key) }
        collectionView.reloadData()
        if selectionChanged { scrollSelectionToCentre(animated: window != nil) }
    }

    /// Shows `image` for item `id`, and for a video its trimmed duration.
    func setThumbnail(_ image: UIImage?, duration: Double?, for id: UUID) {
        thumbnails[id] = image
        durations[id] = duration
        guard let index = items.firstIndex(where: { $0.id == id }),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? ThumbnailCell
        else { return }
        configure(cell, at: index)
    }

    /// The thumbnail shown for `id`, if any — the editor scales it up as a
    /// placeholder while a full-size photo decodes.
    func thumbnail(for id: UUID) -> UIImage? { thumbnails[id] }

    private func scrollSelectionToCentre(animated: Bool) {
        guard let index = items.firstIndex(where: { $0.id == selectedID }) else { return }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0),
                                    at: .centeredHorizontally, animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The first layout gives the collection a width; centre the selection
        // once it can.
        if collectionView.bounds.width > 0, collectionView.contentOffset == .zero {
            scrollSelectionToCentre(animated: false)
        }
    }

    // MARK: - Interaction

    /// A tap on `id`'s cell, as the collection view or VoiceOver reports it.
    func tap(_ id: UUID) {
        if id == selectedID {
            if armedID == id {
                armedID = nil
                delegate?.thumbnailStrip(self, didRemove: id)
            } else {
                armedID = id
                reloadVisibleCells()
            }
        } else {
            armedID = nil
            delegate?.thumbnailStrip(self, didSelect: id)
        }
    }

    private func reloadVisibleCells() {
        for indexPath in collectionView.indexPathsForVisibleItems where indexPath.section == 0 {
            if let cell = collectionView.cellForItem(at: indexPath) as? ThumbnailCell {
                configure(cell, at: indexPath.item)
            }
        }
    }

    @objc private func handleReorder(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: point), indexPath.section == 0 else { return }
            armedID = nil
            collectionView.beginInteractiveMovementForItem(at: indexPath)
        case .changed:
            collectionView.updateInteractiveMovementTargetPosition(CGPoint(x: point.x, y: collectionView.bounds.midY))
        case .ended:
            collectionView.endInteractiveMovement()
        default:
            collectionView.cancelInteractiveMovement()
        }
    }

    /// Moves an item one place, for VoiceOver's reorder actions.
    private func move(_ id: UUID, by offset: Int) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let destination = index + offset
        guard items.indices.contains(destination) else { return false }
        delegate?.thumbnailStrip(self, didMoveItemFrom: index, to: destination)
        return true
    }

    // MARK: - Cells

    private func configure(_ cell: ThumbnailCell, at index: Int) {
        let item = items[index]
        let isSelected = item.id == selectedID
        cell.configure(image: thumbnails[item.id], kind: item.source.kind,
                       duration: durations[item.id], isSelected: isSelected,
                       isArmed: item.id == armedID, appearance: appearance)

        cell.accessibilityLabel = L10n.stripItem(kind: item.source.kind, index: index + 1, count: items.count)
        cell.accessibilityTraits = isSelected ? [.button, .selected] : .button
        var actions: [UIAccessibilityCustomAction] = [
            UIAccessibilityCustomAction(name: L10n.stripRemove) { [weak self] _ in
                guard let self else { return false }
                delegate?.thumbnailStrip(self, didRemove: item.id)
                return true
            },
        ]
        if appearance.allowsReordering {
            actions.append(UIAccessibilityCustomAction(name: L10n.stripMoveLeft) { [weak self] _ in
                self?.move(item.id, by: -1) ?? false
            })
            actions.append(UIAccessibilityCustomAction(name: L10n.stripMoveRight) { [weak self] _ in
                self?.move(item.id, by: 1) ?? false
            })
        }
        cell.accessibilityCustomActions = actions
        appearance.styleThumbnailCell?(cell.contentView, item, isSelected)
    }
}

// MARK: - Data source and delegate

extension ThumbnailStripView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    // The "+" cell is a section of its own; space it like one more thumbnail
    // rather than with a second set of edge insets.
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        insetForSectionAt section: Int) -> UIEdgeInsets {
        let edge: CGFloat = 16
        if section == 0 {
            return UIEdgeInsets(top: 8, left: edge, bottom: 8, right: showsAddCell ? appearance.thumbnailSpacing : edge)
        }
        return UIEdgeInsets(top: 8, left: 0, bottom: 8, right: edge)
    }


    func numberOfSections(in collectionView: UICollectionView) -> Int { 2 }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        section == 0 ? items.count : (showsAddCell ? 1 : 0)
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if indexPath.section == 1 {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AddCell.reuseID,
                                                          for: indexPath) as! AddCell
            cell.configure(appearance: appearance)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ThumbnailCell.reuseID,
                                                      for: indexPath) as! ThumbnailCell
        configure(cell, at: indexPath.item)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        if indexPath.section == 1 {
            delegate?.thumbnailStripDidTapAdd(self)
        } else {
            tap(items[indexPath.item].id)
        }
    }

    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        appearance.allowsReordering && indexPath.section == 0
    }

    func collectionView(_ collectionView: UICollectionView,
                        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
                        atCurrentIndexPath currentIndexPath: IndexPath,
                        toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        // Never past the "+" cell.
        guard proposedIndexPath.section == 0 else {
            return IndexPath(item: max(0, items.count - 1), section: 0)
        }
        return proposedIndexPath
    }

    func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath,
                        to destinationIndexPath: IndexPath) {
        let moved = items.remove(at: sourceIndexPath.item)
        items.insert(moved, at: destinationIndexPath.item)
        delegate?.thumbnailStrip(self, didMoveItemFrom: sourceIndexPath.item, to: destinationIndexPath.item)
    }
}

// MARK: - Cells

@MainActor
private final class ThumbnailCell: UICollectionViewCell {
    static let reuseID = "ThumbnailCell"

    private let imageView = UIImageView()
    private let placeholder = UIImageView()
    private let videoBadge = UIStackView()
    private let durationLabel = UILabel()
    private let trashOverlay = UIView()
    private let trashGlyph = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        contentView.clipsToBounds = true
        contentView.backgroundColor = UIColor(white: 1, alpha: 0.12)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        placeholder.contentMode = .center
        placeholder.tintColor = UIColor(white: 1, alpha: 0.7)

        let glyph = UIImageView(image: UIImage(systemName: "play.fill",
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)))
        glyph.tintColor = .white
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        durationLabel.textColor = .white
        videoBadge.axis = .horizontal
        videoBadge.spacing = 3
        videoBadge.alignment = .center
        videoBadge.addArrangedSubview(glyph)
        videoBadge.addArrangedSubview(durationLabel)
        videoBadge.layer.shadowColor = UIColor.black.cgColor
        videoBadge.layer.shadowOpacity = 0.6
        videoBadge.layer.shadowRadius = 2
        videoBadge.layer.shadowOffset = .zero

        trashGlyph.contentMode = .center
        trashGlyph.image = UIImage(systemName: "trash.fill",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        trashGlyph.tintColor = .white
        trashOverlay.addSubview(trashGlyph)

        for view in [imageView, placeholder, videoBadge, trashOverlay, trashGlyph] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(placeholder)
        contentView.addSubview(imageView)
        contentView.addSubview(videoBadge)
        contentView.addSubview(trashOverlay)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            videoBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            videoBadge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            trashOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            trashOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            trashOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            trashOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            trashGlyph.centerXAnchor.constraint(equalTo: trashOverlay.centerXAnchor),
            trashGlyph.centerYAnchor.constraint(equalTo: trashOverlay.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(image: UIImage?, kind: MediaKind?, duration: Double?, isSelected: Bool,
                   isArmed: Bool, appearance: EditorAppearance) {
        contentView.layer.cornerRadius = appearance.thumbnailCornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderWidth = isSelected ? 2 : 0
        contentView.layer.borderColor = appearance.accent.cgColor
        imageView.image = image
        let symbol = kind == nil ? "doc.fill" : (kind == .video ? "video.fill" : "photo")
        placeholder.image = image == nil ? UIImage(systemName: symbol) : nil
        videoBadge.isHidden = kind != .video
        durationLabel.text = duration.map { PlaybackTimeLabel.format($0, style: .forDuration($0), locale: .autoupdatingCurrent) }
        trashOverlay.backgroundColor = appearance.destructive.withAlphaComponent(0.75)
        trashOverlay.isHidden = !isArmed
        alpha = 1
    }
}

@MainActor
private final class AddCell: UICollectionViewCell {
    static let reuseID = "AddCell"
    private let glyph = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = L10n.stripAdd
        contentView.backgroundColor = UIColor(white: 1, alpha: 0.12)
        glyph.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(appearance: EditorAppearance) {
        contentView.layer.cornerRadius = appearance.thumbnailCornerRadius
        contentView.layer.cornerCurve = .continuous
        glyph.tintColor = appearance.tint
    }
}

#endif
