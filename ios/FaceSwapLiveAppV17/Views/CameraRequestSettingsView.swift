import SwiftUI

/// Full control over the opt-in "ask me every request" mode. Everything is off by
/// default, so the app behaves exactly as it always has until enabled here.
struct CameraRequestSettingsView: View {
    @Bindable var store: CameraPromptStore
    /// Called after every change so the page already open picks it up immediately
    /// instead of only after a reload.
    var onChanged: () -> Void = {}

    var body: some View {
        List {
            masterSection
            if store.settings.isEnabled {
                kindsSection
                fallbackSection
                memorySection
                permissionSection
            }
            rulesSection
        }
        .navigationTitle("Camera Requests")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var masterSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.settings.isEnabled },
                set: { store.setEnabled($0); onChanged() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask me every request")
                        .font(.subheadline.weight(.medium))
                    Text("Pause each camera request and choose what to serve.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Off by default. While off, camera requests are answered automatically from your queue exactly as before.")
        }
    }

    private var kindsSection: some View {
        Section {
            Toggle("Live camera feeds", isOn: binding(\.askForLiveCamera))
            Toggle("Native camera captures", isOn: binding(\.askForNativeCamera))
            Toggle("Library / file picks", isOn: binding(\.askForFilePick))
        } header: {
            Text("Ask about")
        } footer: {
            Text("Choose which kinds of request pause and wait for you. Anything left off is answered automatically.")
        }
    }

    private var fallbackSection: some View {
        Section {
            Picker("If I don't answer", selection: Binding(
                get: { store.settings.defaultAction },
                set: { next in store.update { $0.defaultAction = next }; onChanged() }
            )) {
                ForEach(CameraRequestAction.allCases) { action in
                    Text(action.label).tag(action)
                }
            }

            Stepper(
                value: Binding(
                    get: { store.settings.timeoutSeconds },
                    set: { next in store.update { $0.timeoutSeconds = next }; onChanged() }
                ),
                in: 3...120,
                step: 1
            ) {
                HStack {
                    Text("Wait for me")
                        .font(.subheadline)
                    Spacer()
                    Text("\(store.settings.timeoutSeconds)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("If I don't answer in time")
        } footer: {
            Text("A request never hangs a page forever. When the wait runs out, this action is applied automatically.")
        }
    }

    private var memorySection: some View {
        Section {
            Toggle("Offer \u{201C}always do this for this site\u{201D}", isOn: binding(\.rememberPerSite))
        } header: {
            Text("Per-site memory")
        } footer: {
            Text("When on, each prompt can save your answer for that site so it stops asking there.")
        }
    }

    private var permissionSection: some View {
        Section {
            Picker("Release permission", selection: Binding(
                get: { store.settings.permissionReset },
                set: { next in store.update { $0.permissionReset = next }; onChanged() }
            )) {
                ForEach(CameraPermissionResetPolicy.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            Text(store.settings.permissionReset.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("Camera permission")
        } footer: {
            Text("Releasing the site's camera permission forces the next request to ask again, the way a fresh visit would.")
        }
    }

    private var rulesSection: some View {
        Section {
            if store.siteRules.isEmpty {
                Text("No saved site answers yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.siteRules.sorted(by: { $0.key < $1.key }), id: \.key) { host, action in
                    HStack(spacing: 10) {
                        Image(systemName: action.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(action.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            store.forget(host: host)
                            onChanged()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } header: {
            Text("Saved site answers")
        } footer: {
            Text("Sites you chose \u{201C}always do this\u{201D} for. Remove one to be asked there again.")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<CameraPromptSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { next in
                store.update { $0[keyPath: keyPath] = next }
                onChanged()
            }
        )
    }
}
