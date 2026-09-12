//
//  LocalizationTests.swift
//  MediaEditorUIKitTests
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing
@testable import MediaEditorUIKit

@Suite("Localization")
struct LocalizationTests {

    /// Loads the `.lproj` bundle for a language shipped inside the package.
    ///
    /// Matched case-insensitively: SwiftPM lowercases the region subtag when it
    /// builds the resource bundle for macOS (`pt-BR.lproj` → `pt-br.lproj`),
    /// while Xcode's iOS build preserves it. Language tags are case-insensitive
    /// per BCP 47, so both spellings are the same localization — this test is
    /// about the translations being present, not the directory's spelling.
    private func bundle(for language: String) throws -> Bundle {
        let name = L10n.bundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        } ?? language
        let path = try #require(L10n.bundle.path(forResource: name, ofType: "lproj"),
                                "Missing \(language).lproj in the package bundle")
        return try #require(Bundle(path: path))
    }

    /// A key resolves when the returned value differs from the key itself.
    private func value(_ key: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    @Test("Every shipped language provides every key",
          arguments: ["en", "it", "fr", "es", "pt-BR"])
    func everyLanguageIsComplete(language: String) throws {
        let bundle = try bundle(for: language)
        for key in L10n.allKeys {
            let translated = value(key, in: bundle)
            #expect(translated != key, "\(language) is missing a translation for \"\(key)\"")
            #expect(!translated.isEmpty, "\(language) has an empty translation for \"\(key)\"")
        }
    }

    @Test("Supported languages list matches the shipped bundles")
    func supportedLanguagesMatchBundles() throws {
        for language in L10n.supportedLanguages {
            _ = try bundle(for: language)
        }
        #expect(L10n.supportedLanguages.count == 5)
    }

    @Test("Translations are actually distinct per language")
    func translationsDiffer() throws {
        // "Cancel" differs across these languages, so a mis-wired bundle
        // (everything falling back to English) would fail here.
        let english = value("action.cancel", in: try bundle(for: "en"))
        let italian = value("action.cancel", in: try bundle(for: "it"))
        let french = value("action.cancel", in: try bundle(for: "fr"))
        #expect(english == "Cancel")
        #expect(italian == "Annulla")
        #expect(french == "Annuler")
    }

    @Test("Export progress format substitutes the percentage",
          arguments: ["en", "it", "fr", "es", "pt-BR"])
    func exportProgressFormats(language: String) throws {
        let format = value("export.progress", in: try bundle(for: language))
        let rendered = String(format: format, 42)
        #expect(rendered.contains("42"), "\(language) progress string lost the number: \(rendered)")
        #expect(rendered.contains("%"), "\(language) progress string lost the percent sign: \(rendered)")
        // The %% escape must not leak through as a literal "%%".
        #expect(!rendered.contains("%%"))
    }
}
