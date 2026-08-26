//
//  WhiskyUITests.swift
//  WhiskyUITests
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

import XCTest

final class WhiskyUITests: WhiskyUITestCase {
    func testAppLaunchesAndShowsBottleDetail() throws {
        try requireBottleFixture()
        require(app.buttons["nav.bottleConfiguration"], "bottle nav row", timeout: 8)
        XCTAssertTrue(app.buttons["nav.installedPrograms"].exists)
        XCTAssertTrue(app.buttons["nav.runningProcesses"].exists)
        XCTAssertTrue(app.buttons["nav.gameConfigurations"].exists)
    }

    func testBottomToolbarShowsAllFourActions() throws {
        try requireBottleFixture()
        // BottomBarButtonStyle wraps each button in a new Button, which strips our
        // accessibility identifiers. Look up by visible label instead.
        XCTAssertTrue(app.buttons["Open C: Drive"].exists, "Open C: Drive button missing")
        XCTAssertTrue(app.buttons["Terminal..."].exists, "Terminal button missing")
        XCTAssertTrue(app.buttons["Winetricks..."].exists, "Winetricks button missing")
        XCTAssertTrue(app.buttons["Run..."].exists, "Run button missing")
    }

    func testCreateBottleButtonPresentInToolbar() throws {
        try requireBottleFixture()
        XCTAssertTrue(
            app.buttons.matching(identifier: "toolbar.createBottle").firstMatch.exists,
            "+ toolbar button missing"
        )
    }

    // MARK: - Bottle Configuration

    func testBottleConfigurationSectionsRender() throws {
        try requireBottleFixture()
        openBottleConfiguration()
        // Wine section is the first one expanded by default
        XCTAssertTrue(app.staticTexts["Wine"].exists)
        // Other section headers render as DisclosureTriangles, not StaticTexts
        // (see testControllerAndInputSectionExists), so query them the same way.
        let sectionHeader = app.descendants(matching: .disclosureTriangle)
            .matching(NSPredicate(format: "label CONTAINS 'Launcher Compatibility' OR label CONTAINS 'Controller'"))
            .firstMatch
        XCTAssertTrue(sectionHeader.waitForExistence(timeout: 5), "Expected a collapsible config section header")
    }

    /// Verifies the Controller & Input section exists as a collapsed DisclosureGroup
    /// in Bottle Configuration. The Cmd→Ctrl toggle inside it is verified by source
    /// inspection - SwiftUI doesn't expose collapsed DisclosureGroup contents in
    /// the AX tree, so we can't drive the toggle via XCUITest without expanding it,
    /// which itself requires clicking the chevron at a fragile coordinate.
    func testControllerAndInputSectionExists() throws {
        try requireBottleFixture()
        openBottleConfiguration()
        // The header renders as a DisclosureTriangle with label "Controller & Input",
        // not as a StaticText. Disclosure triangles report as descendant of a window.
        let predicate = NSPredicate(format: "label CONTAINS 'Controller'")
        let disclosure = app.descendants(matching: .disclosureTriangle).matching(predicate)
            .firstMatch
        XCTAssertTrue(
            disclosure.waitForExistence(timeout: 5),
            "Controller & Input section header missing"
        )
    }

    // MARK: - Game Configurations browser
}
