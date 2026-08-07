//
//  DLLOverrideRegistryTests.swift
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

final class DLLOverrideRegistryTests: XCTestCase {
    // MARK: - Scope keys

    func testBottleScopeUsesPrefixDefaultKey() {
        XCTAssertEqual(
            Wine.DLLOverrideScope.bottle.registryKey,
            #"HKCU\Software\Wine\DllOverrides"#
        )
    }

    func testProgramScopeIsKeyedOnTheExecutable() {
        XCTAssertEqual(
            Wine.DLLOverrideScope.program("steam.exe").registryKey,
            #"HKCU\Software\Wine\AppDefaults\steam.exe\DllOverrides"#
        )
    }

    /// Two executables must land in different keys, which is the whole point:
    /// an environment variable could not separate a launcher from the games it
    /// spawns.
    func testProgramScopesDoNotCollide() {
        XCTAssertNotEqual(
            Wine.DLLOverrideScope.program("steam.exe").registryKey,
            Wine.DLLOverrideScope.program("steamwebhelper.exe").registryKey
        )
    }

    // MARK: - Parsing

    func testParsesDXVKPreset() {
        let parsed = Wine.parseDLLOverrides("d3d10core=n,b;d3d11=n,b;d3d9=n,b;dxgi=n,b")
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(parsed["d3d11"], "n,b")
        XCTAssertEqual(parsed["dxgi"], "n,b")
    }

    func testParsesBuiltinOnlyModes() {
        let parsed = Wine.parseDLLOverrides("dxgi=b;winemetal=b")
        XCTAssertEqual(parsed["dxgi"], "b")
        XCTAssertEqual(parsed["winemetal"], "b")
    }

