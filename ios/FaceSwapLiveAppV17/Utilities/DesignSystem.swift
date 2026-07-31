import SwiftUI

/// Shared design system used across every tab so Diagnostics, Profiles, Media
/// Controls, and My Media all read as the same app: one card style, one set of
/// section headers, one button language, and consistent empty / loading states.
///
/// Visual direction: dark, cyan as the single primary accent, with
/// green = good, orange = caution, red = blocked used consistently everywhere.
enum DS {
    /// Standard card corner radius.
    static let corner: CGFloat = 14
    /// Standard inner card padding.
    static let cardPadding: CGFloat = 14
    /// Standard spacing between stacked cards / groups.
    static let groupSpacing: CGFloat = 14

    /// The single primary accent for the whole app.
    static let accent = Color.cyan
    /// Semantic status colors — always the same meaning everywhere.
    static let good = Color.green
    static let caution = Color.orange
    static let blocked = Color.red
}

// MARK: - Card container

/// One shared card style: rounded, padded, on the grouped-secondary background.
struct DSCard<Content: View>: View {
    var spacing: CGFloat = 10
    var padding: CGFloat = DS.cardPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: DS.corner))
    }
}

extension View {
    /// Wraps any view in the standard card background without the internal VStack.
    func dsCardBackground(padding: CGFloat = DS.cardPadding) -> some View {
        self
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: DS.corner))
    }
}

// MARK: - Section header

/// A consistent section header: small icon chip + title, optional trailing view.
struct DSSectionHeader<Trailing: View>: View {
    let title: String
    var icon: String?
    var tint: Color = DS.accent
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 9) {
            if let icon {
                Image(systemName: icon)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: 6))
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension DSSectionHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, tint: Color = DS.accent) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.trailing = { EmptyView() }
    }
}

// MARK: - Collapsible card

/// A consistent collapsible card used by grouped technical surfaces such as
/// Diagnostics. Header toggles the disclosure; body animates in/out.
struct DSDisclosureCard<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = DS.accent
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) { isExpanded.toggle() }
                Haptics.selection()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(DS.cardPadding)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, DS.cardPadding)
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(DS.cardPadding)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: DS.corner))
    }
}

// MARK: - Buttons

/// Gentle press animation + optional haptic for any tappable control.
struct DSPressStyle: ButtonStyle {
    var haptic: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in
                haptic && pressed
            }
    }
}

extension ButtonStyle where Self == DSPressStyle {
    static var dsPress: DSPressStyle { DSPressStyle() }
}

/// The three consistent button roles used across the app.
enum DSButtonRole {
    case primary
    case secondary
    case destructive

    var fillsBackground: Bool { self == .primary }
}

/// One reusable full-width action button so every screen uses the same primary /
/// secondary / destructive language.
struct DSActionButton: View {
    let title: String
    var icon: String?
    var role: DSButtonRole = .primary
    var tint: Color = DS.accent
    var isLoading: Bool = false
    var fullWidth: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 11)
            .padding(.horizontal, fullWidth ? 0 : 16)
            .background(background, in: .rect(cornerRadius: 11))
        }
        .buttonStyle(.dsPress)
    }

    private var resolvedTint: Color {
        role == .destructive ? DS.blocked : tint
    }

    private var foreground: Color {
        switch role {
        case .primary: return .black
        case .secondary: return resolvedTint
        case .destructive: return DS.blocked
        }
    }

    private var background: Color {
        switch role {
        case .primary: return resolvedTint
        case .secondary, .destructive: return resolvedTint.opacity(0.15)
        }
    }
}

// MARK: - Badges & chips

/// The single small version badge style used in the few places it appears.
struct DSVersionBadge: View {
    var body: some View {
        Text(AppVersion.shortLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
    }
}

/// A small pill chip with a tinted label, used for status / counts.
struct DSChip: View {
    let text: String
    var icon: String?
    var tint: Color = DS.accent

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: .capsule)
    }
}

// MARK: - Empty state

/// Consistent in-card empty state.
struct DSEmptyState: View {
    let icon: String
    let title: String
    var message: String?
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

// MARK: - Key/value row

/// A consistent label/value row for spec lists.
struct DSInfoRow: View {
    let label: String
    let value: String
    var labelWidth: CGFloat = 100
    var valueTint: Color = .primary

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(valueTint)
            Spacer(minLength: 0)
        }
    }
}
