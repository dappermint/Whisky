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
}
