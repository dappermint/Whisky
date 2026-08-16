//
//  IconPalette.swift
//  WhiskyKit
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

/// The colour a program's own icon is built around.
///
/// Whisky reads icons out of the executable's PE resources, so it can colour a
/// program's card from the program itself rather than from artwork someone had
/// to publish. A launcher that fetches store art has no equivalent: this works
/// for a game nobody has ever written a store page for.
public struct IconPalette: Equatable, Sendable {
    /// The colour the icon is built around, as sRGB in 0...1.
    public let red: Double
    public let green: Double
    public let blue: Double

    /// Whether that colour is dark enough that white text sits comfortably on it.
    public var prefersLightForeground: Bool { luminance < 0.55 }

    /// Rec. 709 relative luminance, which is what decides foreground contrast.
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// The neutral used for icons with no colour of their own, and for anything
    /// that fails to decode. Deliberately not black: a card that falls back
    /// should still look like a card.
    public static let neutral = IconPalette(red: 0.42, green: 0.44, blue: 0.5)

    /// The same hue taken to a fixed luminance.
    ///
    /// A card has to be readable whatever the icon is, and icons range from
    /// near-black to fluorescent yellow. Scaling to a target luminance keeps
    /// each program's own colour while guaranteeing the contrast underneath the
    /// label, which picking a tint by eye per program cannot do.
    public func deepened(toLuminance target: Double = 0.14) -> IconPalette {
        let current = luminance
        guard current > 0.001 else {
            return IconPalette(red: target, green: target, blue: target)
        }
        let scale = target / current
        // Above 1 the scale would blow out a dark icon into a wash; a dark icon
        // is allowed to stay dark, it just cannot go darker than the target.
        return IconPalette(
            red: red * min(scale, 1.6),
            green: green * min(scale, 1.6),
            blue: blue * min(scale, 1.6)
        )
    }
}

public extension IconPalette {
    /// Samples `image` and returns the colour it is built around.
    ///
    /// Grey and near-transparent pixels are dropped before anything is averaged.
    /// Windows icons are overwhelmingly a small mark on a transparent or white
    /// field, so averaging everything returns off-white for almost every program
    /// and every card comes out the same colour. What survives the filter is the
    /// mark itself, which is the part a person recognises.
    static func palette(for image: NSImage, sampleSize: Int = 32) -> IconPalette {
        guard let pixels = samples(of: image, size: sampleSize), !pixels.isEmpty else { return .neutral }

        var coloured: [WeightedColour] = []
        var greyTotal = (red: 0.0, green: 0.0, blue: 0.0, weight: 0.0)

        for pixel in pixels where pixel.alpha > 0.4 {
            let highest = max(pixel.red, pixel.green, pixel.blue)
            let lowest = min(pixel.red, pixel.green, pixel.blue)
            let saturation = highest > 0 ? (highest - lowest) / highest : 0

            // Weighted towards saturated mid-tones: a colour that is nearly
            // black or nearly white carries no identity even when it is the
            // most common pixel in the icon.
            if saturation > 0.25, highest > 0.15 {
                let weight = saturation * (1 - abs(highest - 0.6))
                coloured.append(
                    WeightedColour(red: pixel.red, green: pixel.green, blue: pixel.blue, weight: max(weight, 0.05))
                )
            } else {
                greyTotal.red += pixel.red
                greyTotal.green += pixel.green
                greyTotal.blue += pixel.blue
                greyTotal.weight += 1
            }
        }

        if !coloured.isEmpty {
            let total = coloured.reduce(0) { $0 + $1.weight }
            return IconPalette(
                red: coloured.reduce(0) { $0 + $1.red * $1.weight } / total,
                green: coloured.reduce(0) { $0 + $1.green * $1.weight } / total,
                blue: coloured.reduce(0) { $0 + $1.blue * $1.weight } / total
            )
        }

        // A genuinely greyscale icon still gets its own shade rather than the
        // shared fallback, so two grey icons do not look like the same program.
        guard greyTotal.weight > 0 else { return .neutral }
        return IconPalette(
            red: greyTotal.red / greyTotal.weight,
            green: greyTotal.green / greyTotal.weight,
            blue: greyTotal.blue / greyTotal.weight
        )
    }

    /// A pixel that survived the filter, and how much it counts.
    private struct WeightedColour {
        let red: Double
        let green: Double
        let blue: Double
        let weight: Double
    }

    private struct Sample {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    private static func samples(of image: NSImage, size: Int) -> [Sample]? {
        guard size > 0, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        var raw = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &raw,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        return stride(from: 0, to: raw.count, by: 4).map { index in
            let alpha = Double(raw[index + 3]) / 255
            // Premultiplied, so the colour channels have to be divided back out
            // or every translucent edge pixel reads as darker than it is.
            let scale = alpha > 0 ? alpha : 1
            return Sample(
                red: Double(raw[index]) / 255 / scale,
                green: Double(raw[index + 1]) / 255 / scale,
                blue: Double(raw[index + 2]) / 255 / scale,
                alpha: alpha
            )
        }
    }
}
