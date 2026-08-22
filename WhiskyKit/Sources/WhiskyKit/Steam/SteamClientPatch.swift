//
//  SteamClientPatch.swift
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

/// One of the three edits that make compatibility tools usable on macOS.
public enum SteamClientPatchPart: String, CaseIterable, Sendable {
    /// `steam.cfg` beside the client, which stops the bootstrapper undoing the
    /// other two.
    case bootstrapperInhibit
    /// The compare in `steamclient.dylib` that decides whether compatibility
    /// tools exist at all.
    case client
    /// The check in the interface bundle that hides the Compatibility settings.
    case interface
}

/// What state the macOS Steam client is in.
public enum SteamClientPatchStatus: Equatable, Sendable {
    /// Steam is not installed.
    case steamNotInstalled
    /// Untouched.
    case notApplied
    /// All three parts are in place.
    case applied
    /// Some parts survived and some did not, which is what a Steam update
    /// leaves behind.
    case partiallyApplied(missing: [SteamClientPatchPart])
    /// A part could not be found in the shape this knows how to edit, so the
    /// client has changed too much to patch blindly.
    case unrecognised(SteamClientPatchPart)
}

/// Errors thrown while patching the macOS Steam client.
public enum SteamClientPatchError: LocalizedError, Equatable {
    case steamNotInstalled
    case steamRunning
    case notFound(SteamClientPatchPart)
    case signingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .steamNotInstalled:
            String(localized: "steam.patch.error.notInstalled")
        case .steamRunning:
            String(localized: "steam.patch.error.running")
        case let .notFound(part):
            String(localized: "steam.patch.error.notFound \(part.rawValue)")
        case let .signingFailed(message):
            String(localized: "steam.patch.error.signing \(message)")
        }
    }
}

/// Makes compatibility tools usable in the macOS Steam client, and puts it back.
///
/// Valve builds the whole compatibility manager for macOS and then switches it
/// off with a string compare: `CCompatManager`'s constructor sets a byte to
/// whether the platform reads as Linux, and the only function that asks whether
/// tools are enabled reads that byte and nothing else. No setting reaches it.
/// The interface hides its Compatibility pages behind the same question in
/// JavaScript.
///
/// So three edits, and all three are needed. The third exists because the
/// client verifies its own executables at startup and reinstalls anything that
/// does not match, which undoes the other two within one launch.
///
/// Nothing here hunts for a fixed offset. The client is found by the shape of
/// the code around the compare, so a Steam update moves it without breaking
/// this, and anything that no longer matches is reported rather than patched.
public enum SteamClientPatch {
    // MARK: - Locations

    static func clientDirectory(steamRoot: URL) -> URL {
        steamRoot
            .appending(path: "Steam.AppBundle")
            .appending(path: "Steam")
            .appending(path: "Contents")
            .appending(path: "MacOS")
    }

    static func dylib(steamRoot: URL) -> URL {
        clientDirectory(steamRoot: steamRoot).appending(path: "steamclient.dylib")
    }

    static func interfaceBundle(steamRoot: URL) -> URL {
        clientDirectory(steamRoot: steamRoot).appending(path: "steamui").appending(path: "library.js")
    }

    /// The bootstrapper reads this from its own directory. A copy in the data
    /// root is ignored and the repair runs anyway, which is a full afternoon's
    /// worth of confusing evidence.
    static func inhibitFile(steamRoot: URL) -> URL {
        clientDirectory(steamRoot: steamRoot).appending(path: "steam.cfg")
    }

    static func backup(of url: URL) -> URL {
        url.appendingPathExtension("valve-original")
    }

    static let inhibitContents = """
    BootStrapperInhibitAll=enable
    BootStrapperInhibitClientChecksum=enable
    BootStrapperInhibitUpdateOnLaunch=enable

    """

    // MARK: - Status

    /// What state the client is in, without changing anything.
    public static func status(steamRoot: URL = HostSteam.defaultRoot) -> SteamClientPatchStatus {
        guard HostSteam.installRoot(at: steamRoot) != nil else { return .steamNotInstalled }

        var missing: [SteamClientPatchPart] = []

        if !isInhibited(steamRoot: steamRoot) { missing.append(.bootstrapperInhibit) }

        switch clientState(steamRoot: steamRoot) {
        case .patched: break
        case .patchable: missing.append(.client)
        case .unrecognised: return .unrecognised(.client)
        }

        switch interfaceState(steamRoot: steamRoot) {
        case .patched: break
        case .patchable: missing.append(.interface)
        case .unrecognised: return .unrecognised(.interface)
        }

        if missing.isEmpty { return .applied }
        if missing.count == SteamClientPatchPart.allCases.count { return .notApplied }
        return .partiallyApplied(missing: missing)
    }

