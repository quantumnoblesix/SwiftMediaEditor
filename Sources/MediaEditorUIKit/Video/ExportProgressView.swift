//
//  ExportProgressView.swift
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

/// A modal progress overlay shown while a video export runs, with a cancel
/// control.
@MainActor
final class ExportProgressView: UIView {

    var onCancel: (() -> Void)?

    private let progressView = UIProgressView(progressViewStyle: .default)
    private let label = UILabel()
    private let appearance: EditorAppearance

    init(appearance: EditorAppearance) {
        self.appearance = appearance
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        backgroundColor = UIColor.black.withAlphaComponent(0.7)

        label.text = L10n.exportProgress(percent: 0)
        label.textColor = appearance.tint
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center

        progressView.progressTintColor = appearance.accent
        progressView.trackTintColor = appearance.tint.withAlphaComponent(0.3)

        let cancel = UIButton(type: .system)
        cancel.setTitle(L10n.cancel, for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, progressView, cancel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Liquid Glass panel on iOS 26, blurred material below.
        let panel = appearance.makeBarBackground(cornerRadius: 24)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        panel.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),

            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -24),
        ])
    }

    func setProgress(_ progress: Float) {
        progressView.setProgress(progress, animated: true)
        label.text = L10n.exportProgress(percent: Int(progress * 100))
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}

#endif
