//
//  NVAPIBridgeTests.swift
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

/// Apple's NVAPI is what makes MetalFX reachable: Streamline asks it about the
/// GPU before it will consider DLSS, and Wine's placeholder exports nothing.
final class NVAPIBridgeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A store holding Apple's NVAPI, and a library tree holding Wine's placeholder.
    private func makeTree(placeholder: String = "wine placeholder") throws -> (store: URL, folder: URL) {
        let store = root.appending(path: "store")
        let storePE = store.appending(path: "lib").appending(path: "wine").appending(path: "x86_64-windows")
        try FileManager.default.createDirectory(at: storePE, withIntermediateDirectories: true)
        try "apple nvapi".write(
            to: storePE.appending(path: GPTKImporter.nvapiBridgeName), atomically: true, encoding: .utf8
        )

        let folder = root.appending(path: "Libraries")
        let treePE = folder.appending(path: "Wine").appending(path: "lib")
            .appending(path: "wine").appending(path: "x86_64-windows")
        try FileManager.default.createDirectory(at: treePE, withIntermediateDirectories: true)
        try placeholder.write(
            to: treePE.appending(path: GPTKImporter.nvapiBridgeName), atomically: true, encoding: .utf8
        )
        return (store, folder)
    }

    private func contents(of url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    func testInstallReplacesThePlaceholderAndLinksTheUnixHalf() throws {
        let (store, folder) = try makeTree()
        try GPTKImporter.installNVAPIBridge(intoLibraryFolder: folder, usingStore: store)

        XCTAssertTrue(GPTKImporter.isNVAPIBridgeInstalled(inLibraryFolder: folder, usingStore: store))
        XCTAssertEqual(contents(of: GPTKImporter.nvapiBridgePE(inLibraryFolder: folder)), "apple nvapi")

        // The unix half is required: the PE alone loads and dies in DllMain.
        let link = GPTKImporter.nvapiBridgeUnixLink(inLibraryFolder: folder)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false))
        XCTAssertEqual(target, GPTKImporter.unixLinkDestination)
    }

    func testRemovePutsWinesPlaceholderBack() throws {
        let (store, folder) = try makeTree()
        try GPTKImporter.installNVAPIBridge(intoLibraryFolder: folder, usingStore: store)
        GPTKImporter.removeNVAPIBridge(fromLibraryFolder: folder, usingStore: store)

        XCTAssertFalse(GPTKImporter.isNVAPIBridgeInstalled(inLibraryFolder: folder, usingStore: store))
        XCTAssertEqual(contents(of: GPTKImporter.nvapiBridgePE(inLibraryFolder: folder)), "wine placeholder")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: GPTKImporter.nvapiBridgeUnixLink(inLibraryFolder: folder).path(percentEncoded: false)
        ))
    }

    func testInstallingTwiceDoesNotEatThePlaceholder() throws {
        let (store, folder) = try makeTree()
        try GPTKImporter.installNVAPIBridge(intoLibraryFolder: folder, usingStore: store)
        // A second install must not back Apple's DLL up over the placeholder,
        // or removal would restore Apple's and never undo anything.
        try GPTKImporter.installNVAPIBridge(intoLibraryFolder: folder, usingStore: store)
        GPTKImporter.removeNVAPIBridge(fromLibraryFolder: folder, usingStore: store)

        XCTAssertEqual(contents(of: GPTKImporter.nvapiBridgePE(inLibraryFolder: folder)), "wine placeholder")
    }

    func testHelpersGetNVAPIDisabledWithoutLosingTheirOtherOverrides() {
        let result = Wine.disablingNVAPI(in: "dxgi=n,b;d3d11=n,b")
        XCTAssertEqual(result, "d3d11=n,b;dxgi=n,b;nvapi64=")
    }

    func testDisablingNVAPIOnAnEmptyStringStillDisablesIt() {
        XCTAssertEqual(Wine.disablingNVAPI(in: ""), "nvapi64=")
    }
}
