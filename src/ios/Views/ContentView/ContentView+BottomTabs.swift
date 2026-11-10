//
//  ContentView+BottomTabs.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  Apple-style floating bottom tab bar: Chats / Settings.
//  Glass material, capsule shape, SF Symbols, spring press feedback.
//  No gradients — flat translucent surfaces only.
//

import SwiftUI

/// The two home tabs on iPhone.
enum HomeTab: Hashable {
    case chats
    case settings
}

// MARK: - Floating tab bar

struct MinisFloatingTabBar: View {
    @Binding var selection: HomeTab
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 4) {
            tab(.chats, title: "Chats", systemImage: "bubble.left.and.text.bubble.right")
            tab(.settings, title: "Settings", systemImage: "gearshape")
        }
        .padding(5)
        .background {
            // Real-time blur of whatever scrolls behind it.
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            // Hairline edge highlight.
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.16 : 0.45),
                    lineWidth: 0.5
                )
        }
        // Soft, wide shadow keeps the bar floating above the list.
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.12),
                radius: 22, x: 0, y: 10)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.05),
                radius: 3, x: 0, y: 1)
        .padding(.horizontal, 52)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Home tabs")
    }

    private func tab(_ tab: HomeTab, title: LocalizedStringKey, systemImage: String) -> some View {
        let selected = selection == tab
        return Button {
            guard selection != tab else { return }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                selection = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(selected
                             ? Color.primary
                             : Color(UIColor.secondaryLabel).opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .fill(selectedFill)
                        .matchedGeometryEffect(id: "selectedPill", in: pillNamespace)
                        .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        }
        .buttonStyle(SoftTabPressStyle())
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    /// Flat light gray-white pill — brighter on dark backgrounds so it still reads.
    private var selectedFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.white.opacity(0.72)
    }
}

// MARK: - Press feedback

/// Subtle elastic press: scale down on touch, spring back on release.
struct SoftTabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72),
                       value: configuration.isPressed)
    }
}
