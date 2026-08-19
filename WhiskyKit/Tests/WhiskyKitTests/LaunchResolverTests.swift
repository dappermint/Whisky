//
//  LaunchResolverTests.swift
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

@Suite("GameProfile Layer Tests")
struct GameProfileLayerTests {
    @Test("Game profile beats launcher defaults, loses to user layers")
    func layerOrdering() {
        var builder = EnvironmentBuilder()

        builder.set("SHARED", "launcher", layer: .launcherManaged)
        builder.set("SHARED", "gamedb", layer: .gameProfile)
        builder.set("USER_WINS", "gamedb", layer: .gameProfile)
        builder.set("USER_WINS", "bottle-user", layer: .bottleUser)
        builder.set("PROGRAM_WINS", "gamedb", layer: .gameProfile)
        builder.set("PROGRAM_WINS", "program", layer: .programUser)

        let (resolved, _) = builder.resolve()

        #expect(resolved["SHARED"] == "gamedb")
        #expect(resolved["USER_WINS"] == "bottle-user")
        #expect(resolved["PROGRAM_WINS"] == "program")
    }

    @Test("constructWineEnvironment carries the game profile environment")
    @MainActor func constructCarriesProfile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)

        let env = Wine.constructWineEnvironment(
            for: bottle,
            environment: ["CONTESTED": "program-user"],
            gameProfileEnvironment: [
                "GAME_PROFILE_ONLY": "1",
                "CONTESTED": "gamedb",
                "not a valid key!": "dropped"
            ]
        )

        #expect(env["GAME_PROFILE_ONLY"] == "1")
        #expect(env["CONTESTED"] == "program-user")
        #expect(env["not a valid key!"] == nil)
    }

    @Test("A WINEDEBUG the user typed survives the diagnostic preset")
    @MainActor func userWinedebugBeatsPreset() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)
        var settings = ProgramSettings()
        settings.activeWineDebugPreset = .dllLoad

        let withUserValue = Wine.constructWineEnvironment(
            for: bottle,
            environment: ["WINEDEBUG": "+file"],
            programSettings: settings
        )
        #expect(withUserValue["WINEDEBUG"] == "+file")

        let presetOnly = Wine.constructWineEnvironment(for: bottle, programSettings: settings)
        #expect(presetOnly["WINEDEBUG"] == WineDebugPreset.dllLoad.winedebugValue)
    }
}

@Suite("LaunchResolver Tests")
struct LaunchResolverTests {
    private func fixtureEntries() throws -> [GameDBEntry] {
        let json = """
        {
            "version": 1,
            "entries": [
                {
                    "id": "casualties-unknown-demo",
                    "title": "Casualties: Unknown Demo",
                    "rating": "unverified",
                    "steamAppId": 4576510,
                    "exeNames": ["casualties.exe"],
                    "variants": [
                        {
                            "id": "recommended",
                            "label": "Recommended",
                            "isDefault": true,
                            "settings": {
                                "graphicsBackend": "dxvk",
                                "dxvkAsync": true,
                                "forceD3D11": false,
                                "performancePreset": "unity"
                            },
                            "environmentVariables": {
                                "DXVK_FRAME_RATE": "120"
                            },
                            "dllOverrides": []
                        }
                    ]
                }
            ]
        }
        """
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appending(path: "gamedb.json")
        try Data(json.utf8).write(to: url)
        return try GameDBLoader.loadEntries(from: url)
    }

    @Test("Plans from a GameDB match by App ID")
    func plansFromMatch() throws {
        let plan = try LaunchResolver.plan(steamAppId: 4_576_510, entries: fixtureEntries())

        #expect(plan.overrides.graphicsBackend == .dxvk)
        #expect(plan.overrides.dxvkAsync == true)
        #expect(plan.overrides.forceD3D11 == false)
        #expect(plan.overrides.performancePreset == .unity)
        #expect(plan.gameProfileEnvironment["DXVK_FRAME_RATE"] == "120")
        #expect(plan.provenance.count == 1)
        #expect(plan.provenance[0].contains("Casualties: Unknown Demo"))
    }

    @Test("User overrides win over GameDB fields")
    func userOverridesWin() throws {
        var user = ProgramOverrides()
        user.graphicsBackend = .dxmt
        user.dxvkAsync = false

        let plan = try LaunchResolver.plan(
            steamAppId: 4_576_510, userOverrides: user, entries: fixtureEntries()
        )

        #expect(plan.overrides.graphicsBackend == .dxmt)
        #expect(plan.overrides.dxvkAsync == false)
        // Fields the user left unset still come from the variant
        #expect(plan.overrides.performancePreset == .unity)
    }

    @Test("No match passes user overrides through untouched")
    func noMatchPassthrough() throws {
        var user = ProgramOverrides()
        user.graphicsBackend = .wined3d

        let plan = try LaunchResolver.plan(
            steamAppId: 1, userOverrides: user, entries: fixtureEntries()
        )

        #expect(plan.overrides.graphicsBackend == .wined3d)
        #expect(plan.gameProfileEnvironment.isEmpty)
        #expect(plan.provenance.isEmpty)
    }

    @Test("No match and no user overrides yields an empty plan")
    func emptyPlan() throws {
        let plan = try LaunchResolver.plan(steamAppId: 1, entries: fixtureEntries())

        #expect(plan.overrides.isEmpty)
        #expect(plan.gameProfileEnvironment.isEmpty)
    }

    @Test("A direct run plans from its exe name, same as through Steam")
    func directRunPlansFromExeName() throws {
        let exe = URL(fileURLWithPath: "/tmp/bottle/drive_c/Games/CU/casualties.exe")
        let plan = try LaunchResolver.plan(forProgramAt: exe, entries: fixtureEntries())

        #expect(plan.overrides.graphicsBackend == .dxvk)
        #expect(plan.gameProfileEnvironment["DXVK_FRAME_RATE"] == "120")
        #expect(plan.provenance.count == 1)
    }

    @Test("A direct run's user overrides still win")
    func directRunUserOverridesWin() throws {
        var user = ProgramOverrides()
        user.graphicsBackend = .dxmt

        let exe = URL(fileURLWithPath: "/tmp/bottle/drive_c/Games/CU/casualties.exe")
        let plan = try LaunchResolver.plan(forProgramAt: exe, userOverrides: user, entries: fixtureEntries())

        #expect(plan.overrides.graphicsBackend == .dxmt)
        #expect(plan.overrides.performancePreset == .unity)
    }

    @Test("An unknown exe plans nothing, so a miss costs nothing")
    func unknownExePlansNothing() throws {
        let exe = URL(fileURLWithPath: "/tmp/bottle/drive_c/Tools/editor.exe")
        let plan = try LaunchResolver.plan(forProgramAt: exe, entries: fixtureEntries())

        #expect(plan.overrides.isEmpty)
        #expect(plan.gameProfileEnvironment.isEmpty)
        #expect(plan.provenance.isEmpty)
    }
}
