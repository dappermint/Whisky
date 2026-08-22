//
//  SteamFrontend.swift
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

/// The operations Whisky needs from the macOS Steam client, expressed as the
/// JavaScript that performs them.
///
/// Every one of these exists because the client will not do the thing on its
/// own for a Windows title. Its Install button leaves the manifest written and
/// nothing downloaded, its Play button answers `AppError_29`, and the settings
/// page that would let you choose otherwise is hidden behind a check for
/// whether the platform is Linux.
///
/// The scripts are separate from the connection so they can be read and tested
/// without a client running, which matters because a wrong one fails inside
/// Steam's UI where there is nothing to see.
public enum SteamFrontendScript {
    /// The platforms a title ships builds for, as Steam records them.
    ///
    /// `["windows"]` for a Windows-only title, `["windows","osx","linux"]` for
    /// one with a native macOS build. This is the honest way to tell them
    /// apart; everything else is guessing from install paths or names.
    public static func platforms(forAppId appId: Int) -> String {
        """
        (async () => {
          await appDetailsStore.RequestAppDetails(\(appId));
          const details = appDetailsStore.GetAppDetails(\(appId));
          return JSON.stringify(details ? details.vecPlatforms : []);
        })()
        """
    }

    /// The compatibility tool a title is set to run through, empty when none.
    public static func compatTool(forAppId appId: Int) -> String {
        """
        (async () => {
          await appDetailsStore.RequestAppDetails(\(appId));
          const details = appDetailsStore.GetAppDetails(\(appId));
          return details ? details.strCompatToolName : "";
        })()
        """
    }

    /// Points a title at a compatibility tool, or clears it with an empty name.
    ///
    /// The client persists this into `config.vdf` and does not show it in its
    /// own state until it restarts, which is why reading it straight back
    /// answers with the old value rather than the one just written.
    public static func useCompatTool(_ name: String, forAppId appId: Int) -> String {
        "SteamClient.Apps.SpecifyCompatTool(\(appId), \(jsonString(name))), true"
    }

    /// The compatibility tools the client will offer for a title.
    public static func availableCompatTools(forAppId appId: Int) -> String {
        """
        (async () => {
          const tools = await SteamClient.Apps.GetAvailableCompatTools(\(appId));
          return JSON.stringify((tools || []).map(tool => tool.strToolName));
        })()
        """
    }

    /// Downloads a title's Windows build into a library folder.
    ///
    /// Two console commands, and both are needed. Without the platform
    /// override the client writes an app manifest and fetches nothing, leaving
    /// the title in a state it will not retry from, so a half-installed one has
    /// to be uninstalled before this will work. The folder index is the one
    /// `SteamClient.InstallFolder.GetInstallFolders()` reports.
    public static func installWindowsBuild(appId: Int, libraryFolder: Int) -> String {
        """
        (() => {
          SteamClient.Console.ExecCommand("@sSteamCmdForcePlatformType windows");
          SteamClient.Console.ExecCommand("app_install \(appId) \(libraryFolder)");
          return true;
        })()
        """
    }

    /// Puts the client's platform override back, so its own downloads are
    /// native again.
    public static func clearPlatformOverride() -> String {
        #"SteamClient.Console.ExecCommand("@sSteamCmdForcePlatformType \"\""), true"#
    }

    /// Hands a launch to Whisky through the URL scheme.
    ///
    /// The way out of the client for a title it will not launch itself. Whisky
    /// resolves the bottle, the GameDB profile and the per-program overrides
    /// from the App ID alone, so nothing else has to cross.
    public static func launchThroughWhisky(appId: Int, bottle: String? = nil) -> String {
        var url = "whisky://launch?steam=\(appId)"
        if let bottle, let escaped = bottle.addingPercentEncoding(
            withAllowedCharacters: Self.queryValueAllowed
        ) {
            url += "&bottle=\(escaped)"
        }
        return "SteamClient.System.OpenInSystemBrowser(\(jsonString(url))), true"
    }

    /// The library folders the client can install into, index first.
    public static func installFolders() -> String {
        """
        (async () => {
          const folders = await SteamClient.InstallFolder.GetInstallFolders();
          return JSON.stringify((folders || []).map(f => [f.nFolderIndex, f.strFolderPath]));
        })()
        """
    }

    /// What may appear unencoded in a query value: everything a query allows
    /// except the two characters that would end the value or start another.
    static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return allowed
    }()

    /// A Swift string as a JavaScript string literal.
    ///
    /// Written through `JSONSerialization` rather than by hand because a tool
    /// or bottle name is user input reaching a script, and a quote in one would
    /// otherwise end the literal early and run whatever followed.
    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(bytes: data, encoding: .utf8)
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}

