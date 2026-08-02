//
//  RuntimePickerView.swift
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

import os
import SwiftUI
import WhiskyKit

/// Picks which installed Wine runtime a bottle runs on.
///
/// Hidden when only the default runtime is installed, so the common setup gains
/// no control it cannot use.
struct RuntimePickerView: View {
    private static let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "RuntimePicker")

    @ObservedObject var bottle: Bottle
    @State private var runtimes: [InstalledRuntime] = []
    @State private var loadingState: LoadingState = .success

    var body: some View {
        Group {
            if runtimes.count > 1 {
                SettingItemView(
                    title: "config.runtime",
                    description: "config.runtime.info",
                    loadingState: loadingState
                ) {
                    Picker("config.runtime", selection: runtimeBinding) {
                        ForEach(runtimes) { runtime in
                            Text(label(for: runtime)).tag(runtime.runtime)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
        .task { runtimes = WhiskyWineInstaller.installedRuntimes() }
    }

    /// Writes through to the bottle and reboots the prefix.
    ///
    /// `system32` is populated from the runtime that created it, so switching
    /// without a `wineboot -u` leaves the previous runtime's builtins in place
    /// and the bottle runs a mix of the two.
    private var runtimeBinding: Binding<String?> {
        Binding(
            get: { bottle.settings.runtime },
            set: { newValue in
                guard newValue != bottle.settings.runtime else { return }
                bottle.settings.runtime = newValue
                Task(priority: .userInitiated) { await updatePrefix() }
            }
        )
    }

    private func updatePrefix() async {
        loadingState = .modifying
        do {
            try await Wine.updatePrefix(bottle: bottle)
            loadingState = .success
        } catch {
            Self.logger.error("Failed to update the prefix after a runtime change: \(error.localizedDescription)")
            loadingState = .failed
        }
    }

    private func label(for runtime: InstalledRuntime) -> String {
        var label = runtime.isDefault ? String(localized: "config.runtime.default") : runtime.displayName
        if !runtime.versionDescription.isEmpty {
            label += " \(runtime.versionDescription)"
        }
        if runtime.gptkCapable {
            label += " (\(String(localized: "config.runtime.gptk")))"
        }
        return label
    }
}
