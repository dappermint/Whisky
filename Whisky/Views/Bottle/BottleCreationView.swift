//
//  BottleCreationView.swift
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

struct BottleCreationView: View {
    @Binding var newlyCreatedBottleURL: URL?

    @State private var newBottleName: String = ""
    @State private var newBottleVersion: WinVersion = .win10
    @State private var newBottleURL: URL = UserDefaults.standard.url(forKey: "defaultBottleLocation")
        ?? BottleData.defaultBottleDir
    @State private var nameValid: Bool = false
    @State private var locationIssue: BottleLocationValidation.ValidationResult?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                TextField("create.name", text: $newBottleName)
                    .onChange(of: newBottleName) { _, name in
                        nameValid = !name.isEmpty
                    }
                    .accessibilityIdentifier("create.nameField")

                Picker("create.win", selection: $newBottleVersion) {
                    ForEach(WinVersion.allCases.reversed(), id: \.self) {
                        Text($0.pretty())
                    }
                }

                ActionView(
                    text: "create.path",
                    subtitle: newBottleURL.prettyPath(),
                    actionName: "create.browse"
                ) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = BottleData.containerDir
                    panel.begin { result in
                        if result == .OK, let url = panel.urls.first {
                            newBottleURL = url
                            // Probing here surfaces the consent prompt, and any capability the
                            // location lacks, while the user is still choosing it.
                            locationIssue = validate(url)
                        }
                    }
                }

                if let locationIssue {
                    locationWarning(locationIssue)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("create.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("create.cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("create.cancelButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("create.create") {
                        submit()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!nameValid || locationIssue != nil)
                    .accessibilityIdentifier("create.createButton")
                }
            }
            .onSubmit {
                submit()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: ViewWidth.small)
    }

    @ViewBuilder
    private func locationWarning(_ issue: BottleLocationValidation.ValidationResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This location can't hold a bottle", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(explanation(for: issue))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if showsPrivacyRecovery(for: issue),
                   let settings = BottleLocationValidation.privacySettingsURL {
                    Button("Open Full Disk Access…") { openURL(settings) }
                }
                Button("Check Again") { locationIssue = validate(newBottleURL) }
            }
        }
        .padding(.vertical, 4)
    }

    /// An unwritable consent-gated volume is most likely a declined prompt, which
    /// only Settings can undo.
    private func showsPrivacyRecovery(for issue: BottleLocationValidation.ValidationResult) -> Bool {
        guard case .notWritable = issue else { return false }
        return BottleLocationValidation.isConsentGatedVolume(newBottleURL)
    }

    private func explanation(for issue: BottleLocationValidation.ValidationResult) -> String {
        switch issue {
        case .valid:
            ""
        case let .notWritable(path):
            notWritableExplanation(path)
        case let .missingCapability(capability, path):
            capability.explanation(path: path)
        case let .insufficientSpace(available, required):
            String(localized: """
            Not enough free space: \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) \
            available, \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) needed.
            """)
        }
    }

    private func notWritableExplanation(_ path: String) -> String {
        guard BottleLocationValidation.isConsentGatedVolume(newBottleURL) else {
            return String(localized: "\(path) isn't writable. Pick another location, or fix its permissions in Finder.")
        }
        return String(localized: """
        macOS is withholding access to \(path). Add Whisky Preview under Privacy & Security \u{2192} \
        Full Disk Access with the + button, then check again. It won't be listed under Files and \
        Folders: this build is ad-hoc signed, so each update looks like a new app to macOS.
        """)
    }

    private func validate(_ url: URL) -> BottleLocationValidation.ValidationResult? {
        let result = BottleLocationValidation.validate(at: url)
        return result == .valid ? nil : result
    }

    func submit() {
        // The default location never passes through the panel, so validate again here.
        guard let issue = validate(newBottleURL) else {
            newlyCreatedBottleURL = BottleVM.shared.createNewBottle(
                bottleName: newBottleName,
                winVersion: newBottleVersion,
                bottleURL: newBottleURL
            )
            dismiss()
            return
        }
        locationIssue = issue
    }
}

#Preview {
    BottleCreationView(newlyCreatedBottleURL: .constant(nil))
}
