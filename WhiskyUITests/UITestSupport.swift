//
//  UITestSupport.swift
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

/// Shared setup and the waiting helpers, so the suites below read as tests
/// rather than as XCUITest plumbing.
class WhiskyUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-WhiskyUITestMode", "1"]
        app.launch()
        // Frontmost before interacting: a non-key window makes toolbar elements
        // unhittable — the usual source of "element missing" flakiness.
        app.activate()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Helpers

    /// Wait up to `timeout` for an element, returning it on success or failing the test on miss.
    @discardableResult
    func require(
        _ element: XCUIElement,
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Required element missing: \(description)",
            file: file,
            line: line
        )
        return element
    }

    /// Wait up to `timeout` for an element to become *hittable* (interactive),
    /// not merely present — a click before a control is hittable silently no-ops.
    @discardableResult
    func waitUntilHittable(
        _ element: XCUIElement,
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result, .completed,
            "Element never became hittable: \(description)",
            file: file,
            line: line
        )
        return result == .completed
    }

    /// Walk every visible static text label and return any that look like raw localization keys.
    /// Heuristic: contains a `.`, no whitespace, starts lowercase.
    func rawKeyLeaks() -> [String] {
        app.staticTexts.allElementsBoundByIndex.compactMap { element -> String? in
            let label = element.label
            guard !label.isEmpty,
                  label.contains("."),
                  !label.contains(" "),
                  let first = label.first, first.isLowercase
            else { return nil }
            return label
        }
    }

    /// Navigate to Bottle Configuration view of the currently-selected bottle.
    func openBottleConfiguration() {
        let configRow = require(
            app.buttons["nav.bottleConfiguration"],
            "bottle nav row",
            timeout: 8
        )
        configRow.click()
        require(
            app.staticTexts["Wine"],
            "Wine section header in Bottle Configuration",
            timeout: 5
        )
    }

    /// Navigate to Game Configurations view of the currently-selected bottle.
    /// Waits for the list to populate (GameDBLoader runs in `.onAppear`).
    func openGameConfigurations() {
        let row = require(
            app.buttons["nav.gameConfigurations"],
            "game configs nav row",
            timeout: 8
        )
        row.click()
        let list = require(app.outlines["gamedb.list"], "GameDB list outline", timeout: 5)
        // Wait for the outline to actually have rows - the loader runs in onAppear so
        // there is a brief gap between the outline appearing and rows materializing.
        let firstRow = list.outlineRows.firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 5),
            "GameDB list rendered but no rows materialized within 5s"
        )
    }

    // MARK: - Smoke

    /// Throws XCTSkip if the user container has no bottles. CI runners start fresh
    /// without fixtures, and most of these tests assume at least one bottle exists.
    func requireBottleFixture() throws {
        // The app lands on the library now, so a test that wants bottle detail
        // selects a bottle the way a person would rather than assuming one is
        // already open.
        let bottleRow = app.descendants(matching: .any).matching(identifier: "sidebar.bottle").firstMatch
        if bottleRow.waitForExistence(timeout: 5) {
            bottleRow.tap()
        }
        if !app.buttons["nav.bottleConfiguration"].waitForExistence(timeout: 5) {
            throw XCTSkip(
                "No bottle fixtures in user container; skipping. " +
                    "Run a bottle setup locally before running this suite."
            )
        }
    }
}
