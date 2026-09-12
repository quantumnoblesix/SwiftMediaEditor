//
//  TextEditorViewController.swift
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

/// A minimal full-screen text entry surface for adding or editing a text/emoji
/// overlay. Returns the resulting `TextStyle`, or `nil` on cancel.
@MainActor
final class TextEditorViewController: UIViewController, UITextViewDelegate {

    private var style: TextStyle
    private let onFinish: (TextStyle?) -> Void

    private let textView = UITextView()
    private let swatchColors: [RGBAColor] = [
        .white, .black,
        RGBAColor(red: 1, green: 0.23, blue: 0.19),   // red
        RGBAColor(red: 1, green: 0.8, blue: 0),       // yellow
        RGBAColor(red: 0.2, green: 0.6, blue: 1),     // blue
        RGBAColor(red: 0.3, green: 0.85, blue: 0.4),  // green
    ]

    private let appearance: EditorAppearance

    init(style: TextStyle, appearance: EditorAppearance, onFinish: @escaping (TextStyle?) -> Void) {
        self.style = style
        self.appearance = appearance
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.85)

        let cancel = UIButton(type: .system)
        appearance.styleBarButton(cancel, title: L10n.cancel, role: .dismissing)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let done = UIButton(type: .system)
        appearance.styleBarButton(done, title: L10n.done, role: .confirming)
        done.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        let topBar = UIStackView(arrangedSubviews: [cancel, UIView(), done])
        topBar.translatesAutoresizingMaskIntoConstraints = false

        textView.backgroundColor = .clear
        textView.textColor = style.color.uiColor
        textView.tintColor = .white
        textView.font = .systemFont(ofSize: 40, weight: .semibold)
        textView.textAlignment = .center
        textView.text = style.string
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.keyboardAppearance = .dark

        let swatches = UIStackView()
        swatches.distribution = .equalSpacing
        swatches.translatesAutoresizingMaskIntoConstraints = false
        for (index, color) in swatchColors.enumerated() {
            let button = UIButton(type: .system)
            button.backgroundColor = color.uiColor
            button.layer.cornerRadius = 16
            button.layer.borderWidth = 2
            button.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
            button.tag = index
            button.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            swatches.addArrangedSubview(button)
        }

        // A full color picker for any custom color beyond the preset swatches.
        let picker = UIButton(type: .system)
        picker.setImage(UIImage(systemName: "paintpalette.fill"), for: .normal)
        picker.tintColor = .white
        picker.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        picker.layer.cornerRadius = 16
        picker.addTarget(self, action: #selector(presentColorPicker), for: .touchUpInside)
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.widthAnchor.constraint(equalToConstant: 32).isActive = true
        picker.heightAnchor.constraint(equalToConstant: 32).isActive = true
        swatches.addArrangedSubview(picker)

        [topBar, textView, swatches].forEach(view.addSubview)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            textView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            textView.heightAnchor.constraint(lessThanOrEqualToConstant: 240),

            swatches.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            swatches.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            swatches.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    @objc private func colorTapped(_ sender: UIButton) {
        let color = swatchColors[sender.tag]
        style.color = color
        textView.textColor = color.uiColor
    }

    @objc private func presentColorPicker() {
        let picker = UIColorPickerViewController()
        picker.selectedColor = style.color.uiColor
        picker.supportsAlpha = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func applyPickedColor(_ color: UIColor) {
        style.color = RGBAColor(color)
        textView.textColor = color
    }

    @objc private func cancelTapped() {
        dismiss(animated: true) { [onFinish] in onFinish(nil) }
    }

    @objc private func doneTapped() {
        style.string = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = style.string.isEmpty ? nil : style
        dismiss(animated: true) { [onFinish] in onFinish(result) }
    }
}

extension TextEditorViewController: UIColorPickerViewControllerDelegate {
    func colorPickerViewController(_ viewController: UIColorPickerViewController,
                                   didSelect color: UIColor, continuously: Bool) {
        applyPickedColor(color)
    }
}

#endif
