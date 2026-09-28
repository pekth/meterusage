import SwiftUI

/// Never bind a secret to AppStorage or restore a saved key into a field.
struct APIConnectionControls: View {
    let provider: Provider
    @ObservedObject var coordinator: AppCoordinator
    @State private var editing = false
    @State private var key = ""

    private var testing: Bool { coordinator.testingAPIProviders.contains(provider) }
    private var hasKey: Bool { coordinator.hasAPIKey(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if coordinator.isDemoMode {
                Text("Demo data. No connection needed.")
            } else {
                status
                if editing {
                    Text(provider == .openAI
                         ? "Use an organization Admin key with usage access."
                         : "Use a Console organization Admin key. Individual accounts do not have reporting access.")
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Create an Admin key", destination: URL(string: provider == .openAI
                         ? "https://platform.openai.com/settings/organization/admin-keys"
                         : "https://platform.claude.com/docs/en/manage-claude/admin-api-keys")!)
                    SecureField("Admin API key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .privacySensitive()
                        .accessibilityLabel("\(provider.displayName) Admin key")
                        .onSubmit(connect)
                    HStack {
                        Button("Test connection", action: connect)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                        Button("Cancel") { key = ""; editing = false }
                    }
                } else {
                    HStack {
                        Button(hasKey ? "Replace key" : "Connect") { editing = true }
                            .disabled(testing)
                        if hasKey || coordinator.apiConnectionErrors[provider] != nil {
                            Button("Disconnect") {
                                key = ""
                                coordinator.disconnectAPI(provider)
                            }
                        }
                    }
                }
                if coordinator.apiConnectionErrors[provider] != nil {
                    Button("Retry saved key") {
                        Task { await coordinator.retrySavedAPIKey(provider) }
                    }
                    .disabled(testing)
                }
                Text("Keys entered here are saved in macOS Keychain across restarts and updates. Disconnect removes the saved key.")
                    .foregroundColor(MU.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.muCaption)
        .foregroundColor(MU.textSecondary)
        .controlSize(.small)
        .padding(.leading, 21)
        .padding(.bottom, 4)
        .onDisappear { key = ""; editing = false }
    }

    @ViewBuilder
    private var status: some View {
        if let error = coordinator.apiConnectionErrors[provider] {
            Text(error)
                .foregroundColor(MU.warn)
                .fixedSize(horizontal: false, vertical: true)
        } else if testing {
            Text("Testing usage and cost access…")
        } else if !hasKey {
            Text("Not connected")
        } else {
            switch coordinator.usages[.primary(provider)] ?? .idle {
            case .value(let usage):
                Text("Connected · Updated \(Fmt.timeSince(usage.capturedAt, now: coordinator.clock))")
                    .foregroundColor(MU.calm)
            case .missing(let reason):
                Text(reason.userFacingMessage)
                    .foregroundColor(MU.warn)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                Text("Waiting for a usage reading…")
            }
        }
    }

    private func connect() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !testing else { return }
        let enteredKey = key
        key = ""
        editing = false
        Task { await coordinator.connectAPI(provider, key: enteredKey) }
    }
}
