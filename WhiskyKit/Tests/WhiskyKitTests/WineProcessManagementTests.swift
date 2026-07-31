//
//  WineProcessManagementTests.swift
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

final class WineProcessManagementTests: XCTestCase {
    /// A fresh prefix can never have a live wineserver, so the probe must
    /// report false — whether wineserver spawns and exits nonzero (runtime
    /// installed) or the spawn itself fails (no runtime, e.g. CI).
    @MainActor
    func testWineserverProbeReturnsFalseForBottleWithoutServer() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)

        let running = await Wine.isWineserverRunning(for: bottle)

        XCTAssertFalse(running)
    }
}
