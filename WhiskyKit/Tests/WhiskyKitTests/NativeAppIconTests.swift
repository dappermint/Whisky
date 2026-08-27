//
//  NativeAppIconTests.swift
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

/// Tests for the macOS-shaped plate composed for a program's Dock tile.
final class NativeAppIconTests: XCTestCase {
    private func swatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        image.unlockFocus()
        return image
    }

    func testComposeProducesAFullSizeIcon() throws {
        let data = try XCTUnwrap(
            NativeAppIcon.compose(artwork: swatch(.systemPink), palette: IconPalette.neutral)
        )
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))

        XCTAssertEqual(image.pixelsWide, 1_024)
        XCTAssertEqual(image.pixelsHigh, 1_024)
    }

    func testComposeLeavesTheCornersTransparent() throws {
        let data = try XCTUnwrap(
            NativeAppIcon.compose(artwork: swatch(.white), palette: IconPalette.neutral)
        )
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))

        // The plate is a squircle inside a 1024 canvas, so the very corner of
        // the canvas is outside both it and its shadow.
        let corner = try XCTUnwrap(image.colorAt(x: 2, y: 2))
        XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.02)

        let middle = try XCTUnwrap(image.colorAt(x: 512, y: 512))
        XCTAssertEqual(middle.alphaComponent, 1, accuracy: 0.02)
    }

    func testSquircleIsWiderThanACircleAtTheDiagonal() {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 100)
        let path = NativeAppIcon.squircle(in: rect, samples: 8)

        // A circle would reach 85.4 on the 45 degree diagonal; the squircle
        // pushes further out, which is what makes the corner continuous.
        XCTAssertTrue(path.bounds.width > 99, "\(path.bounds)")
        XCTAssertTrue(path.contains(NSPoint(x: 88, y: 88)))
    }

    func testCacheKeyIsStableForTheSameFileAndChangesWithIt() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "whisky-icon-key-\(UUID().uuidString)")
        try Data("first".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let first = try XCTUnwrap(NativeAppIcon.cacheKey(for: file))
        XCTAssertEqual(first, NativeAppIcon.cacheKey(for: file))

        try Data("a longer second build".utf8).write(to: file)
        XCTAssertNotEqual(first, NativeAppIcon.cacheKey(for: file))
    }

    func testCacheKeyIsNilForAFileThatIsNotThere() {
        let missing = URL(fileURLWithPath: "/nowhere/whisky/does-not-exist.exe")
        XCTAssertNil(NativeAppIcon.cacheKey(for: missing))
    }
}