/// Drives the macOS Steam client's interface to do what it will not do for a
/// Windows title on its own.
public actor SteamFrontend {
    private let devTools: SteamDevTools

    public init(devTools: SteamDevTools = SteamDevTools()) {
        self.devTools = devTools
    }

    /// Attaches to the client, if it is running with debugging enabled.
    public func connect() async throws {
        try await devTools.connect()
    }

    /// The platforms a title ships builds for.
    public func platforms(forAppId appId: Int) async throws -> [String] {
        try await Self.decodeStrings(
            from: devTools.evaluate(SteamFrontendScript.platforms(forAppId: appId))
        )
    }

    /// Whether a title has to run in a bottle rather than natively.
    ///
    /// The platform list alone cannot answer this once Steam Play is on. The
    /// client synthesises `osx` into `vecPlatforms` for any title a
    /// compatibility tool covers, so Helldivers 2 and a genuinely native game
    /// read the same. What separates them is the tool: the client attaches one
    /// only where there is no native build to run, so a title with a tool
    /// assigned is a title macOS cannot run on its own.
    ///
    /// The platform list is still the answer before any tool exists, which is
    /// the state a fresh install is in.
    public func needsBottle(appId: Int) async throws -> Bool {
        if try await !compatTool(forAppId: appId).isEmpty { return true }
        let platforms = try await platforms(forAppId: appId)
        return platforms.contains("windows") && !platforms.contains("osx")
    }

    /// The compatibility tool a title is set to run through, empty when none.
    public func compatTool(forAppId appId: Int) async throws -> String {
        let value = try await devTools.evaluate(SteamFrontendScript.compatTool(forAppId: appId))
        return Self.unquote(value) ?? ""
    }

    /// The compatibility tools the client offers for a title.
    public func availableCompatTools(forAppId appId: Int) async throws -> [String] {
        try await Self.decodeStrings(
            from: devTools.evaluate(SteamFrontendScript.availableCompatTools(forAppId: appId))
        )
    }

    /// Points a title at a compatibility tool. Takes effect on the client's
    /// next start.
    public func useCompatTool(_ name: String, forAppId appId: Int) async throws {
        try await devTools.evaluate(SteamFrontendScript.useCompatTool(name, forAppId: appId))
    }

    /// Downloads a title's Windows build into a library folder.
    public func installWindowsBuild(appId: Int, libraryFolder: Int) async throws {
        try await devTools.evaluate(
            SteamFrontendScript.installWindowsBuild(appId: appId, libraryFolder: libraryFolder)
        )
    }

    /// Puts the client's platform override back.
    public func clearPlatformOverride() async throws {
        try await devTools.evaluate(SteamFrontendScript.clearPlatformOverride())
    }

    /// Hands a launch to Whisky.
    public func launchThroughWhisky(appId: Int, bottle: String? = nil) async throws {
        try await devTools.evaluate(
            SteamFrontendScript.launchThroughWhisky(appId: appId, bottle: bottle)
        )
    }

    /// The library folders the client can install into.
    public func installFolders() async throws -> [(index: Int, path: String)] {
        let json = try await devTools.evaluate(SteamFrontendScript.installFolders())
        guard let unquoted = Self.unquote(json),
              let rows = try? JSONSerialization.jsonObject(with: Data(unquoted.utf8)) as? [[Any]]
        else { return [] }
        return rows.compactMap { row in
            guard row.count == 2, let index = row[0] as? Int, let path = row[1] as? String
            else { return nil }
            return (index, path)
        }
    }

    /// Decodes a JSON array of strings that arrived as a JSON string.
    ///
    /// The scripts return `JSON.stringify(...)` rather than the array itself,
    /// because the protocol's by-value encoding flattens some objects into
    /// nothing and a string always survives it intact.
    static func decodeStrings(from json: String) throws -> [String] {
        guard let unquoted = unquote(json),
              let values = try? JSONSerialization.jsonObject(with: Data(unquoted.utf8)) as? [String]
        else { return [] }
        return values
    }

    /// Turns a JSON string value back into the text it holds.
    static func unquote(_ json: String) -> String? {
        guard let wrapped = try? JSONSerialization.jsonObject(
            with: Data("[\(json)]".utf8)
        ) as? [Any],
            let value = wrapped.first as? String
        else { return nil }
        return value
    }
}
