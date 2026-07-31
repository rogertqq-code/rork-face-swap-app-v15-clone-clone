import SwiftUI

/// Plain-language reference: what each detection category means and which
/// injection method suits it, plus what each method actually does.
struct DetectionGuideView: View {
    var body: some View {
        List {
            Section {
                Text("Different sites check the camera in opposite ways. Some hunt for any sign of tampering — there, fewer changes win. Others probe the camera deeply or run live challenges — there, richer masking wins. Use this guide to understand what the scanner found and which injection method to use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Detection categories") {
                ForEach(DetectedSystemCategory.allCases) { category in
                    categoryRow(category)
                }
            }

            Section("Injection methods") {
                ForEach(InjectionMethodKind.displayOrder) { method in
                    methodRow(method)
                }
            }

            Section("Network backend switches") {
                backendRow(
                    title: "Block detection scripts",
                    icon: "shield.lefthalf.filled",
                    tint: .indigo,
                    detail: "Optional switch that layers on top of any method. It blocks known detection and fingerprint scripts before they run, strips integrity locks, and needs a reload after changing. It can break sites that genuinely depend on those scripts."
                )
                backendRow(
                    title: "Rewrite proxy",
                    icon: "arrow.triangle.swap",
                    tint: .teal,
                    detail: "Optional switch that layers on top of any method. It routes readable pages through the local proxy so security policies and integrity locks can be stripped before page code runs. HTTPS pages are tunneled and still rely on the selected camera method."
                )
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Detection Guide")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private func categoryRow(_ category: DetectedSystemCategory) -> some View {
        let tint = Color(themeName: category.tintName)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(category.label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Label(category.recommendedProfile.label, systemImage: category.recommendedProfile.icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color(themeName: category.recommendedProfile.tintName))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(themeName: category.recommendedProfile.tintName).opacity(0.14), in: .capsule)
            }
            Text(category.guideSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    private func methodRow(_ method: InjectionMethodKind) -> some View {
        let tint = Color(themeName: method.tintName)
        return guideRow(title: method.label, icon: method.icon, tint: tint, detail: method.detail)
    }

    private func backendRow(title: String, icon: String, tint: Color, detail: String) -> some View {
        guideRow(title: title, icon: icon, tint: tint, detail: detail)
    }

    private func guideRow(title: String, icon: String, tint: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }
}
