//
//  MetalFXSettingTests.swift
//  WhiskyKitTests
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import Testing
@testable import WhiskyKit

@Suite("MetalFX Backend Reconciliation Tests")
@MainActor
struct MetalFXBackendTests {
    private let tempDir: URL

    init() throws {
        tempDir = try makeGPTKTempDir()
    }

    private func makeBottle(metalFX: Bool) throws -> Bottle {
        let url = tempDir.appending(path: "bottle")
        try FileManager.default.createDirectory(
            at: url.appending(path: "drive_c").appending(path: "windows").appending(path: "system32"),
            withIntermediateDirectories: true
        )
        let bottle = Bottle(bottleUrl: url)
        bottle.settings.metalFX = metalFX
        return bottle
    }

    private func placeholder(inBottle bottle: Bottle) -> URL {
        bottle.url.appending(path: "drive_c").appending(path: "windows")
            .appending(path: "system32").appending(path: GPTKImporter.metalFXBridgeName)
    }

    private func makeRuntimeWithBridge() throws -> URL {
        let store = try makeImportedStore(in: tempDir)
        try makeStoreMetalFXBridge(inStore: store)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)
        return runtime
    }

    @Test("D3DMetal with the setting on seeds the placeholder")
    func d3dMetalSeeds() throws {
        let runtime = try makeRuntimeWithBridge()
        let bottle = try makeBottle(metalFX: true)

        Wine.applyMetalFX(bottle: bottle, backend: .d3dMetal, libraryFolder: runtime)

        #expect(FileManager.default.fileExists(
            atPath: placeholder(inBottle: bottle).path(percentEncoded: false)
        ))
    }

    @Test("Switching off D3DMetal clears the placeholder, setting on or not")
    func otherBackendsClear() throws {
        let runtime = try makeRuntimeWithBridge()
        let bottle = try makeBottle(metalFX: true)

        for backend in [GraphicsBackend.dxvk, .dxmt, .wined3d] {
            Wine.applyMetalFX(bottle: bottle, backend: .d3dMetal, libraryFolder: runtime)
            #expect(FileManager.default.fileExists(
                atPath: placeholder(inBottle: bottle).path(percentEncoded: false)
            ))

            // only D3DMetal answers the DLSS entry points behind the placeholder
            Wine.applyMetalFX(bottle: bottle, backend: backend, libraryFolder: runtime)
            #expect(!FileManager.default.fileExists(
                atPath: placeholder(inBottle: bottle).path(percentEncoded: false)
            ))
        }
    }
}

@Suite("MetalFX Setting Tests")
struct MetalFXSettingTests {
    @Test("The setting is on by default and survives a round trip")
    func settingRoundTrips() throws {
        var settings = BottleSettings()
        #expect(settings.metalFX)

        settings.metalFX = false
        let decoded = try PropertyListDecoder().decode(
            BottleSettings.self, from: PropertyListEncoder().encode(settings)
        )

        #expect(!decoded.metalFX)
    }

    @Test("A bottle written before the key existed picks up the new default")
    func absentKeyDefaultsOn() throws {
        // The graphics config is nested, so an older bottle's plist has the
        // dictionary without the key rather than no dictionary at all.
        let plist: [String: Any] = ["graphicsConfig": ["backend": "recommended"]]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )

        let decoded = try PropertyListDecoder().decode(BottleSettings.self, from: data)

        #expect(decoded.metalFX)
    }

    @Test("The env var follows the setting, and is only set under D3DMetal")
    func environmentFollowsTheSetting() throws {
        var builder = EnvironmentBuilder()
        var settings = BottleSettings()
        settings.graphicsBackend = .d3dMetal
        _ = settings.populateBottleManagedLayer(builder: &builder, resolvedBackend: .d3dMetal)
        #expect(builder.resolve().environment["D3DM_ENABLE_METALFX"] == "1")

        settings.metalFX = false
        var offBuilder = EnvironmentBuilder()
        _ = settings.populateBottleManagedLayer(builder: &offBuilder, resolvedBackend: .d3dMetal)
        #expect(offBuilder.resolve().environment["D3DM_ENABLE_METALFX"] == nil)

        // DXVK never reaches D3DMetal's bridge, so the knob would be a lie
        settings.metalFX = true
        settings.graphicsBackend = .dxvk
        var dxvkBuilder = EnvironmentBuilder()
        _ = settings.populateBottleManagedLayer(builder: &dxvkBuilder, resolvedBackend: .dxvk)
        #expect(dxvkBuilder.resolve().environment["D3DM_ENABLE_METALFX"] == nil)
    }

    @Test("MetalFX writes the whole NVIDIA identity, not only the vendor id D3DMetal flips")
    func metalFXWritesTheAdapterIdentity() throws {
        var settings = BottleSettings()
        settings.graphicsBackend = .d3dMetal
        var builder = EnvironmentBuilder()
        _ = settings.populateBottleManagedLayer(builder: &builder, resolvedBackend: .d3dMetal)
        let env = builder.resolve().environment
        #expect(env["D3DM_VENDOR_ID"] == GPUVendor.nvidia.vendorID)
        #expect(env["D3DM_DEVICE_ID"] == GPUVendor.nvidia.deviceID)
        #expect(env["D3DM_DEVICE_DESCRIPTION"] == GPUVendor.nvidia.modelName)

        settings.metalFX = false
        var offBuilder = EnvironmentBuilder()
        _ = settings.populateBottleManagedLayer(builder: &offBuilder, resolvedBackend: .d3dMetal)
        #expect(offBuilder.resolve().environment["D3DM_VENDOR_ID"] == nil)
    }
}

@Suite("Metal 4 Setting Tests")
struct Metal4SettingTests {
    @Test("The setting is on by default and survives a round trip")
    func settingRoundTrips() throws {
        var settings = BottleSettings()
        #expect(settings.metal4Enabled)

        settings.metal4Enabled = false
        let decoded = try PropertyListDecoder().decode(
            BottleSettings.self, from: PropertyListEncoder().encode(settings)
        )

        #expect(!decoded.metal4Enabled)
    }

    @Test("A bottle written before the key existed picks up the new default")
    func absentKeyDefaultsOn() throws {
        let plist: [String: Any] = ["metalConfig": ["metalHud": false]]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )

        let decoded = try PropertyListDecoder().decode(BottleSettings.self, from: data)

        #expect(decoded.metal4Enabled)
    }

    @Test("The env var follows the setting, and is only set under D3DMetal")
    func environmentFollowsTheSetting() throws {
        var builder = EnvironmentBuilder()
        var settings = BottleSettings()
        settings.graphicsBackend = .d3dMetal
        _ = settings.populateBottleManagedLayer(builder: &builder, resolvedBackend: .d3dMetal)
        #expect(builder.resolve().environment["D3DM_MTL4"] == "1")

        // Off has to be written, not omitted: D3DMetal defaults the option on
        // from the OS version and only an explicit value overrides that.
        settings.metal4Enabled = false
        var offBuilder = EnvironmentBuilder()
        _ = settings.populateBottleManagedLayer(builder: &offBuilder, resolvedBackend: .d3dMetal)
        #expect(offBuilder.resolve().environment["D3DM_MTL4"] == "0")

        // Metal 4 is D3DMetal's own backend, so it means nothing under DXVK
        settings.metal4Enabled = true
        settings.graphicsBackend = .dxvk
        var dxvkBuilder = EnvironmentBuilder()
        _ = settings.populateBottleManagedLayer(builder: &dxvkBuilder, resolvedBackend: .dxvk)
        #expect(dxvkBuilder.resolve().environment["D3DM_MTL4"] == nil)
    }
}
