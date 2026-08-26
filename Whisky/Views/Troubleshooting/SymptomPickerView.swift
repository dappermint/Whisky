//
//  SymptomPickerView.swift
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

/// Grid of 8 symptom categories with SF Symbols and descriptions.
///
/// Uses an adaptive 2-column grid for wider views. The "Other" category
/// is shown at the bottom with reduced visual weight per locked decision.
struct SymptomPickerView: View {
    @ObservedObject var engine: TroubleshootingFlowEngine

    /// Primary categories exclude "other" for separate rendering.
    private var primaryCategories: [SymptomCategory] {
        SymptomCategory.allCases.filter { $0 != .other }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("troubleshooting.symptom.title")
                .font(.title3)
                .fontWeight(.medium)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)],
                spacing: 12
            ) {
                ForEach(primaryCategories, id: \.self) { category in
                    categoryCard(category, isOther: false)
                }
            }

            // "Other" option with reduced visual weight
            categoryCard(.other, isOther: true)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Category Card

extension SymptomPickerView {
    private func categoryCard(_ category: SymptomCategory, isOther: Bool) -> some View {
        Button {
            engine.selectCategory(category)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: category.sfSymbol)
                    .font(.title2)
                    .foregroundStyle(isOther ? .tertiary : .secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.localizedTitle)
                        .font(.headline)
                        .foregroundStyle(isOther ? .secondary : .primary)
                    Text(category.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.secondary.opacity(isOther ? 0.1 : 0.2),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Localized Category Strings

/// Catalog-backed strings for ``SymptomCategory``. The kit's
/// ``SymptomCategory/displayTitle`` is an English fallback for contexts
/// without the app's string catalog; every view in the app goes through
/// these instead.
extension SymptomCategory {
    var localizedTitle: String {
        switch self {
        case .launchCrash:
            String(localized: "troubleshooting.symptom.launchCrash")
        case .launcherIssues:
            String(localized: "troubleshooting.symptom.launcherIssues")
        case .graphics:
            String(localized: "troubleshooting.symptom.graphics")
        case .audio:
            String(localized: "troubleshooting.symptom.audio")
        case .controllerInput:
            String(localized: "troubleshooting.symptom.controllerInput")
        case .installDependencies:
            String(localized: "troubleshooting.symptom.installDependencies")
        case .networkDownload:
            String(localized: "troubleshooting.symptom.networkDownload")
        case .performanceStability:
            String(localized: "troubleshooting.symptom.performanceStability")
        case .other:
            String(localized: "troubleshooting.symptom.other")
        }
    }

    var localizedDescription: String {
        switch self {
        case .launchCrash:
            String(localized: "troubleshooting.symptom.launchCrash.description")
        case .launcherIssues:
            String(localized: "troubleshooting.symptom.launcherIssues.description")
        case .graphics:
            String(localized: "troubleshooting.symptom.graphics.description")
        case .audio:
            String(localized: "troubleshooting.symptom.audio.description")
        case .controllerInput:
            String(localized: "troubleshooting.symptom.controllerInput.description")
        case .installDependencies:
            String(localized: "troubleshooting.symptom.installDependencies.description")
        case .networkDownload:
            String(localized: "troubleshooting.symptom.networkDownload.description")
        case .performanceStability:
            String(localized: "troubleshooting.symptom.performanceStability.description")
        case .other:
            String(localized: "troubleshooting.symptom.other.description")
        }
    }
}
