// swiftlint:disable function_body_length
//
//  WineEnvironment.swift
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

let envLogger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "WineEnvironment")

// swiftlint:disable cyclomatic_complexity
extension Wine {
    /// Construct an environment merging the bottle values with the given values
    /// using EnvironmentBuilder with 8-layer resolution.
    ///
    /// Each Wine process launch resolves through this method, which populates
    /// an ``EnvironmentBuilder`` with base, platform, bottleManaged, launcherManaged,
    /// bottleUser, programUser, featureRuntime, and callsiteOverride layers.
    /// WINEDLLOVERRIDES is composed per-DLL via ``DLLOverrideResolver``.
    ///
    /// Invalid environment variable keys (those not matching `[A-Za-z_][A-Za-z0-9_]*`)
    /// are filtered out with a debug log message, as macOS silently ignores them.
    ///
    /// - Parameters:
    ///   - bottle: The bottle whose settings configure the environment.
    ///   - environment: Caller-provided environment variables (typically from `Program.generateEnvironment()`).
    ///   - programOverrides: Optional per-program setting overrides. `nil` fields inherit from bottle.
    /// - Returns: The fully resolved environment dictionary for passing to a Wine process.
    @MainActor
    public static func constructWineEnvironment(
        for bottle: Bottle,
        environment: [String: String] = [:],
        programOverrides: ProgramOverrides? = nil,
        programSettings: ProgramSettings? = nil,
        gameProfileEnvironment: [String: String] = [:]
    ) -> [String: String] {
        constructWineEnvironmentWithProvenance(
            for: bottle,
            environment: environment,
            programOverrides: programOverrides,
            programSettings: programSettings,
            gameProfileEnvironment: gameProfileEnvironment
        ).environment
    }

    /// The same construction, keeping the per-key provenance so an inspector
    /// can say which layer set each variable and why. `logSummary` is off for
    /// inspection so browsing settings never writes launch lines to the log.
    @MainActor
    public static func constructWineEnvironmentWithProvenance(
        for bottle: Bottle,
        environment: [String: String] = [:],
        programOverrides: ProgramOverrides? = nil,
        programSettings: ProgramSettings? = nil,
        gameProfileEnvironment: [String: String] = [:],
        logSummary: Bool = true
    ) -> (environment: [String: String], provenance: EnvironmentProvenance) {
        var builder = EnvironmentBuilder()
        var dllResolver = DLLOverrideResolver(managed: [], bottleCustom: [], programCustom: [])

        // Layer 1: Base -- WINEPREFIX, default WINEDEBUG, GST_DEBUG
        builder.set("WINEPREFIX", bottle.url.path, layer: .base)
        builder.set("WINEDEBUG", "fixme-all", layer: .base)
        builder.set("GST_DEBUG", "1", layer: .base)

        // Layer 2: Platform -- macOS compatibility fixes
        // Apply fixes from the MacOSCompatibilityFixes registry with reason strings.
        // applyMacOSCompatibilityFixes() is still called for the conditional WINEESYNC logic.
        for fix in MacOSCompatibilityFixes.activeFixes() {
            builder.set(fix.key, fix.value, layer: .platform, reason: fix.reason)
        }
        // Forward host timezone so games that read system time/date behave correctly.
        // macOS does not export TZ by default; without this, Wine sees UTC.
        if ProcessInfo.processInfo.environment["TZ"] == nil {
            builder.set(
                "TZ", TimeZone.current.identifier, layer: .platform,
                reason: "Host timezone forwarding"
            )
        }
        // Handle conditional WINEESYNC (depends on existing environment state)
        var platformConditional: [String: String] = [:]
        applyMacOSCompatibilityFixes(to: &platformConditional)
        if let esync = platformConditional["WINEESYNC"] {
            builder.set(
                "WINEESYNC", esync, layer: .platform,
                reason: "Fallback sync mode for macOS 15.4+ (esync/msync not otherwise set)"
            )
        }

        // Layer 3: Bottle managed -- settings-derived env vars (DXVK, sync, Metal, perf)
        let managedOverrides = bottle.settings.populateBottleManagedLayer(builder: &builder)
        dllResolver.managed.append(contentsOf: managedOverrides)

        // DXVK reads its config from DXVK_CONFIG_FILE or the process working
        // directory, and the working directory of a launch is never the bottle
        // root the config editor writes to, so without this line the file is
        // decoration. Z: maps the host filesystem and DXVK's PE build accepts
        // forward slashes.
        let dxvkConf = bottle.url.appending(path: "dxvk.conf")
        if FileManager.default.fileExists(atPath: dxvkConf.path(percentEncoded: false)) {
            builder.set(
                "DXVK_CONFIG_FILE", "Z:\(dxvkConf.path(percentEncoded: false))",
                layer: .bottleManaged, reason: "dxvk.conf present in the bottle"
            )
        }

        // Layer 4: Launcher managed -- launcher compatibility overrides
        let launcherOverrides = bottle.settings.populateLauncherManagedLayer(builder: &builder)
        dllResolver.managed.append(contentsOf: launcherOverrides)

        // Input compatibility (bottleManaged layer -- input settings are bottle-managed toggles)
        bottle.settings.populateInputCompatibilityLayer(builder: &builder)

        // Layer 5: Game profile -- GameDB variant environment for this launch.
        // Beats bottle/launcher defaults, loses to anything the user set.
        for (key, value) in gameProfileEnvironment {
            if isValidEnvKey(key) {
                builder.set(key, value, layer: .gameProfile, reason: "GameDB profile")
            } else {
                envLogger.debug("Skipping invalid game profile key '\(key)' in constructWineEnvironment")
            }
        }

        // Layer 6: Bottle user (empty for now -- no bottle-level custom env vars UI yet)

        // Layer 7: Program user (caller-provided environment dict, typically from Program.generateEnvironment())
        if !environment.isEmpty {
            for (key, value) in environment {
                if isValidEnvKey(key) {
                    builder.set(key, value, layer: .programUser)
                } else {
                    envLogger.debug("Skipping invalid environment key '\(key)' in constructWineEnvironment")
                }
            }
        }

        // Apply per-program overrides to the programUser layer
        if let overrides = programOverrides {
            applyProgramOverrides(
                overrides, runtime: bottle.settings.runtime, builder: &builder, dllResolver: &dllResolver
            )
        }

        // Layer 8: featureRuntime -- the diagnostic preset, which yields to a WINEDEBUG the user set
        programSettings?.activeWineDebugPreset?.applyIfUnset(in: &builder)

        // Layer 9: callsiteOverride is left empty (populated by direct callers)

        // Collect bottle custom DLL overrides for the resolver
        dllResolver.bottleCustom = bottle.settings.dllOverrides

        // Resolve the builder and capture provenance for launch logging
        let (resolved, provenance) = builder.resolve()
        var result = resolved

        // Compose WINEDLLOVERRIDES from DLLOverrideResolver (outside the builder)
        let (overrideString, _) = dllResolver.resolve()
        if !overrideString.isEmpty {
            result["WINEDLLOVERRIDES"] = overrideString
        }

        // Launch logging: safe summary of bottle, active layers, and whitelisted keys
        if logSummary {
            logLaunchSummary(bottleName: bottle.settings.name, provenance: provenance, environment: result)
        }

        return (environment: result, provenance: provenance)
    }
}

// swiftlint:enable cyclomatic_complexity
// swiftlint:enable function_body_length
