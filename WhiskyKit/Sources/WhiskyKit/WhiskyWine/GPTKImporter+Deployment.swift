//
//  GPTKImporter+Deployment.swift
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
import os.log

/// Which runtime the backed-up Wine originals were taken from. The store now
/// outlives the runtime, so a backup can outlive the engine it came from, and
/// restoring a Wine 10 builtin into a Wine 11 tree breaks it silently.
struct GPTKOriginalsRecord: Codable, Equatable, Sendable {
    let runtimeVersion: String
}

/// Runtime capability gating and deployment of the stored payload into the
/// Wine tree (Apple's documented layout).
extension GPTKImporter {
    // MARK: - Runtime capability

    /// Whether the installed runtime's Wine build can execute GPTK payloads.
    ///
    /// Advertised by `gptkCapable` in the runtime's version plist; absent means
    /// no. This is a build property (exception-unwind support), not something
    /// the payload or the app can add.
    public static func isRuntimeGPTKCapable() -> Bool {
        isRuntimeGPTKCapable(for: nil)
    }

    /// Whether `runtime`'s Wine build can execute GPTK payloads.
    public static func isRuntimeGPTKCapable(for runtime: String?) -> Bool {
        WhiskyWineInstaller.whiskyWineInfo(for: runtime)?.gptkCapable == true
    }

    // MARK: - Deployment

    /// Whether the payload is deployed into the default runtime's tree.
    public static func isDeployed() -> Bool {
        isDeployed(for: nil)
    }

    /// Whether the payload is deployed into `runtime`'s tree.
    public static func isDeployed(for runtime: String?) -> Bool {
        isDeployed(inLibraryFolder: WhiskyWineInstaller.libraryFolder(for: runtime))
    }

