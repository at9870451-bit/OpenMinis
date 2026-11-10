//
//  ContentView+SoulTab.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  The Soul tab: a read-only overview of SOUL.md (identity + personality
//  prompt). The editor that used to sit in Settings is opened from the
//  top-right button here.
//

import SwiftUI

struct SoulHomeView: View {
    @State private var file: SoulFile? = SoulStore.load()
    @State private var showSettings = false
    @Environment(\.colorScheme) private var colorScheme

    private var metadata: SoulMetadata { file?.metadata ?? .default }

    private var bodyText: String {
        let trimmed = (file?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? AppLocalized("No personality prompt yet. Tap the button at the top right to write one.")
            : trimmed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identityCard
                    promptCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle(Text("Soul"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Text("Soul Settings"))
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SoulSettingsView()
            }
            .onAppear { file = SoulStore.load() }
            .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
                file = SoulStore.load()
            }
        }
    }

    // MARK: - Cards

    private var identityCard: some View {
        HStack(spacing: 14) {
            SoulIconView(icon: metadata.icon, size: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(metadata.name.isEmpty ? "Minis" : metadata.name)
                    .font(.title3.weight(.semibold))
                if !metadata.style.isEmpty {
                    Text(metadata.style)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Personality Prompt")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(bodyText)
                .font(.system(size: 15))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(UIColor.secondarySystemGroupedBackground))
    }
}