    /// Whether anything has to be done, which is the question a menu item asks.
    public static func needsApplying(steamRoot: URL = HostSteam.defaultRoot) -> Bool {
        switch status(steamRoot: steamRoot) {
        case .notApplied, .partiallyApplied: true
        case .applied, .steamNotInstalled, .unrecognised: false
        }
    }

    enum PartState { case patched, patchable, unrecognised }

    static func isInhibited(steamRoot: URL) -> Bool {
        guard let text = try? String(contentsOf: inhibitFile(steamRoot: steamRoot), encoding: .utf8)
        else { return false }
        return text.contains("BootStrapperInhibitClientChecksum=enable")
    }

    static func clientState(steamRoot: URL) -> PartState {
        guard let data = try? Data(contentsOf: dylib(steamRoot: steamRoot)),
              let slice = MachOImage.arm64Slice(of: data),
              let gate = findCompatGate(in: data, slice: slice)
        else { return .unrecognised }
        return gate.isPatched ? .patched : .patchable
    }

    static func interfaceState(steamRoot: URL) -> PartState {
        guard let source = try? String(contentsOf: interfaceBundle(steamRoot: steamRoot), encoding: .utf8)
        else { return .unrecognised }
        if source.contains(Self.openedInterfaceGate) { return .patched }
        return interfaceGateRange(in: source) != nil ? .patchable : .unrecognised
    }

    // MARK: - Applying

    /// Applies whatever is missing, leaving anything already done alone.
    ///
    /// - Throws: ``SteamClientPatchError``.
    public static func apply(steamRoot: URL = HostSteam.defaultRoot) throws {
        guard HostSteam.installRoot(at: steamRoot) != nil else {
            throw SteamClientPatchError.steamNotInstalled
        }
        guard !HostSteamProcess.isRunning() else { throw SteamClientPatchError.steamRunning }

        // The inhibit goes first. Patching before it lets the bootstrapper
        // repair the work on the very next launch.
        try inhibitContents.write(
            to: inhibitFile(steamRoot: steamRoot), atomically: true, encoding: .utf8
        )

        try applyClientPatch(steamRoot: steamRoot)
        try applyInterfacePatch(steamRoot: steamRoot)
    }

    static func applyClientPatch(steamRoot: URL) throws {
        let target = dylib(steamRoot: steamRoot)
        guard let data = try? Data(contentsOf: target),
              let slice = MachOImage.arm64Slice(of: data),
              let gate = findCompatGate(in: data, slice: slice)
        else { throw SteamClientPatchError.notFound(.client) }
        if gate.isPatched { return }

        let backup = backup(of: target)
        if !FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) {
            try FileManager.default.copyItem(at: target, to: backup)
        }

