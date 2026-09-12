//
//  EditorConfigurationTests.swift
//  MediaEditorCoreTests
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Testing
import MediaEditorCore

@Suite("EditorConfiguration")
struct EditorConfigurationTests {

    @Test("By default each kind of media gets every tool it supports")
    func defaults() {
        let configuration = EditorConfiguration()
        #expect(configuration.tools(for: .photo) == .allPhoto)
        #expect(configuration.tools(for: .video) == .allVideo)
    }

    @Test("Photo and video tools are chosen independently")
    func independentSets() {
        var configuration = EditorConfiguration()
        configuration.photoTools = [.crop, .drawing]
        configuration.videoTools = [.trim]
        #expect(configuration.tools(for: .photo) == [.crop, .drawing])
        #expect(configuration.tools(for: .video) == [.trim])
    }

    @Test("A tool the media can't use is dropped rather than offered")
    func unsupportedToolsIgnored() {
        let configuration = EditorConfiguration(photoTools: [.crop, .trim, .audio],
                                                videoTools: [.filters, .overlays])
        #expect(configuration.tools(for: .photo) == [.crop])
        #expect(configuration.tools(for: .video) == [.overlays])
    }

    @Test("Setting tools applies one list to both kinds")
    func sharedList() {
        var configuration = EditorConfiguration()
        configuration.tools = [.crop, .overlays]
        #expect(configuration.photoTools == [.crop, .overlays])
        #expect(configuration.videoTools == [.crop, .overlays])
        #expect(configuration.tools == [.crop, .overlays])
    }
}
