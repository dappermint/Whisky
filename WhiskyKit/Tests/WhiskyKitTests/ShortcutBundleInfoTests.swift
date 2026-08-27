//
//  ShortcutBundleInfoTests.swift
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

/// Tests for the Info.plist a shortcut bundle carries.
///
/// Without a name and an identifier the Dock and the app switcher fall back to
/// the bundle's file name, and LaunchServices cannot tell two shortcuts apart.
final class ShortcutBundleInfoTests: XCTestCase {
    func testPlistNamesTheShortcut() throws {
        let plist = ShortcutCreator.infoPlist(name: "Ready or Not")

        XCTAssertTrue(plist.contains("<key>CFBundleName</key>\n    <string>Ready or Not</string>"), plist)
        XCTAssertTrue(plist.contains("<key>CFBundleDisplayName</key>"), plist)
        XCTAssertTrue(plist.contains("<key>CFBundleIdentifier</key>"), plist)
    }

    func testPlistIsStillValidForANameWithMarkupCharacters() throws {
        let plist = ShortcutCreator.infoPlist(name: "Tom & Jerry <Deluxe>")
        let data = try XCTUnwrap(plist.data(using: .utf8))
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]

        XCTAssertEqual(parsed?["CFBundleName"] as? String, "Tom & Jerry <Deluxe>")
    }

    func testIdentifierIsASlugOfTheName() {
        XCTAssertTrue(
            ShortcutCreator.bundleIdentifier(for: "Ready or Not!").hasSuffix(".shortcut.ready-or-not"),
            ShortcutCreator.bundleIdentifier(for: "Ready or Not!")
        )
        XCTAssertTrue(
            ShortcutCreator.bundleIdentifier(for: "S.T.A.L.K.E.R. 2").hasSuffix(".shortcut.s-t-a-l-k-e-r-2")
        )
    }

    func testIdentifierStaysUsableForANameWithNoLettersAtAll() {
        XCTAssertTrue(ShortcutCreator.bundleIdentifier(for: "!!!").hasSuffix(".shortcut.program"))
    }

    func testDifferentNamesGetDifferentIdentifiers() {
        XCTAssertNotEqual(
            ShortcutCreator.bundleIdentifier(for: "Celeste"),
            ShortcutCreator.bundleIdentifier(for: "Hollow Knight")
        )
    }
}