    /// `dll=` with no value is how a DLL is disabled, in both the variable and
    /// the registry, so it has to survive the round trip rather than be dropped.
    func testKeepsDisabledOverrides() {
        let parsed = Wine.parseDLLOverrides("mscoree=;mshtml=")
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed["mscoree"], "")
    }

    func testEmptyStringYieldsNoOverrides() {
        XCTAssertTrue(Wine.parseDLLOverrides("").isEmpty)
    }

    func testIgnoresEmptyClausesAndWhitespace() {
        let parsed = Wine.parseDLLOverrides(" d3d11=n,b ;; dxgi=b ;")
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed["d3d11"], "n,b")
        XCTAssertEqual(parsed["dxgi"], "b")
    }

    func testLastClauseWinsForARepeatedDLL() {
        let parsed = Wine.parseDLLOverrides("d3d11=n,b;d3d11=b")
        XCTAssertEqual(parsed["d3d11"], "b")
    }

    // MARK: - Launcher helpers

    /// The reason this exists: steam draws its whole client in the webhelper,
    /// and AppDefaults is per executable with no inheritance, so an override on
    /// steam.exe alone leaves the window blank.
    func testSteamCarriesItsHelpersAlong() {
        let helpers = Wine.helperExecutables(for: URL(filePath: "/B/Steam/steam.exe"))
        XCTAssertTrue(helpers.contains("steamwebhelper.exe"))
    }

    func testAGameIsNotALauncherAndCarriesNothing() {
        let url = URL(filePath: "/B/Steam/steamapps/common/Some Game/game.exe")
        XCTAssertTrue(Wine.helperExecutables(for: url).isEmpty)
    }

    func testUnknownExecutableCarriesNothing() {
        XCTAssertTrue(Wine.helperExecutables(for: URL(filePath: "/B/thing.exe")).isEmpty)
    }

    /// A helper must never be listed as its own helper, or a launch would write
    /// the same scope twice.
    func testNoLauncherListsItself() {
        for launcher in LauncherType.allCases {
            XCTAssertFalse(
                launcher.helperExecutables.contains { $0.lowercased().contains("steam.exe") },
                "\(launcher) lists a launcher executable as a helper"
            )
        }
    }

    // MARK: - reg query output

    func testParsesRegQueryOutput() {
        let output = """
        HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides
            d3d11    REG_SZ    n,b
            dxgi    REG_SZ    n,b
        """
        let parsed = Wine.parseRegistryQueryOutput(output)
        XCTAssertEqual(parsed, ["d3d11": "n,b", "dxgi": "n,b"])
    }

    /// A disabled override has no value column at all, and must come back as
    /// an empty string rather than being dropped.
    func testParsesValuelessEntryAsDisabled() {
        let parsed = Wine.parseRegistryQueryOutput("    mscoree    REG_SZ")
        XCTAssertEqual(parsed, ["mscoree": ""])
    }

    func testIgnoresHeaderAndBlankLines() {
        let output = """

        HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\steam.exe\\DllOverrides

            d3d11    REG_SZ    n,b

        """
        XCTAssertEqual(Wine.parseRegistryQueryOutput(output), ["d3d11": "n,b"])
    }

    func testEmptyQueryOutputYieldsNothing() {
        XCTAssertTrue(Wine.parseRegistryQueryOutput("").isEmpty)
    }

    // MARK: - Sync plan

    func testWritesEverythingWhenTheKeyIsEmpty() {
        let plan = Wine.syncPlan(existing: [:], wanted: ["d3d11": "n,b", "dxgi": "n,b"])
        XCTAssertEqual(plan.writes.map(\.dll), ["d3d11", "dxgi"])
        XCTAssertTrue(plan.deletes.isEmpty)
        XCTAssertFalse(plan.isEmpty)
    }

    /// Launches are frequent and the overrides rarely change, so an unchanged
    /// key must produce no wine processes at all.
    func testNoWorkWhenAlreadyCorrect() {
        let same = ["d3d11": "n,b", "dxgi": "n,b"]
        XCTAssertTrue(Wine.syncPlan(existing: same, wanted: same).isEmpty)
    }

    func testWritesOnlyWhatChanged() {
        let plan = Wine.syncPlan(
            existing: ["d3d11": "n,b", "dxgi": "n,b"],
            wanted: ["d3d11": "n,b", "dxgi": "b"]
        )
        XCTAssertEqual(plan.writes.map(\.dll), ["dxgi"])
        XCTAssertEqual(plan.writes.map(\.mode), ["b"])
        XCTAssertTrue(plan.deletes.isEmpty)
    }

    /// Switching DXVK to DXMT: DXMT's preset does not mention d3d9, so DXVK's
    /// entry has to be removed rather than left behind.
    func testPrunesEntriesTheNewBackendDoesNotWant() {
        let plan = Wine.syncPlan(
            existing: ["d3d11": "n,b", "d3d9": "n,b", "d3d10core": "n,b", "dxgi": "n,b"],
            wanted: ["d3d11": "n,b", "d3d10core": "n,b", "dxgi": "n,b", "winemetal": "b"]
        )
        XCTAssertEqual(plan.deletes, ["d3d9"])
        XCTAssertEqual(plan.writes.map(\.dll), ["winemetal"])
    }

    func testClearingWantedRemovesEverything() {
        let plan = Wine.syncPlan(existing: ["d3d11": "n,b", "dxgi": "n,b"], wanted: [:])
        XCTAssertEqual(plan.deletes, ["d3d11", "dxgi"])
        XCTAssertTrue(plan.writes.isEmpty)
    }

    func testPlanIsDeterministicallyOrdered() {
        let plan = Wine.syncPlan(
            existing: ["zzz": "b", "aaa": "b"],
            wanted: ["dxgi": "n,b", "d3d11": "n,b", "d3d9": "n,b"]
        )
        XCTAssertEqual(plan.writes.map(\.dll), ["d3d11", "d3d9", "dxgi"])
        XCTAssertEqual(plan.deletes, ["aaa", "zzz"])
    }
}
