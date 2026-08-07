//
//  GraphicsBackendResolver.swift
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

/// Resolves the `.recommended` graphics backend to a concrete backend.
///
/// This is a caseless enum (static methods only) following the ``GPUDetection`` pattern.
/// The resolver centralises the heuristic so that future improvements (e.g., preferring
/// DXVK on specific GPU families) can be made without changing the data model or UI.
public enum GraphicsBackendResolver {
    /// Resolves the recommended graphics backend for the current system.
    ///
    /// D3DMetal is the best-supported path on macOS 15+ Apple Silicon, but only
    /// GPTK-based runtimes bundle its payload. Recommending it on a runtime
    /// without the payload makes launches silently fall back to wined3d, which
    /// cannot bring up D3D11 on current macOS — so the resolver only recommends
    /// backends that are actually installed: DXMT (native D3D11-to-Metal) when
    /// the runtime bundles it, otherwise DXVK, which ships with every runtime.
    ///
    /// - Parameters:
    ///   - macOSVersion: The macOS version to consider. Defaults to the running system.
    ///   - runtimeInfo: The runtime record to consider. Defaults to the installed
    ///     runtime's version plist.
    ///   - d3dMetalInstalled: Whether the D3DMetal payload exists on disk. Defaults
    ///     to checking the installed runtime.
    /// - Returns: A concrete ``GraphicsBackend`` (never `.recommended`).
    public static func resolve(
        for launcher: LauncherType? = nil,
        macOSVersion: MacOSVersion = .current,
        runtimeInfo: WhiskyWineVersion? = WhiskyWineInstaller.whiskyWineInfo(),
        d3dMetalInstalled: Bool = WhiskyWineInstaller.isD3DMetalInstalled()
    ) -> GraphicsBackend {
        if d3dMetalInstalled {
            // Launcher clients are Chromium, and Chromium cannot render on
            // D3DMetal: the window is created, the process tree looks healthy,
            // and nothing ever paints. Measured on Steam, whose client sat at
            // luma 0.0 indefinitely with nine processes running.
            //
            // Only the launcher itself. Games it starts still resolve to
            // D3DMetal, which is the reason to have it installed at all, and
            // per-executable overrides are what keep the two apart.
            if launcher != nil {
                return .dxvk
            }
            return .d3dMetal
        }
        if GraphicsBackend.dxmt.isAvailable(runtimeInfo: runtimeInfo) {
            return .dxmt
        }
        return .dxvk
    }

    /// ``resolve(macOSVersion:runtimeInfo:d3dMetalInstalled:)`` against a
    /// specific runtime.
    ///
    /// D3DMetal is deployed per runtime, so "recommended" is a different answer
    /// on a GPTK runtime than on Whisky's own — resolving against the singleton
    /// would recommend D3DMetal to a bottle whose runtime does not carry it.
    public static func resolve(
        for runtime: String?, launcher: LauncherType? = nil, macOSVersion: MacOSVersion = .current
    ) -> GraphicsBackend {
        resolve(
            for: launcher,
            macOSVersion: macOSVersion,
            runtimeInfo: WhiskyWineInstaller.whiskyWineInfo(for: runtime),
            d3dMetalInstalled: WhiskyWineInstaller.isD3DMetalInstalled(for: runtime)
        )
    }

    /// Returns a localized explanation for the recommended backend choice.
    ///
    /// Suitable for display in a detail label or tooltip next to the "Recommended" option.
    ///
    /// - Parameter macOSVersion: The macOS version to consider. Defaults to the running system.
    /// - Returns: A human-readable rationale string.
    public static func rationale(macOSVersion: MacOSVersion = .current) -> String {
        String(localized: "config.graphics.backend.recommended.rationale")
    }
}
