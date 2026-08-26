//
//  ManagedPresetTests.swift
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

final class ManagedPresetTests: XCTestCase {
    func testDXVKBackendContributesTheDXVKPreset() {
        let preset = DLLOverrideResolver.managedPreset(for: .dxvk)
        XCTAssertEqual(preset.map(\.dllName).sorted(), ["d3d10core", "d3d11", "d3d12", "d3d9", "dxgi"])
    }

    /// The case the config section used to miss entirely: a DXMT bottle applies
    /// five overrides at launch and the UI listed none of them.
    func testDXMTBackendContributesTheDXMTPreset() {
        let preset = DLLOverrideResolver.managedPreset(for: .dxmt)
        XCTAssertEqual(preset.map(\.dllName).sorted(), ["d3d10core", "d3d11", "d3d12", "dxgi", "winemetal"])
    }

    /// D3DMetal and WineD3D both run on Wine's builtin D3D and pick between
    /// themselves with WINED3DMETAL, so neither overrides a DLL.
    func testBuiltinBackendsContributeNothing() {
        XCTAssertTrue(DLLOverrideResolver.managedPreset(for: .d3dMetal).isEmpty)
        XCTAssertTrue(DLLOverrideResolver.managedPreset(for: .wined3d).isEmpty)
    }

    /// `.recommended` is not a backend, it is a deferral. Callers resolve it
    /// first; answering with a preset here would attribute one bottle's
    /// overrides to another machine's heuristics.
    func testRecommendedContributesNothingUnresolved() {
        XCTAssertTrue(DLLOverrideResolver.managedPreset(for: .recommended).isEmpty)
    }

    func testPresetMatchesWhatTheResolverApplies() {
        for backend in [GraphicsBackend.dxvk, .dxmt] {
            let resolver = DLLOverrideResolver(
                managed: DLLOverrideResolver.managedPreset(for: backend).map { ($0, .dxvk) },
                bottleCustom: [],
                programCustom: []
            )
            let (overrides, _) = resolver.resolve()
            for entry in DLLOverrideResolver.managedPreset(for: backend) {
                XCTAssertTrue(
                    overrides.contains("\(entry.dllName)=\(entry.mode.rawValue)"),
                    "\(backend.displayName) preset lost \(entry.dllName) through the resolver"
                )
            }
        }
    }
}
