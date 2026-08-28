//
//  RuntimeTLS.swift
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

import Foundation

/// Whether a runtime can open an HTTPS connection.
///
/// Wine's schannel is GnuTLS, which links libidn2 and libunistring, which call
/// `libiconv`. GNU libiconv exports that name; Apple's exports `iconv` and
/// nothing else, so a runtime that bundles Apple's copy under the GNU name
/// loads no GnuTLS at all.
///
/// Nothing says so out loud. `secur32` reports no schannel support, every
/// Windows process gets `SEC_E_SECPKG_NOT_FOUND` back from a TLS handshake, and
/// a game sits on "signing in" forever with a clean log. Naming it here is the
/// difference between a two minute fix and an evening.
public enum RuntimeTLS {
    public enum Status: Equatable, Sendable {
        /// The bundled libiconv serves GnuTLS' dependencies.
        case available
        /// Apple's libiconv is bundled under the GNU name, so HTTPS cannot work.
        case libiconvIsApples
        /// Nothing to judge: the runtime bundles no TLS stack of its own, or
        /// its libraries could not be read.
        case unknown

        public var summary: String {
            switch self {
            case .available: "✅ Available"
            case .libiconvIsApples: "❌ Unavailable (bundled libiconv is Apple's, not GNU's)"
            case .unknown: "Unknown"
            }
        }
    }

    /// The symbol GNU libiconv exports and Apple's does not.
    private static let gnuSymbol = "_libiconv"

    /// The 64-bit unix library directories a runtime can have, in the order
    /// they are looked for. A lane only ever ships one.
    private static let unixDirectories = ["aarch64-unix", "x86_64-unix"]

    public static func status(forRuntime runtime: String?) -> Status {
        guard let folder = unixFolder(forRuntime: runtime) else { return .unknown }
        return status(unixFolder: folder)
    }

    static func status(unixFolder: URL) -> Status {
        let files = FileManager.default
        // Without a bundled GnuTLS there is nothing for libiconv to break.
        guard files.fileExists(atPath: unixFolder.appending(path: "libgnutls.30.dylib").path(percentEncoded: false))
        else { return .unknown }

        let libiconv = unixFolder.appending(path: "libiconv.2.dylib")
        guard let data = try? Data(contentsOf: libiconv, options: .mappedIfSafe) else { return .unknown }

        // Anything that is not a Mach-O we understand is not evidence of a
        // broken runtime, only of a file this cannot read.
        let slices = MachOImage.slices(of: data)
        guard !slices.isEmpty else { return .unknown }

        return slices.contains { MachOImage.exportsSymbol(gnuSymbol, in: data, slice: $0) }
            ? .available : .libiconvIsApples
    }

    static func unixFolder(forRuntime runtime: String?) -> URL? {
        let wine = WhiskyWineInstaller.dllFolder(for: runtime)
        return unixDirectories
            .map { wine.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}
