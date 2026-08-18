//
//  SpotlightIndexer.swift
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

import CoreSpotlight
import Foundation
import WhiskyKit

/// Mirrors the library into the system Spotlight index, so a game launches
/// from Spotlight like any native app. Item identifiers are `whisky://`
/// launch URLs, which the activation handler hands straight to
/// ``QuickLaunch``.
@MainActor
enum SpotlightIndexer {
    private static let domain = "library"

    /// Replaces the index with the current library. Hidden entries are
    /// dropped, so hiding a card also removes it from Spotlight.
    static func reindex(rows: [LibraryRow]) {
        let items = rows.filter { !$0.isHidden }.compactMap(item(for:))
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items)
        }
    }

    private static func item(for row: LibraryRow) -> CSSearchableItem? {
        guard let url = launchURL(for: row) else { return nil }
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = row.name
        attributes.contentDescription = row.bottleName
        attributes.keywords = [row.name, "Whisky"]
        return CSSearchableItem(
            uniqueIdentifier: url.absoluteString,
            domainIdentifier: domain,
            attributeSet: attributes
        )
    }

    /// The same URL forms ``QuickLaunch/handle(_:)`` parses. Pins are
    /// addressed by their source name, which a rename does not touch.
    private static func launchURL(for row: LibraryRow) -> URL? {
        var components = URLComponents()
        components.scheme = "whisky"
        components.host = "launch"
        var query: [URLQueryItem] = []
        switch row.item.launch {
        case let .steam(appID):
            query.append(URLQueryItem(name: "steam", value: String(appID)))
        case .program:
            query.append(URLQueryItem(name: "pin", value: row.item.name))
        }
        if let bottleName = row.bottleName {
            query.append(URLQueryItem(name: "bottle", value: bottleName))
        }
        components.queryItems = query
        return components.url
    }
}