        var patched = data
        patched.replaceSubrange(
            gate.fileOffset ..< gate.fileOffset + 4, with: MachOImage.movImmediateOne(register: gate.register)
        )
        try patched.write(to: target)
        try resign(target)
    }

    static func applyInterfacePatch(steamRoot: URL) throws {
        let target = interfaceBundle(steamRoot: steamRoot)
        guard let source = try? String(contentsOf: target, encoding: .utf8)
        else { throw SteamClientPatchError.notFound(.interface) }
        if source.contains(openedInterfaceGate) { return }
        guard let range = interfaceGateRange(in: source) else {
            throw SteamClientPatchError.notFound(.interface)
        }

        let backup = backup(of: target)
        if !FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) {
            try FileManager.default.copyItem(at: target, to: backup)
        }

        try source.replacingCharacters(in: range, with: openedInterfaceGate)
            .write(to: target, atomically: true, encoding: .utf8)
    }

    /// Puts everything back and lets Steam update itself again.
    public static func revert(steamRoot: URL = HostSteam.defaultRoot) throws {
        guard !HostSteamProcess.isRunning() else { throw SteamClientPatchError.steamRunning }

        for target in [dylib(steamRoot: steamRoot), interfaceBundle(steamRoot: steamRoot)] {
            let backup = backup(of: target)
            guard FileManager.default.fileExists(atPath: backup.path(percentEncoded: false))
            else { continue }
            _ = try FileManager.default.replaceItemAt(target, withItemAt: backup)
        }
        try? FileManager.default.removeItem(at: inhibitFile(steamRoot: steamRoot))
    }

    // MARK: - The client's gate

    /// Where the compatibility gate is, and whether it is already open.
    struct CompatGate: Equatable {
        /// Byte offset of the instruction that decides the answer.
        let fileOffset: Int
        /// The register it writes, which the replacement has to write too.
        let register: UInt32
        /// Whether that instruction has already been replaced.
        let isPatched: Bool
    }

    /// Finds the compare that decides whether compatibility tools exist.
    ///
    /// The shape, rather than an address, because an address only holds until
    /// the next Steam update:
    ///
    /// ```
    /// adrp x1, <page of "linux">     ; a reference to the string
    /// add  x1, x1, #<offset>
    /// bl   _V_strnicmp               ; a few instructions later
    /// cmp  w0, #0
    /// cset wN, eq                    ; <- the answer
    /// strb wN, [xM, #imm]            ; stored on the manager
    /// ```
    ///
    /// A `mov wN, #1` where the `cset` was is the patch, and finding one there
    /// is how an already-patched client is recognised.
    static func findCompatGate(in data: Data, slice: MachOImage.Slice) -> CompatGate? {
        guard let text = MachOImage.section(named: "__text", segment: "__TEXT", in: data, slice: slice),
              let linux = MachOImage.address(of: "linux", in: data, slice: slice)
        else { return nil }

        let instructions = MachOImage.instructions(in: data, section: text)
        var pendingPages: [UInt32: UInt64] = [:]

        for (index, insn) in instructions.enumerated() {
            if let (register, page) = Arm64.adrp(insn, at: text.address &+ UInt64(index * 4)) {
                pendingPages[register] = page
                continue
            }
            guard let add = Arm64.addImmediate(insn),
                  let page = pendingPages[add.source],
                  page &+ UInt64(add.immediate) == linux
            else { continue }

            // The compare follows within a handful of instructions.
            for lookahead in (index + 1) ..< min(index + 10, instructions.count - 1) {
                let candidate = instructions[lookahead]
                let next = instructions[lookahead + 1]
                guard let stored = Arm64.storeByteRegister(next) else { continue }

                if let set = Arm64.csetEqual(candidate), set == stored {
                    return CompatGate(
                        fileOffset: text.fileOffset + lookahead * 4, register: set, isPatched: false
                    )
                }
                if let moved = Arm64.movImmediateOneRegister(candidate), moved == stored {
                    return CompatGate(
                        fileOffset: text.fileOffset + lookahead * 4, register: moved, isPatched: true
                    )
                }
            }
        }
        return nil
    }

    // MARK: - The interface's gate

    /// What the gate is replaced with, and how an already-patched bundle is
    /// recognised.
    static let openedInterfaceGate = "function C(){return!0}"

    /// Finds the check that hides the Compatibility pages.
    ///
    /// Matched by shape rather than exact text: the bundle is minified, so the
    /// function and module names change between builds while the comparison
    /// does not.
    static func interfaceGateRange(in source: String) -> Range<String.Index>? {
        let pattern = #"function [A-Za-z_$][\w$]*\(\)\{return"linux"==[A-Za-z_$][\w$]*\.TS\.PLATFORM\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: source, range: NSRange(source.startIndex ..< source.endIndex, in: source)
              )
        else { return nil }
        return Range(match.range, in: source)
    }

    // MARK: - Signing

    /// Signs an edited file ad hoc, because the edit invalidates Valve's
    /// signature and dyld then refuses to load it.
    ///
    /// The stale signature is removed first: signing over it fails with "main
    /// executable failed strict validation". And a fresh copy is signed rather
    /// than the file in place, because `codesign` refuses anything carrying
    /// `com.apple.provenance`, which cannot be removed from a file that has it.
    static func resign(_ url: URL) throws {
        let staging = url.appendingPathExtension("signing")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: url, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }

        try run("/usr/bin/xattr", ["-c", staging.path(percentEncoded: false)])
        try? run("/usr/bin/codesign", ["--remove-signature", staging.path(percentEncoded: false)])
        try run("/usr/bin/codesign", ["-f", "-s", "-", staging.path(percentEncoded: false)])

        _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        let data = try? errors.fileHandleForReading.readToEnd()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = data.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            throw SteamClientPatchError.signingFailed(
                message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
