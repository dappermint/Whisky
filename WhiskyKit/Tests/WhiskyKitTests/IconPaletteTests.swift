//
//  IconPaletteTests.swift
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
import Foundation
import Testing
@testable import WhiskyKit

@Suite("Icon Palette Tests")
struct IconPaletteTests {
    /// Explicitly sRGB: `CGColor(red:green:blue:alpha:)` builds a generic RGB
    /// colour, and filling that into an sRGB context shifts every channel, which
    /// would have this test asserting against the conversion rather than the
    /// algorithm.
    private func srgb(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(red), CGFloat(green), CGFloat(blue), 1]
        ) ?? CGColor(gray: 0, alpha: 1)
    }

    /// Draws `body` over a transparent field, the shape almost every Windows
    /// icon actually has.
    private func icon(size: CGFloat = 64, body: (CGContext) -> Void) throws -> NSImage {
        let context = try #require(CGContext(
            data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        body(context)
        let cgImage = try #require(context.makeImage())
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    @Test("A solid colour icon returns that colour")
    func solidColour() throws {
        let image = try icon { context in
            context.setFillColor(srgb(0.85, 0.2, 0.2))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }

        let palette = IconPalette.palette(for: image)
        #expect(abs(palette.red - 0.85) < 0.08)
        #expect(abs(palette.green - 0.2) < 0.08)
        #expect(abs(palette.blue - 0.2) < 0.08)
    }

    @Test("A small mark on a transparent field wins over the empty space")
    func markBeatsTransparency() throws {
        let image = try icon { context in
            // A tenth of the area, which is a realistic mark-to-field ratio
            context.setFillColor(srgb(0.1, 0.35, 0.9))
            context.fill(CGRect(x: 22, y: 22, width: 20, height: 20))
        }

        let palette = IconPalette.palette(for: image)
        #expect(palette.blue > palette.red)
        #expect(palette.blue > 0.6)
    }

    @Test("A coloured mark on a white field wins over the white")
    func markBeatsWhite() throws {
        let image = try icon { context in
            context.setFillColor(srgb(1, 1, 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(srgb(0.1, 0.6, 0.25))
            context.fill(CGRect(x: 24, y: 24, width: 16, height: 16))
        }

        let palette = IconPalette.palette(for: image)
        #expect(palette.green > palette.red)
        #expect(palette.green > palette.blue)
    }

    @Test("A greyscale icon keeps its own shade instead of the shared fallback")
    func greyscaleKeepsItsShade() throws {
        let image = try icon { context in
            context.setFillColor(srgb(0.25, 0.25, 0.25))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }

        let palette = IconPalette.palette(for: image)
        #expect(abs(palette.red - palette.green) < 0.02)
        #expect(palette.luminance < 0.4)
        #expect(palette != .neutral)
    }

    @Test("A fully transparent icon falls back rather than returning black")
    func transparentFallsBack() throws {
        let image = try icon { _ in }

        #expect(IconPalette.palette(for: image) == .neutral)
    }

    @Test("Foreground choice follows luminance")
    func foregroundFollowsLuminance() {
        #expect(IconPalette(red: 0.05, green: 0.05, blue: 0.1).prefersLightForeground)
        #expect(!IconPalette(red: 0.95, green: 0.93, blue: 0.2).prefersLightForeground)
    }

    @Test("Deepening lands on the target luminance whatever the icon's colour")
    func deepeningNormalisesLuminance() {
        for palette in [
            IconPalette(red: 0.95, green: 0.93, blue: 0.2), // fluorescent yellow
            IconPalette(red: 0.1, green: 0.35, blue: 0.9), // saturated blue
            IconPalette(red: 0.5, green: 0.5, blue: 0.5) // mid grey
        ] {
            #expect(abs(palette.deepened().luminance - 0.14) < 0.02)
            #expect(palette.deepened().prefersLightForeground)
        }
    }

    @Test("Deepening keeps the hue rather than flattening every card to one colour")
    func deepeningKeepsHue() {
        let blue = IconPalette(red: 0.1, green: 0.35, blue: 0.9).deepened()
        let red = IconPalette(red: 0.9, green: 0.2, blue: 0.15).deepened()

        #expect(blue.blue > blue.red)
        #expect(red.red > red.blue)
    }

    @Test("An almost black icon is left alone rather than washed out")
    func deepeningLeavesDarkIconsDark() {
        let palette = IconPalette(red: 0.02, green: 0.02, blue: 0.03).deepened()

        #expect(palette.luminance < 0.06)
    }

    @Test("Components are clamped, so a bad sample cannot escape the range")
    func componentsAreClamped() {
        let palette = IconPalette(red: 4, green: -1, blue: 0.5)

        #expect(palette.red == 1)
        #expect(palette.green == 0)
        #expect(palette.blue == 0.5)
    }
}
