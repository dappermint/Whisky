//
//  DockIdentityTests.swift
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

import AppKit
@testable import WhiskyKit
import XCTest

/// Tests for the name and icon a Windows program shows in the Dock.
///
/// The name becomes a file name, so anything that would change the meaning of
/// a path has to be gone before it is used, and a launch must still work when
/// there is no usable name at all.
final class DockIdentityTests: XCTestCase {
    func testSanitizedRemovesPathSeparators() {
        XCTAssertEqual(DockIdentity.sanitized("S.T.A.L.K.E.R.: Clear Sky"), "S.T.A.L.K.E.R.  Clear Sky")
        XCTAssertEqual(DockIdentity.sanitized("../../etc/passwd"), ".. .. etc passwd")
        XCTAssertEqual(DockIdentity.sanitized("Half\u{0000}Life"), "Half Life")
    }

    func testSanitizedRejectsNamesThatWouldNotBeAFile() {
        XCTAssertNil(DockIdentity.sanitized(""))
        XCTAssertNil(DockIdentity.sanitized("   "))
        XCTAssertNil(DockIdentity.sanitized("."))
        XCTAssertNil(DockIdentity.sanitized(".."))
        XCTAssertNil(DockIdentity.sanitized("/"))
    }

    func testSanitizedCapsLength() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(DockIdentity.sanitized(long)?.count, 60)
    }

    func testDisplayNamePrefersTheGameTitle() {
        let url = URL(fileURLWithPath: "/Games/RoN/ReadyOrNot-Win64-Shipping.exe")
        XCTAssertEqual(DockIdentity.displayName(for: url, title: "Ready or Not"), "Ready or Not")
    }

    func testDisplayNameFallsBackToTheExeNameWithoutItsExtension() {
        let url = URL(fileURLWithPath: "/Games/Celeste/Celeste.exe")
        XCTAssertEqual(DockIdentity.displayName(for: url, title: nil), "Celeste")
    }

    func testDisplayNameFallsBackWhenTheTitleIsUnusable() {
        let url = URL(fileURLWithPath: "/Games/Celeste/Celeste.exe")
        XCTAssertEqual(DockIdentity.displayName(for: url, title: "  "), "Celeste")
    }

    func testEnvironmentCarriesTheLoaderPathsAndName() {
        let environment = DockIdentity.environment(displayName: "Celeste", iconFile: nil, runtime: nil)

        XCTAssertEqual(environment["WINE_APP_DISPLAY_NAME"], "Celeste")
        XCTAssertEqual(
            environment["WINEDLLPATH"],
            WhiskyWineInstaller.dllFolder(for: nil).path(percentEncoded: false)
        )
        XCTAssertTrue(environment["WINESERVER"]?.hasSuffix("/bin/wineserver") == true)
        // No composed icon means Wine keeps using the exe's own resource.
        XCTAssertNil(environment["WINE_APP_ICON_PATH"])
    }

    func testEnvironmentCarriesTheIconWhenThereIsOne() {
        let icon = URL(fileURLWithPath: "/tmp/whisky-test-icon.png")
        let environment = DockIdentity.environment(displayName: "Celeste", iconFile: icon, runtime: nil)

        XCTAssertEqual(environment["WINE_APP_ICON_PATH"], "/tmp/whisky-test-icon.png")
    }

    func testLoaderAliasIsNilWhenTheRuntimeIsNotInstalled() {
        XCTAssertNil(
            DockIdentity.loaderAlias(displayName: "Celeste", runtime: "whisky-not-installed-0.0.0")
        )
    }

    func testDllFolderSitsUnderTheRuntimeItNames() {
        let path = WhiskyWineInstaller.dllFolder(for: "whisky-arm64-5.0.0").path(percentEncoded: false)
        XCTAssertTrue(path.hasSuffix("/Runtimes/whisky-arm64-5.0.0/Wine/lib/wine"), path)
    }
}