    /// Testable seam for ``isDeployed()``: the unix bridge for dxgi and the
    /// shared dylib both present in the Wine tree.
    static func isDeployed(inLibraryFolder folder: URL) -> Bool {
        let lib = folder.appending(path: "Wine").appending(path: "lib")
        let bridge = lib.appending(path: "wine").appending(path: "x86_64-unix").appending(path: "dxgi.so")
        let dylib = lib.appending(path: "external").appending(path: "libd3dshared.dylib")
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: bridge.path(percentEncoded: false)) &&
            fileManager.fileExists(atPath: dylib.path(percentEncoded: false))
    }

    /// Deploys the stored payload into the runtime tree per Apple's documented
    /// layout: forwarders replace the Wine builtins (originals are backed up in
    /// the store), the unix bridges and `external/` are added alongside.
    ///
    /// Callers gate this on ``isRuntimeGPTKCapable()`` — deploying to an
    /// incapable runtime turns every D3DMetal launch into a crash.
    ///
    /// - Throws: ``GPTKImportError/storeNotVerified(_:)`` when the store fails
    ///   the checks an import applies (see ``verifyStoredPayload()``).
    public static func deployStoredPayload() throws {
        try deployStoredPayload(for: nil)
    }

    /// Deploys the stored payload into `runtime`'s tree.
    public static func deployStoredPayload(for runtime: String?) throws {
        let store = storeFolder
        if case let .failed(reason) = storeVerdict(inStore: store, isAppleSigned: isAppleSigned(_:identifier:)) {
            throw GPTKImportError.storeNotVerified(reason)
        }
        try deploy(
            fromStore: store,
            intoLibraryFolder: WhiskyWineInstaller.libraryFolder(for: runtime),
            originalsKey: originalsKey(for: runtime)
        )
    }

    /// Deploys the stored payload if there is one and the runtime can execute
    /// it, reporting whether it deployed.
    ///
    /// The store survives a runtime install but the deployed copy does not, so
    /// every install has to re-evaluate. Idempotent and safe to call anywhere.
    ///
    /// A runtime holding a payload copied in by hand is left as it is. This
    /// runs without anyone asking, every time Settings opens, and deploying
    /// would replace that payload, deleting its forwarders or filing them away
    /// as Wine's own. Importing is what replaces it.
    ///
    /// A store that fails the checks an import applies is not deployed either
    /// (see ``verifyStoredPayload()``).
    @discardableResult
    public static func deployStoredPayloadIfCapable() -> Bool {
        deployStoredPayloadIfCapable(for: nil)
    }

    /// ``deployStoredPayloadIfCapable()`` against a specific runtime.
    @discardableResult
    public static func deployStoredPayloadIfCapable(for runtime: String?) -> Bool {
        guard isRuntimeGPTKCapable(for: runtime) else { return false }
        return deployStoredPayloadIfPresent(
            fromStore: storeFolder,
            intoLibraryFolder: WhiskyWineInstaller.libraryFolder(for: runtime),
            originalsKey: originalsKey(for: runtime),
            isAppleSigned: isAppleSigned(_:identifier:)
        )
    }

    /// Testable seam for ``deployStoredPayloadIfCapable()``, past the runtime
    /// capability check.
    @discardableResult
    static func deployStoredPayloadIfPresent(
        fromStore store: URL,
        intoLibraryFolder folder: URL,
        originalsKey key: String = "default",
        isAppleSigned: (_ code: URL, _ identifier: String) -> Bool
    ) -> Bool {
        guard storedRecord(inStore: store) != nil else { return false }
        let verdict = verifyStoredPayload(inStore: store, libraryFolder: folder, isAppleSigned: isAppleSigned)
        guard verdict == .verified else {
            logger.info("Left the stored GPTK payload undeployed: it fails the checks an import applies")
            return false
        }
        guard !holdsHandPlacedPayload(inLibraryFolder: folder, usingStore: store) else {
            logger.info("Left the GPTK payload copied into the runtime by hand in place of the stored one")
            return false
        }
        do {
            try deploy(fromStore: store, intoLibraryFolder: folder, originalsKey: key)
            return true
        } catch {
            logger.error("Deploying the stored GPTK payload failed: \(error.localizedDescription)")
            return false
        }
    }

    /// What a sweep across the installed runtimes did: which it deployed
    /// into, and which capable runtime failed with what. A failure here means
    /// a runtime the UI reports as GPTK-ready can be missing half its payload,
    /// so the one caller with a user watching has to be able to say so.
    public struct DeploySweep: Sendable {
        public let deployed: [String?]
        public let failures: [String]
    }

    /// Deploys the stored payload into every installed runtime that can execute
    /// it, reporting the identifiers it reached and the failures it hit.
    ///
    /// Callers that used to deploy "into the runtime" now have several to
    /// choose from, and the useful default is all of the capable ones: an
    /// incapable runtime is skipped rather than broken.
    @discardableResult
    public static func deployStoredPayloadEverywhereCapable() -> DeploySweep {
        var deployed: [String?] = []
        var failures: [String] = []
        for runtime in WhiskyWineInstaller.installedRuntimes().map(\.runtime) {
            guard storedRecord() != nil, isRuntimeGPTKCapable(for: runtime) else { continue }
            do {
                try deployStoredPayload(for: runtime)
                deployed.append(runtime)
            } catch {
                logger.error("Deploying the stored GPTK payload failed: \(error.localizedDescription)")
                failures.append("\(runtime ?? "default"): \(error.localizedDescription)")
            }
        }
        return DeploySweep(deployed: deployed, failures: failures)
    }

    /// Testable seam for ``deployStoredPayload()``.
    static func deploy(fromStore store: URL, intoLibraryFolder folder: URL, originalsKey key: String = "default")
        throws {
        guard storedRecord(inStore: store) != nil else {
            throw GPTKImportError.storeEmpty
        }
        let fileManager = FileManager.default
        let storeLib = store.appending(path: "lib")
        let wineLib = folder.appending(path: "Wine").appending(path: "lib")
        let peDir = wineLib.appending(path: "wine").appending(path: "x86_64-windows")
        let unixDir = wineLib.appending(path: "wine").appending(path: "x86_64-unix")
        let originals = originalsFolder(inStore: store, key: key)
        try migrateFlatOriginals(inStore: store)
        try prepareOriginals(inStore: store, forLibraryFolder: folder, key: key)

        // A previous install leaves the interposer in the d3d12 slot, where it
        // matches neither Wine's DLL nor the store's forwarder. Clear it first
        // so the loop below sees the tree it expects and never files the
        // interposer away as if it were Wine's own builtin.
        removeVideoProcessor(fromLibraryFolder: folder, usingStore: store)

        try installForwarders(storeLib: storeLib, peDir: peDir, originals: originals)

        try fileManager.createDirectory(at: unixDir, withIntermediateDirectories: true)
        for name in unixLibraryNames {
            let link = unixDir.appending(path: name)
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(
                atPath: link.path(percentEncoded: false),
                withDestinationPath: unixLinkDestination
            )
        }

        // The framework copy is the long operation, so it runs to completion
        // beside the live tree before the old external/ is dropped: the window
        // with neither in place shrinks from the whole copy to one rename.
        let externalDest = wineLib.appending(path: "external")
        let externalStaged = wineLib.appending(path: "external.staging")
        try? fileManager.removeItem(at: externalStaged)
        try fileManager.copyItem(at: storeLib.appending(path: "external"), to: externalStaged)
        if fileManager.fileExists(atPath: externalDest.path(percentEncoded: false)) {
            try fileManager.removeItem(at: externalDest)
        }
        try fileManager.moveItem(at: externalStaged, to: externalDest)
        // Apple's payload is in place now, which is the only moment the bridge
        // can be installed: it forwards into the payload's own shared dylib and
        // has nothing to bind to before this point.
        try installMetalFXBridge(intoLibraryFolder: folder, usingStore: store)
        // Apple's DLLs are in place now, which is the only moment the swaps can
        // be made: the runtime ships the interposers but has nothing to forward
        // into until this point. A payload from a build they were never
        // validated on is deployed without them; install checks the version.
        for interposer in interposers {
            try install(interposer, intoLibraryFolder: folder)
        }
        try installNVAPIBridge(intoLibraryFolder: folder, usingStore: store)
        logger.info("Deployed GPTK payload into the runtime tree")
    }

    /// Swaps Wine's builtins for the store's forwarders, backing up what Wine
    /// shipped.
    private static func installForwarders(storeLib: URL, peDir: URL, originals: URL) throws {
        let fileManager = FileManager.default
        for name in forwarderDLLNames {
            let target = peDir.appending(path: name)
            let backup = originals.appending(path: name)
            // The incoming copy lands beside the slot before the slot is
            // touched, so a copy that dies partway leaves the tree exactly as
            // it was rather than minus one builtin.
            let staged = target.appendingPathExtension("staging")
            try? fileManager.removeItem(at: staged)
            try fileManager.copyItem(
                at: storeLib.appending(path: "wine").appending(path: "x86_64-windows").appending(path: name),
                to: staged
            )
            // Back up whatever Wine shipped, once; a redeploy over an existing
            // GPTK forwarder must not overwrite the original with Apple's copy.
            if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                if !fileManager.fileExists(atPath: backup.path(percentEncoded: false)),
                   !isGPTKForwarder(target, matching: storeLib) {
                    try fileManager.moveItem(at: target, to: backup)
                } else {
                    try fileManager.removeItem(at: target)
                }
            }
            try fileManager.moveItem(at: staged, to: target)
        }
    }

    /// Whether `dll` is byte-identical to the store's forwarder of the same
    /// name, so deploy never mistakes an already-deployed Apple DLL for a Wine
    /// original worth backing up and remove only deletes what it put there.
    static func isGPTKForwarder(_ dll: URL, matching storeLib: URL) -> Bool {
        let storeDLL = storeLib.appending(path: "wine").appending(path: "x86_64-windows")
            .appending(path: dll.lastPathComponent)
        return FileManager.default.contentsEqual(
            atPath: dll.path(percentEncoded: false),
            andPath: storeDLL.path(percentEncoded: false)
        )
    }

    /// Removes the payload from the runtime tree and restores the backed-up
    /// Wine originals.
    public static func removeDeployedPayload() throws {
        try removeDeployedPayload(for: nil)
    }

    /// Removes the payload from `runtime`'s tree and restores its originals.
    public static func removeDeployedPayload(for runtime: String?) throws {
        try remove(
            fromLibraryFolder: WhiskyWineInstaller.libraryFolder(for: runtime),
            usingStore: storeFolder,
            originalsKey: originalsKey(for: runtime)
        )
    }

    /// Removes the payload from every installed runtime.
    public static func removeDeployedPayloadEverywhere() throws {
        for runtime in WhiskyWineInstaller.installedRuntimes().map(\.runtime) {
            try removeDeployedPayload(for: runtime)
        }
    }

    /// Testable seam for ``removeDeployedPayload()``.
    static func remove(fromLibraryFolder folder: URL, usingStore store: URL, originalsKey key: String = "default")
        throws {
        let fileManager = FileManager.default
        let wineLib = folder.appending(path: "Wine").appending(path: "lib")
        let peDir = wineLib.appending(path: "wine").appending(path: "x86_64-windows")
        let unixDir = wineLib.appending(path: "wine").appending(path: "x86_64-unix")
        try migrateFlatOriginals(inStore: store)
        let originals = originalsFolder(inStore: store, key: key)
        let storeLib = store.appending(path: "lib")

        let originalsAreCurrent = originalsRecord(inStore: store, key: key)?.runtimeVersion
            == runtimeVersionStamp(inLibraryFolder: folder)

        removeMetalFXBridge(fromLibraryFolder: folder, usingStore: store)
        // Apple's DLL goes back into the d3d12 slot before the loop reads it,
        // or the slot still holds the interposer, fails the byte match against
        // the store, and is skipped: the tree would keep a d3d12 that forwards
        // to a DLL this call is about to delete.
        removeVideoProcessor(fromLibraryFolder: folder, usingStore: store)
        removeNVAPIBridge(fromLibraryFolder: folder, usingStore: store)

        for name in forwarderDLLNames {
            let backup = originals.appending(path: name)
            let hasBackup = fileManager.fileExists(atPath: backup.path(percentEncoded: false))

            // Backups from a replaced engine: drop them and leave the tree,
            // which this store never deployed into, untouched.
            guard originalsAreCurrent else {
                if hasBackup {
                    try fileManager.removeItem(at: backup)
                }
                continue
            }

            // An interrupted deploy leaves some names still holding Wine's own
            // DLL, never backed up; deleting one loses a builtin with nothing
            // to put back. Only what byte-matches the store came from here.
            let deployed = peDir.appending(path: name)
            if fileManager.fileExists(atPath: deployed.path(percentEncoded: false)) {
                guard isGPTKForwarder(deployed, matching: storeLib) else { continue }
                try fileManager.removeItem(at: deployed)
            }
            if hasBackup {
                try fileManager.moveItem(at: backup, to: deployed)
            }
        }

        // removeItem operates on the link itself, so this also clears a
        // dangling symlink that fileExists (which follows links) would miss.
        for name in unixLibraryNames {
            try? fileManager.removeItem(at: unixDir.appending(path: name))
        }

        let external = wineLib.appending(path: "external")
        if fileManager.fileExists(atPath: external.path(percentEncoded: false)) {
            try fileManager.removeItem(at: external)
        }
        logger.info("Removed GPTK payload from the runtime tree")
    }
}
