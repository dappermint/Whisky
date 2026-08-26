//
//  DLLOverrideTests.swift
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

@testable import WhiskyKit
import XCTest

final class DLLOverrideTests: XCTestCase {
    // MARK: - DLL Override Mode

    func testDLLOverrideModeRawValues() {
        XCTAssertEqual(DLLOverrideMode.builtin.rawValue, "b")
        XCTAssertEqual(DLLOverrideMode.native.rawValue, "n")
        XCTAssertEqual(DLLOverrideMode.nativeThenBuiltin.rawValue, "n,b")
        XCTAssertEqual(DLLOverrideMode.builtinThenNative.rawValue, "b,n")
        XCTAssertEqual(DLLOverrideMode.disabled.rawValue, "")
    }

    // MARK: - DLL Override Entry Codable

    func testDLLOverrideEntryCodableRoundTrip() throws {
        let entry = DLLOverrideEntry(dllName: "dxgi", mode: .nativeThenBuiltin)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(entry)
        let decoded = try PropertyListDecoder().decode(DLLOverrideEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    // MARK: - DLL Override Resolver

    func testManagedOnlyResolvesToCorrectString() {
        let resolver = DLLOverrideResolver(
            managed: [
                (entry: DLLOverrideEntry(dllName: "dxgi", mode: .nativeThenBuiltin), source: .dxvk),
                (entry: DLLOverrideEntry(dllName: "d3d11", mode: .nativeThenBuiltin), source: .dxvk)
            ],
            bottleCustom: [],
            programCustom: []
        )
        let result = resolver.resolve()
        XCTAssertEqual(result.overrides, "d3d11=n,b;dxgi=n,b")
    }

    func testBottleCustomOverridesManaged() {
        let resolver = DLLOverrideResolver(
            managed: [
                (entry: DLLOverrideEntry(dllName: "dxgi", mode: .nativeThenBuiltin), source: .dxvk)
            ],
            bottleCustom: [
                DLLOverrideEntry(dllName: "dxgi", mode: .builtin)
            ],
            programCustom: []
        )
        let result = resolver.resolve()
        XCTAssertEqual(result.overrides, "dxgi=b")
    }

    func testProgramCustomOverridesAll() {
        let resolver = DLLOverrideResolver(
            managed: [
                (entry: DLLOverrideEntry(dllName: "dxgi", mode: .nativeThenBuiltin), source: .dxvk)
            ],
            bottleCustom: [],
            programCustom: [
                DLLOverrideEntry(dllName: "dxgi", mode: .disabled)
            ]
        )
        let result = resolver.resolve()
        XCTAssertEqual(result.overrides, "dxgi=")
    }

    func testEmptyResolverProducesEmptyString() {
        let resolver = DLLOverrideResolver(managed: [], bottleCustom: [], programCustom: [])
        let result = resolver.resolve()
        XCTAssertEqual(result.overrides, "")
    }

    func testMixedSourcesCompose() {
        let resolver = DLLOverrideResolver(
            managed: [
                (entry: DLLOverrideEntry(dllName: "dxgi", mode: .nativeThenBuiltin), source: .dxvk)
            ],
            bottleCustom: [
                DLLOverrideEntry(dllName: "vcrun", mode: .native)
            ],
            programCustom: []
        )
        let result = resolver.resolve()
        XCTAssertEqual(result.overrides, "dxgi=n,b;vcrun=n")
    }

    // MARK: - DLL Override Warnings

    func testDXVKWarningWhenManagedOverridden() {
        let resolver = DLLOverrideResolver(
            managed: [
                (entry: DLLOverrideEntry(dllName: "dxgi", mode: .nativeThenBuiltin), source: .dxvk)
            ],
            bottleCustom: [
                DLLOverrideEntry(dllName: "dxgi", mode: .builtin)
            ],
            programCustom: []
        )
        let result = resolver.resolve()
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings.first?.dllName, "dxgi")
        XCTAssertEqual(result.warnings.first?.overriddenSource, .dxvk)
    }

    func testNoWarningWhenNoConflict() {
        let resolver = DLLOverrideResolver(
            managed: [
                (entry: DLLOverrideEntry(dllName: "dxgi", mode: .nativeThenBuiltin), source: .dxvk)
            ],
            bottleCustom: [
                DLLOverrideEntry(dllName: "vcrun", mode: .native)
            ],
            programCustom: []
        )
        let result = resolver.resolve()
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - DXVK Preset

    func testDXVKPresetReturnsCorrectEntries() {
        let preset = DLLOverrideResolver.dxvkPreset
        let modesByName = Dictionary(uniqueKeysWithValues: preset.map { ($0.dllName, $0.mode) })
        XCTAssertEqual(modesByName, [
            "dxgi": .nativeThenBuiltin,
            "d3d9": .nativeThenBuiltin,
            "d3d10core": .nativeThenBuiltin,
            "d3d11": .nativeThenBuiltin,
            // DXVK has no d3d12; off rather than falling through to D3DMetal
            "d3d12": .disabled
        ])
    }

    // MARK: - DXMT Preset

    func testDXMTPresetReturnsCorrectEntries() {
        // The D3D translation trio loads native from the prefix; winemetal must
        // stay builtin because its unixlib half only binds for builtin loads.
        let preset = DLLOverrideResolver.dxmtPreset
        let modesByName = Dictionary(uniqueKeysWithValues: preset.map { ($0.dllName, $0.mode) })
        XCTAssertEqual(modesByName, [
            "dxgi": .nativeThenBuiltin,
            "d3d10core": .nativeThenBuiltin,
            "d3d11": .nativeThenBuiltin,
            "winemetal": .builtin,
            "d3d12": .disabled
        ])
    }

    func testDXMTPresetResolvesToPinnedOverrideString() {
        let resolver = DLLOverrideResolver(
            managed: DLLOverrideResolver.dxmtPreset.map { (entry: $0, source: .dxmt) },
            bottleCustom: [],
            programCustom: []
        )
        let result = resolver.resolve()
        XCTAssertEqual(result.overrides, "d3d10core=n,b;d3d11=n,b;d3d12=;dxgi=n,b;winemetal=b")
    }

    func testDXMTWarningWhenManagedOverridden() {
        let resolver = DLLOverrideResolver(
            managed: [
                (entry: DLLOverrideEntry(dllName: "d3d11", mode: .nativeThenBuiltin), source: .dxmt)
            ],
            bottleCustom: [
                DLLOverrideEntry(dllName: "d3d11", mode: .builtin)
            ],
            programCustom: []
        )
        let result = resolver.resolve()
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings.first?.overriddenSource, .dxmt)
        XCTAssertTrue(result.warnings.first?.message.contains("DXMT") == true)
    }

    // MARK: - d3d12 is never left to fall through

    func testTranslationPresetsTurnD3D12Off() {
        // Neither DXVK nor DXMT ships a d3d12. Leaving the name unmentioned let
        // it resolve to the builtin, which is D3DMetal, and a DX12 game took its
        // adapter from one implementation into the other and jumped to null.
        for (name, preset) in [
            ("DXVK", DLLOverrideResolver.dxvkPreset),
            ("DXMT", DLLOverrideResolver.dxmtPreset)
        ] {
            let entry = preset.first { $0.dllName == "d3d12" }
            XCTAssertNotNil(entry, "\(name) preset must say what happens to d3d12")
            XCTAssertEqual(entry?.mode, .disabled, "\(name) must turn d3d12 off, not leave it builtin")
        }
    }

    func testD3DMetalResetRestoresD3D12() {
        // A program that overrides a DXVK bottle back to D3DMetal has to get
        // real DX12, so the reset union must put d3d12 back to builtin.
        let reset = Wine.translationDLLResetEntries
        let entry = reset.first { $0.dllName == "d3d12" }
        XCTAssertEqual(entry?.mode, .builtin, "resetting to a builtin backend must re-enable d3d12")
    }

    func testDXVKBottleRendersD3D12Disabled() {
        let resolver = DLLOverrideResolver(
            managed: DLLOverrideResolver.dxvkPreset.map { ($0, DLLOverrideSource.dxvk) },
            bottleCustom: [],
            programCustom: []
        )
        XCTAssertTrue(resolver.resolve().overrides.contains("d3d12="))
    }
}
