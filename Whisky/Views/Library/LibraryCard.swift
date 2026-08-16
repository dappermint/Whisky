//
//  LibraryCard.swift
//  Whisky
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

import SwiftUI
import WhiskyKit

extension Color {
    init(_ palette: IconPalette) {
        self.init(.sRGB, red: palette.red, green: palette.green, blue: palette.blue)
    }
}

/// One library entry, coloured by its own icon.
///
/// Landscape rather than the portrait box art other launchers use, because they
/// download 600x900 posters and we have a 32 to 256px icon out of the
/// executable. Stretching an icon into a poster looks broken; a wide card is the
/// shape an icon and a name actually want, and it leaves the icon at its native
/// size where it stays crisp.
struct LibraryCard: View {
    let item: LibraryEntry
    /// Only shown when there is more than one bottle, since with a single bottle
    /// the prefix is plumbing and naming it on every card is noise.
    let bottleName: String?
    let lastPlayed: Date?
    let launch: () -> Void

    @State private var icon: Image?
    @State private var artwork: Image?
    @State private var palette: IconPalette = .neutral
    @State private var isHovering = false

    private var backdrop: Color { Color(palette.deepened()) }

    var body: some View {
        Button(action: launch) {
            card
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
        .task(id: item.id) {
            await loadIcon()
        }
        .accessibilityLabel(item.name)
        .accessibilityHint(Text("library.card.hint"))
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [backdrop, backdrop.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let artwork {
                // Steam cached this art inside the bottle, so a Steam game shows
                // its own banner with nothing fetched. Sized by an empty layer
                // rather than by the image: scaledToFill on its own reports the
                // image's size upward and the card grows to fit it.
                Color.clear
                    .overlay {
                        artwork
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .overlay {
                        // The scrim is what keeps the name readable over art we
                        // do not control.
                        LinearGradient(
                            colors: [.black.opacity(0.05), .black.opacity(0.75)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    // The icon tile is the identity when there is no artwork.
                    // With artwork it would sit on top of the thing it stands in
                    // for, so it goes.
                    if artwork == nil {
                        iconView
                    }
                    Spacer()
                    if isHovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13))
                            .frame(width: 30, height: 30)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                Spacer(minLength: 8)
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    // Tail, not middle: a game's name is recognisable from its
                    // start, and "The Elder Scro...Special Edition" reads worse
                    // than losing the edition suffix.
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(14)
        }
        .foregroundStyle(.white)
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(isHovering ? 0.22 : 0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(isHovering ? 0.28 : 0.16), radius: isHovering ? 10 : 5, y: 3)
        .scaleEffect(isHovering ? 1.015 : 1)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            icon
                .resizable()
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.12))
                .frame(width: 44, height: 44)
        }
    }

    /// Source first when it is not a pin, because "Steam" tells you why an entry
    /// is here at all, and a pin needs no explanation.
    private var subtitle: String {
        var parts: [String] = []
        if item.source == .steam {
            parts.append(String(localized: "library.source.steam"))
        }
        if let lastPlayed {
            parts.append(lastPlayed.formatted(.relative(presentation: .named)))
        } else {
            parts.append(String(localized: "library.card.neverRun"))
        }
        if let bottleName {
            parts.append(bottleName)
        }
        return parts.joined(separator: " · ")
    }

    private func loadIcon() async {
        if let artworkURL = item.artworkURL, let image = NSImage(contentsOf: artworkURL) {
            artwork = Image(nsImage: image)
            // Still sampled: the border and the hover glow pick up the art's own
            // colour, so a card reads as one object rather than art in a frame.
            palette = IconPalette.palette(for: image)
            return
        }
        guard let iconURL = item.iconURL else {
            palette = .neutral
            return
        }
        let image = await IconCache.shared.iconOrFallback(for: iconURL)
        palette = IconPalette.palette(for: image)
        icon = Image(nsImage: image)
    }
}
