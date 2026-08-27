//
//  NativeAppIcon.swift
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
import CryptoKit
import Foundation
import os.log

/// Puts a Windows program's artwork on a macOS-shaped plate.
///
/// A PE icon is a bare bitmap with no plate, so next to the squircles macOS
/// draws for everything else a Dock tile of one reads as a sticker. This
/// composes the program's own artwork onto a squircle tinted from that
/// artwork, at the geometry Apple uses, and writes it where Wine can load it:
/// the patched `winemac.drv` reads `WINE_APP_ICON_PATH` and prefers it over
/// the exe's own resource.
public enum NativeAppIcon {
    /// The macOS 11+ app icon grid: a 1024pt canvas holding an 824pt body,
    /// with the margin left for the drop shadow.
    private static let canvas: CGFloat = 1_024
    private static let body: CGFloat = 824
    /// The superellipse exponent whose corner matches Apple's, which is
    /// continuous rather than the quarter circle a plain rounded rect draws.
    private static let squircleExponent: Double = 5
    /// How much of the plate the program's own artwork covers.
    private static let artworkScale: CGFloat = 0.62

    /// Where composed icons are kept, one file per program build.
    public static var cacheDirectory: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "AppIcons")
    }

    /// Returns a composed icon file for `programURL`, writing it on first use.
    ///
    /// The cache key covers the executable's size and modification date, so a
    /// game that patches its own exe gets a fresh icon rather than a stale one.
    ///
    /// - Returns: The file to hand to Wine, or `nil` when the program has no
    ///   icon worth composing or the file could not be written.
    public static func iconFile(for programURL: URL, steamAppId: Int? = nil) async -> URL? {
        guard let artwork = await artwork(for: programURL, steamAppId: steamAppId),
              let key = cacheKey(for: programURL, steamAppId: steamAppId)
        else { return nil }
        let file = cacheDirectory.appending(path: key).appendingPathExtension("png")

        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            return file
        }

        guard let png = compose(
            artwork: artwork.image, palette: IconPalette.palette(for: artwork.image),
            fills: artwork.isFill
        )
        else { return nil }

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try png.write(to: file)
            return file
        } catch {
            let program = programURL.lastPathComponent
            let reason = error.localizedDescription
            Logger.wineKit.warning(
                "Could not write composed icon for \(program, privacy: .public): \(reason, privacy: .public)"
            )
            return nil
        }
    }

    /// Removes every composed icon. Used when the cache should be rebuilt.
    public static func clearCache() throws {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: cacheDirectory)
    }

    /// The best artwork for the program, and how it wants to be drawn.
    ///
    /// Steam's own art comes first when the launch came from Steam, because an
    /// executable is a poor witness to which game it is: Ready or Not's is the
    /// Epic Online Services bootstrapper and carries Epic's logo.
    ///
    /// - Returns: `nil` when there is nothing worth composing. The executable's
    ///   own resource is deliberately not replaced by the generic system icon
    ///   for a Windows binary, which on a plate looks like a deliberate choice
    ///   rather than the absence of one.
    static func artwork(for programURL: URL, steamAppId: Int?) async -> SteamLibraryArt.Artwork? {
        if let steamAppId, let art = SteamLibraryArt.artwork(forAppId: steamAppId) {
            return art
        }
        guard let icon = await IconCache.shared.icon(for: programURL) else { return nil }
        return .inset(icon)
    }

    // MARK: - Composition

    /// Draws `artwork` onto a plate tinted from `palette` and encodes a PNG.
    ///
    /// Key art `fills` the tile edge to edge, the way a game's icon does on a
    /// console. A mark with its own transparency sits inset on the plate.
    static func compose(artwork: NSImage, palette: IconPalette, fills: Bool = false) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        else { return nil }
        rep.size = NSSize(width: canvas, height: canvas)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previous }
        context.imageInterpolation = .high

        let inset = (canvas - body) / 2
        let plateRect = NSRect(x: inset, y: inset, width: body, height: body)
        let plate = squircle(in: plateRect)

        drawPlate(plate, rect: plateRect, palette: palette, in: context)
        if fills {
            context.saveGraphicsState()
            plate.addClip()
            drawFilling(artwork, in: plateRect)
            context.restoreGraphicsState()
            strokeHairline(around: plateRect)
        } else {
            drawArtwork(artwork, on: plateRect)
        }

        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    private static func drawPlate(
        _ plate: NSBezierPath, rect: NSRect, palette: IconPalette, in context: NSGraphicsContext
    ) {
        // The shadow is what seats the tile on the Dock shelf, and it has to be
        // painted before the plate clips everything to its own shape.
        context.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(deviceWhite: 0, alpha: 0.34)
        shadow.shadowBlurRadius = 42
        shadow.shadowOffset = NSSize(width: 0, height: -18)
        shadow.set()
        NSColor.black.setFill()
        plate.fill()
        context.restoreGraphicsState()

        // A plate tinted from the artwork keeps the tile recognisable at Dock
        // size, where the artwork itself is a handful of pixels. Deepening it
        // first keeps a bright logo from producing a glaring tile.
        let base = palette.deepened(toLuminance: 0.13)
        let bottom = NSColor(
            deviceRed: base.red, green: base.green, blue: base.blue, alpha: 1
        )
        let top = bottom.blended(withFraction: 0.16, of: .white) ?? bottom

        context.saveGraphicsState()
        plate.addClip()
        NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)

        context.restoreGraphicsState()
        strokeHairline(around: rect)
    }

    /// The difference between a flat rectangle of colour and something that
    /// reads as a surface with an edge.
    private static func strokeHairline(around rect: NSRect) {
        let hairline = squircle(in: rect.insetBy(dx: 1.5, dy: 1.5))
        hairline.lineWidth = 3
        NSColor(deviceWhite: 1, alpha: 0.14).setStroke()
        hairline.stroke()
    }

    /// Scales key art to cover the whole plate, cropping whichever axis is
    /// long rather than letterboxing it.
    private static func drawFilling(_ artwork: NSImage, in rect: NSRect) {
        let size = artwork.size
        guard size.width > 0, size.height > 0 else { return }

        let scale = max(rect.width / size.width, rect.height / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        artwork.draw(
            in: NSRect(
                x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                width: drawn.width, height: drawn.height
            ),
            from: .zero, operation: .sourceOver, fraction: 1
        )
    }

    private static func drawArtwork(_ artwork: NSImage, on plateRect: NSRect) {
        let side = plateRect.width * artworkScale
        let target = NSRect(
            x: plateRect.midX - side / 2,
            y: plateRect.midY - side / 2,
            width: side, height: side
        )
        // Wide or tall artwork keeps its own proportions inside that square.
        let size = artwork.size
        var fitted = target
        if size.width > 0, size.height > 0, size.width != size.height {
            let scale = min(target.width / size.width, target.height / size.height)
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            fitted = NSRect(
                x: target.midX - drawn.width / 2, y: target.midY - drawn.height / 2,
                width: drawn.width, height: drawn.height
            )
        }
        artwork.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// The rounded square macOS uses, whose corners are continuous rather than
    /// circular arcs. Sampled as a superellipse, which for a square body is
    /// indistinguishable from the real curve at icon sizes.
    static func squircle(in rect: NSRect, samples: Int = 512) -> NSBezierPath {
        let path = NSBezierPath()
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        let exponent = squircleExponent

        for step in 0 ... samples {
            let angle = Double(step) / Double(samples) * 2 * Double.pi
            let cosine = cos(angle)
            let sine = sin(angle)
            let point = NSPoint(
                x: rect.midX + halfWidth * copysign(pow(abs(cosine), 2 / exponent), cosine),
                y: rect.midY + halfHeight * copysign(pow(abs(sine), 2 / exponent), sine)
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        return path
    }

    // MARK: - Cache key

    /// Identifies one build of one executable: path, size and modification
    /// date, and the App ID when that is where the artwork came from, so a game
    /// that gains library art stops using the icon it was composed from.
    static func cacheKey(for programURL: URL, steamAppId: Int? = nil) -> String? {
        let path = programURL.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let seed = "\(path)|\(size)|\(Int(modified))|\(steamAppId.map(String.init) ?? "")"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
