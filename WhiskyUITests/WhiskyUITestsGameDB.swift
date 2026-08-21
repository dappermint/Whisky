//
//  WhiskyUITestsGameDB.swift
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

/// The GameDB browser, split out to keep each file readable.
final class WhiskyUITestsGameDB: WhiskyUITestCase {
    func testGameDBBrowserShowsEntries() throws {
        try requireBottleFixture()
        openGameConfigurations()
        // We bundle 80+ entries; assert at least one row renders.
        let firstRow = app.outlines["gamedb.list"].outlineRows.firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 5),
            "GameDB browser is empty - bundled entries failed to load"
        )
    }

    /// Open the Celeste GameDB detail view. We use a deterministic row id rather
    /// than walking outline rows because OutlineRow descendants aren't reliably
    /// hittable on macOS - the actual click target is the inner Button.
    private func openCelesteDetail() {
        let row = require(
            app.buttons["gamedb.row.celeste"],
            "Celeste row button",
            timeout: 5
        )
        row.click()
    }

    func testGameDBSearchFiltersEntries() throws {
        try requireBottleFixture()
        openGameConfigurations()
        let searchField: XCUIElement = {
            if app.searchFields.firstMatch.exists { return app.searchFields.firstMatch }
            return app.textFields.firstMatch
        }()
        require(searchField, "GameDB search field", timeout: 5)
        searchField.click()
        searchField.typeText("celeste")
        // The Celeste row should still be present after filtering;
        // most other rows should be filtered out.
        XCTAssertTrue(
            app.buttons["gamedb.row.celeste"].waitForExistence(timeout: 5),
            "Search for 'celeste' did not surface the Celeste row"
        )
        XCTAssertFalse(
            app.buttons["gamedb.row.aoe2-de"].exists,
            "Search filter should hide unrelated entries"
        )
    }

    func testGameDBDetailViewRendersForCeleste() throws {
        try requireBottleFixture()
        openGameConfigurations()
        openCelesteDetail()
        require(
            app.buttons["gamedb.detail.applyButton"],
            "Apply button on detail view",
            timeout: 5
        )
    }

    func testApplyConfigPreviewSheetCancels() throws {
        try requireBottleFixture()
        openGameConfigurations()
        openCelesteDetail()

        let applyButton = require(
            app.buttons["gamedb.detail.applyButton"],
            "Apply button",
            timeout: 5
        )
        applyButton.click()

        let cancelButton = require(
            app.buttons["gamedb.preview.cancelButton"],
            "preview Cancel button",
            timeout: 5
        )
        XCTAssertTrue(
            app.buttons["gamedb.preview.applyButton"].exists,
            "preview Apply Configuration button missing"
        )
        cancelButton.click()

        // Sheet should dismiss
        XCTAssertFalse(
            app.buttons["gamedb.preview.cancelButton"].waitForExistence(timeout: 2),
            "Preview sheet failed to dismiss after Cancel"
        )
    }

    // MARK: - Localization regression

    /// Bottle Configuration view should not leak any raw localization keys.
    /// This is the highest-leverage test - catches the entire class of regressions
    /// that manual smoke testing kept finding (config.title.graphics, status.duplicating.*,
    /// bottle.subtitle.autoBackend, etc.).
    func testNoRawKeysInBottleConfiguration() throws {
        try requireBottleFixture()
        openBottleConfiguration()
        let leaks = rawKeyLeaks()
        XCTAssertTrue(
            leaks.isEmpty,
            "Bottle Configuration leaked raw localization keys: \(leaks)"
        )
    }

    /// Same check, but for the GameDB browser.
    func testNoRawKeysInGameConfigurations() throws {
        try requireBottleFixture()
        openGameConfigurations()
        let leaks = rawKeyLeaks()
        XCTAssertTrue(
            leaks.isEmpty,
            "Game Configurations leaked raw localization keys: \(leaks)"
        )
    }

    /// Same check, but for the GameDB detail view.
    func testNoRawKeysInGameDetail() throws {
        try requireBottleFixture()
        openGameConfigurations()
        openCelesteDetail()
        require(app.buttons["gamedb.detail.applyButton"], "detail view loaded", timeout: 5)
        let leaks = rawKeyLeaks()
        XCTAssertTrue(
            leaks.isEmpty,
            "GameDB detail view leaked raw localization keys: \(leaks)"
        )
    }

    /// Same check, but for the apply-config preview sheet (the overlay where the diff
    /// shows). Verifies sheet content is fully localized.
    func testNoRawKeysInApplyPreviewSheet() throws {
        try requireBottleFixture()
        openGameConfigurations()
        openCelesteDetail()
        require(app.buttons["gamedb.detail.applyButton"], "detail view", timeout: 5).click()
        require(app.buttons["gamedb.preview.cancelButton"], "preview sheet", timeout: 5)

        let leaks = rawKeyLeaks()
        XCTAssertTrue(
            leaks.isEmpty,
            "Apply preview sheet leaked raw localization keys: \(leaks)"
        )

        app.buttons["gamedb.preview.cancelButton"].click()
    }

    // MARK: - Create-bottle sheet

    func testCreateBottleSheetOpensAndCancels() {
        // macOS toolbar buttons render as paired wrapper+inner buttons sharing the
        // same identifier. Click the first match, which is the hittable wrapper.
        let createButton = require(
            app.buttons.matching(identifier: "toolbar.createBottle").firstMatch,
            "+ toolbar button", timeout: 10
        )

        // Opening the sheet is the historically flaky step (a click before the
        // button is hittable, or the Form sheet lagging the AX tree). Wait for
        // hittable, click, wait generously, and retry the click once — guarded on
        // the button still being hittable so we never click behind an open sheet.
        waitUntilHittable(createButton, "+ toolbar button", timeout: 10)
        let cancelButton = app.buttons["create.cancelButton"]
        createButton.click()
        if !cancelButton.waitForExistence(timeout: 15) {
            if createButton.isHittable {
                createButton.click()
            }
            require(cancelButton, "create-bottle sheet", timeout: 15)
        }

        let nameField = require(
            app.textFields["create.nameField"],
            "create-bottle name field"
        )
        // Create button should start disabled (empty name)
        XCTAssertFalse(
            app.buttons["create.createButton"].isEnabled,
            "Create button should be disabled when name is empty"
        )
        // Type a name and verify Create becomes enabled
        nameField.click()
        nameField.typeText("UITestBottle")
        XCTAssertTrue(
            app.buttons["create.createButton"].isEnabled,
            "Create button should enable once name is non-empty"
        )
        // Don't actually create - cancel out
        app.buttons["create.cancelButton"].click()

        // Sheet should dismiss
        XCTAssertFalse(
            app.textFields["create.nameField"]
                .waitForExistence(timeout: 1),
            "Create sheet failed to dismiss after Cancel"
        )
    }
}
