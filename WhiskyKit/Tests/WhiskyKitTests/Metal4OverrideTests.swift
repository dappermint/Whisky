//
//  Metal4OverrideTests.swift
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

@Suite("Metal 4 Override Tests")
struct Metal4OverrideTests {
    /// Resolves the environment a program gets from a D3DMetal bottle, which is
    /// where `D3DM_MTL4` is set, plus its own overrides on top.
    private func resolved(_ overrides: ProgramOverrides) -> [String: String] {
        var settings = BottleSettings()
        settings.graphicsBackend = .d3dMetal
        var builder = EnvironmentBuilder()
        var dllResolver = DLLOverrideResolver(managed: [], bottleCustom: [], programCustom: [])

        _ = settings.populateBottleManagedLayer(builder: &builder)
        Wine.applyProgramOverrides(overrides, builder: &builder, dllResolver: &dllResolver)

        return builder.resolve().environment
    }

    @Test("A bottle on D3DMetal enables Metal 4")
    func bottleEnablesMetal4() {
        #expect(resolved(ProgramOverrides())["D3DM_MTL4"] == "1")
    }

    /// The whole point of the override: D3DMetal only takes the Metal 4 path
    /// for D3D12 devices, so one D3D12 title whose renderer wedges on a fence
    /// has to be able to drop back while the rest of the bottle keeps it.
    /// Dropping back means writing `0`; removing the variable leaves the option
    /// on, because it defaults from the OS version.
    @Test("One program can turn Metal 4 off without the bottle losing it")
    func programCanOptOut() {
        var overrides = ProgramOverrides()
        overrides.metal4Enabled = false

        #expect(resolved(overrides)["D3DM_MTL4"] == "0")
    }

    @Test("Turning it on for a program is not undone by the override")
    func programCanOptIn() {
        var overrides = ProgramOverrides()
        overrides.metal4Enabled = true

        #expect(resolved(overrides)["D3DM_MTL4"] == "1")
    }

    @Test("Saying nothing inherits the bottle")
    func inheritsWhenUnset() {
        #expect(ProgramOverrides().metal4Enabled == nil)
        #expect(ProgramOverrides().isEmpty)
    }

    @Test("The setting survives a round trip through a settings file")
    func encodesAndDecodes() throws {
        var overrides = ProgramOverrides()
        overrides.metal4Enabled = false

        let data = try PropertyListEncoder().encode(overrides)
        let decoded = try PropertyListDecoder().decode(ProgramOverrides.self, from: data)

        #expect(decoded.metal4Enabled == false)
    }

    // MARK: - A backend override re-enabling D3DMetal

    /// Resolves the environment on a DXVK bottle whose program overrides its
    /// backend to D3DMetal, which is the shape every GameDB entry that
    /// recommends D3DMetal produces inside a DXVK bottle. The bottle layer
    /// never wrote `D3DM_MTL4` there, so the override has to.
    private func resolvedOnDXVKBottle(
        _ overrides: ProgramOverrides, bottleMetal4: Bool
    ) -> [String: String] {
        var settings = BottleSettings()
        settings.graphicsBackend = .dxvk
        settings.metal4Enabled = bottleMetal4
        var builder = EnvironmentBuilder()
        var dllResolver = DLLOverrideResolver(managed: [], bottleCustom: [], programCustom: [])

        _ = settings.populateBottleManagedLayer(builder: &builder)
        Wine.applyProgramOverrides(
            overrides, metal4Enabled: bottleMetal4, builder: &builder, dllResolver: &dllResolver
        )

        return builder.resolve().environment
    }

    private var d3dMetalOverride: ProgramOverrides {
        var overrides = ProgramOverrides()
        overrides.graphicsBackend = .d3dMetal
        return overrides
    }

    @Test("An override onto D3DMetal keeps the bottle's Metal 4 off")
    func overrideOntoD3DMetalKeepsBottleOff() {
        #expect(resolvedOnDXVKBottle(d3dMetalOverride, bottleMetal4: false)["D3DM_MTL4"] == "0")
    }

    @Test("An override onto D3DMetal keeps the bottle's Metal 4 on")
    func overrideOntoD3DMetalKeepsBottleOn() {
        #expect(resolvedOnDXVKBottle(d3dMetalOverride, bottleMetal4: true)["D3DM_MTL4"] == "1")
    }

    @Test("The program's own Metal 4 choice beats the bottle's during the override")
    func programChoiceBeatsBottleDuringOverride() {
        var overrides = d3dMetalOverride
        overrides.metal4Enabled = true

        #expect(resolvedOnDXVKBottle(overrides, bottleMetal4: false)["D3DM_MTL4"] == "1")
    }

    // MARK: - The game this was found on

    @Test("Helldivers 2 ships with Metal 4 turned off")
    func helldiversProfileDisablesMetal4() throws {
        let entries = GameDBLoader.loadDefaults()
        let entry = try #require(entries.first { $0.steamAppId == 553_850 })
        let variant = try #require(entry.variants.first { $0.isDefault == true })

        #expect(variant.settings.graphicsBackend == .d3dMetal)
        #expect(variant.environmentVariables?["D3DM_MTL4"] == "0")
    }

    /// The App ID is the identifier the client hands the compatibility tool, so
    /// this is the resolution a game launched from Steam actually gets.
    @Test("The profile reaches a launch made by App ID")
    func planCarriesTheProfileEnvironment() {
        let plan = LaunchResolver.plan(steamAppId: 553_850, exeName: "helldivers2.exe")

        #expect(plan.gameProfileEnvironment["D3DM_MTL4"] == "0")
    }
}
