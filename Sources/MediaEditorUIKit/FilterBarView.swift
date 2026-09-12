//
//  FilterBarView.swift
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
protocol FilterBarDelegate: AnyObject {
    func filterBar(_ bar: FilterBarView, didSelect filter: PhotoFilter)
}

/// A horizontal carousel of filter thumbnails, à la the iOS Photos Filters tab.
/// Each cell shows the current image rendered with that filter plus its name.
@MainActor
final class FilterBarView: UIView {

    weak var delegate: FilterBarDelegate?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var cells: [(filter: PhotoFilter, button: UIButton, thumb: UIImageView, label: UILabel)] = []
    private(set) var selected: PhotoFilter = .none

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = 14
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rebuilds the carousel from `thumbnails` (filter → preview image).
    func configure(thumbnails: [(filter: PhotoFilter, image: UIImage)], selected: PhotoFilter) {
        self.selected = selected
        cells.forEach { $0.button.removeFromSuperview() }
        cells.removeAll()

        for entry in thumbnails {
            let thumb = UIImageView(image: entry.image)
            thumb.contentMode = .scaleAspectFill
            thumb.clipsToBounds = true
            thumb.layer.cornerRadius = 8
            thumb.layer.cornerCurve = .continuous
            thumb.accessibilityIgnoresInvertColors = true   // a photo, not chrome
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.widthAnchor.constraint(equalToConstant: 64).isActive = true
            thumb.heightAnchor.constraint(equalToConstant: 64).isActive = true

            let label = UILabel()
            label.text = L10n.filterName(entry.filter)
            label.font = EditorAccessibility.scaledFont(.systemFont(ofSize: 11, weight: .medium),
                                                       textStyle: .caption2, maximumPointSize: 14)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .white
            label.textAlignment = .center

            let cellStack = UIStackView(arrangedSubviews: [thumb, label])
            cellStack.axis = .vertical
            cellStack.spacing = 5
            cellStack.alignment = .center
            cellStack.isUserInteractionEnabled = false

            let button = UIButton(type: .system)
            button.addSubview(cellStack)
            cellStack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                cellStack.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                cellStack.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                cellStack.topAnchor.constraint(equalTo: button.topAnchor),
                cellStack.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            // The name is drawn inside the button, so VoiceOver needs it spelled out.
            button.accessibilityLabel = L10n.filterName(entry.filter)
            button.addAction(UIAction { [weak self] _ in self?.select(entry.filter) }, for: .touchUpInside)

            stack.addArrangedSubview(button)
            cells.append((entry.filter, button, thumb, label))
        }
        updateSelectionUI()
    }

    private func select(_ filter: PhotoFilter) {
        selected = filter
        updateSelectionUI()
        delegate?.filterBar(self, didSelect: filter)
    }

    private func updateSelectionUI() {
        for cell in cells {
            let isSelected = cell.filter == selected
            cell.thumb.layer.borderWidth = isSelected ? 2.5 : 0
            cell.thumb.layer.borderColor = UIColor.systemYellow.cgColor
            cell.label.textColor = isSelected ? .systemYellow : .white
            cell.button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }
}

#endif
