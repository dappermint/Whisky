//
//  SteamLibraryArtTests.swift
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

/// Tests for reading the artwork the Steam client has already downloaded.
///
/// An executable is a poor witness to which game it is: Ready or Not's is the
/// Epic Online Services bootstrapper, so its icon is Epic's logo.
final class SteamLibraryArtTests: XCTestCase {
    private var cache: URL!

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appending(path: "libcache_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cache)
    }

    private func write(_ name: String, size: NSSize, into folder: URL, type: NSBitmapImageRep.FileType) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: type, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: folder.appending(path: name))
    }

    func testTheCapsuleIsPreferredAndFillsTheTile() throws {
        let app = cache.appending(path: "1144200")
        // The client shards art into content-addressed subdirectories.
        try write(
            "library_capsule.jpg",
            size: NSSize(width: 300, height: 450),
            into: app.appending(path: "13940ca7"),
            type: .jpeg
        )
        try write(
            "logo.png",
            size: NSSize(width: 640, height: 120),
            into: app.appending(path: "464e454e"),
            type: .png
        )

        let artwork = try XCTUnwrap(SteamLibraryArt.artwork(forAppId: 1_144_200, in: cache))
        XCTAssertTrue(artwork.isFill)
        // Cropped square, because a portrait capsule on a square tile would
        // otherwise letterbox.
        XCTAssertEqual(artwork.image.size.width, artwork.image.size.height)
    }

    func testTheLogoIsUsedWhenThereIsNoCapsule() throws {
        let app = cache.appending(path: "553850")
        try write(
            "logo.png",
            size: NSSize(width: 640, height: 360),
            into: app.appending(path: "2e110cff"),
            type: .png
        )

        let artwork = try XCTUnwrap(SteamLibraryArt.artwork(forAppId: 553_850, in: cache))
        XCTAssertFalse(artwork.isFill)
    }

    func testAnAppWithNoArtGetsNothing() {
        XCTAssertNil(SteamLibraryArt.artwork(forAppId: 999_999, in: cache))
    }

    func testAnAppWhoseFolderIsEmptyGetsNothing() throws {
        try FileManager.default.createDirectory(
            at: cache.appending(path: "1"), withIntermediateDirectories: true
        )
        XCTAssertNil(SteamLibraryArt.artwork(forAppId: 1, in: cache))
    }

    func testLandscapeArtIsLeftAlone() throws {
        let app = cache.appending(path: "42")
        try write(
            "library_capsule.jpg",
            size: NSSize(width: 460, height: 215),
            into: app,
            type: .jpeg
        )

        let artwork = try XCTUnwrap(SteamLibraryArt.artwork(forAppId: 42, in: cache))
        XCTAssertEqual(artwork.image.size.width, 460)
    }

    /// The generic Windows-executable icon on a plate looks like a deliberate
    /// choice rather than the absence of one, so it is never composed.
    func testAProgramWithNoIconAndNoArtComposesNothing() async {
        let missing = URL(fileURLWithPath: "/nowhere/whisky/no-such-program.exe")
        let artwork = await NativeAppIcon.artwork(for: missing, steamAppId: nil)
        XCTAssertNil(artwork)
    }

    func testTheCacheKeySeparatesArtSources() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "whisky-art-key-\(UUID().uuidString)")
        try Data("exe".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertNotEqual(
            NativeAppIcon.cacheKey(for: file),
            NativeAppIcon.cacheKey(for: file, steamAppId: 1_144_200)
        )
    }
}
