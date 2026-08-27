//
//  BackendPrefixCleanupTests.swift
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

/// Tests for taking a previous graphics backend's DLLs back out of a prefix.
///
/// A translation layer is a file in `system32` shadowing the runtime's builtin,
/// so one left behind wins over whatever is chosen next.
@MainActor
final class BackendPrefixCleanupTests: XCTestCase {
    private var bottleURL: URL!
    private var system32: URL!

    override func setUpWithError() throws {
        bottleURL = FileManager.default.temporaryDirectory.appending(path: "backend_\(UUID().uuidString)")
        system32 = bottleURL.appending(path: "drive_c").appending(path: "windows").appending(path: "system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bottleURL)
    }

    private func place(_ names: [String]) throws {
        for name in names {
            try Data("dll".utf8).write(to: system32.appending(path: name))
        }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: system32.appending(path: name).path(percentEncoded: false))
    }

    /// The names overlap with Wine's own. `dxgi.dll` in `system32` is usually
    /// the builtin every prefix has, and removing that one is how a game stops
    /// starting at all.
    func testAFileThatIsNotOursIsNeverTouched() throws {
        try place(SteamCompatToolTestSupport.dxmtNames + ["d3dcompiler_47.dll"])

        Wine.clearForeignBackendDLLs(keeping: [], bottle: Bottle(bottleUrl: bottleURL))

        for name in SteamCompatToolTestSupport.dxmtNames + ["d3dcompiler_47.dll"] {
            XCTAssertTrue(exists(name), "\(name) does not match any payload we ship")
        }
    }

    func testKeptNamesAreNeverConsidered() throws {
        try place(SteamCompatToolTestSupport.dxmtNames)

        Wine.clearForeignBackendDLLs(
            keeping: Set(SteamCompatToolTestSupport.dxmtNames), bottle: Bottle(bottleUrl: bottleURL)
        )

        for name in SteamCompatToolTestSupport.dxmtNames {
            XCTAssertTrue(exists(name))
        }
    }

    /// D3DMetal wants the runtime's own builtins, so it leaves nothing of its
    /// own behind and everything else has to go.
    func testD3DMetalPlacesNothingInThePrefix() {
        XCTAssertTrue(Wine.prefixDLLNames(for: .d3dMetal, runtime: nil).isEmpty)
        XCTAssertFalse(Wine.prefixDLLNames(for: .dxmt, runtime: nil).isEmpty)
    }

    func testAPrefixWithNothingToCleanIsLeftAlone() throws {
        try place(["d3dcompiler_47.dll"])

        Wine.clearForeignBackendDLLs(keeping: [], bottle: Bottle(bottleUrl: bottleURL))

        XCTAssertTrue(exists("d3dcompiler_47.dll"))
    }
}

/// The DXMT payload's file names, which are private to `Wine`.
enum SteamCompatToolTestSupport {
    static let dxmtNames = ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"]
}
