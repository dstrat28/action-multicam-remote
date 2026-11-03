import MessageUI
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CameraStore.self) private var store
    @AppStorage(ACRPreferences.largerControls) private var largerControls = false
    @AppStorage(ACRPreferences.insta360SDKEnabled) private var insta360SDKEnabled = false
    @State private var supportPresentation: SupportPresentation?
    @State private var isPreparingSupport = false
    @State private var supportError: String?
    @State private var supportFallbackFile: URL?
    @State private var isShowingMailFallback = false

    var body: some View {
        Form {
            CameraManagementSection()

            Section("Settings") {
                Toggle(isOn: $largerControls) {
                    Label("Larger Controls", systemImage: "hand.tap")
                        .foregroundStyle(Color.acrInk)
                }
                .listRowBackground(Color.acrSurface)
                Toggle(isOn: $insta360SDKEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "camera")
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Insta360 SDK")
                            if !FeatureAvailability.insta360SDK {
                                Text("Experimental · Requires SDK build.")
                                    .font(.caption)
                                    .foregroundStyle(Color.acrMutedText)
                            }
                        }
                    }
                    .foregroundStyle(Color.acrInk)
                }
                .disabled(!FeatureAvailability.insta360SDK)
                .listRowBackground(Color.acrSurface)
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                        .foregroundStyle(Color.acrInk)
                }
                .listRowBackground(Color.acrSurface)
                Button(action: prepareSupportEmail) {
                    Label("Send Feedback", systemImage: "envelope")
                        .foregroundStyle(Color.acrInk)
                }
                .accessibilityLabel("Send feedback with diagnostics")
                .listRowBackground(Color.acrSurface)
            }

            Section {
                LabeledContent("Version", value: versionLabel)
                    .foregroundStyle(Color.acrMutedText)
                    .listRowBackground(Color.acrSurface)
            }
        }
        .tint(Color.acrAccent)
        .scrollContentBackground(.hidden)
        .background(Color.acrAppBackground)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.setPairingModeActive(true)
            store.startScanning()
        }
        .onDisappear {
            store.setPairingModeActive(false)
            if store.pairedCameras.isEmpty {
                store.stopScanning()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .sheet(item: $supportPresentation) { presentation in
            switch presentation {
            case let .mail(draft):
                SupportMailView(draft: draft) { error in
                    supportPresentation = nil
                    supportError = error
                }
            case let .share(url):
                DiagnosticsShareSheet(url: url) { supportPresentation = nil }
            }
        }
        .alert("Mail Not Available", isPresented: $isShowingMailFallback, presenting: supportFallbackFile) { url in
            Button("Share Diagnostics") {
                supportPresentation = .share(url)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Set up an account in Mail to send feedback with diagnostics attached, or share the file using another email app and send it to \(SupportEmailDraft.recipient).")
        }
        .alert("Could Not Send Feedback", isPresented: Binding(
            get: { supportError != nil },
            set: { if !$0 { supportError = nil } }
        )) {
            Button("OK", role: .cancel) { supportError = nil }
        } message: {
            Text(supportError ?? "Please try again.")
        }
    }

    private func prepareSupportEmail() {
        guard !isPreparingSupport else { return }
        isPreparingSupport = true
        let version = versionLabel
        Task {
            defer { isPreparingSupport = false }
            do {
                let url = try await store.exportDiagnostics()
                if MFMailComposeViewController.canSendMail() {
                    let draft = try await Task.detached(priority: .userInitiated) {
                        try SupportEmailDraft(diagnosticsURL: url, version: version)
                    }.value
                    supportPresentation = .mail(draft)
                } else {
                    supportFallbackFile = url
                    isShowingMailFallback = true
                }
            } catch {
                supportError = error.localizedDescription
            }
        }
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

private enum SupportPresentation: Identifiable {
    case mail(SupportEmailDraft)
    case share(URL)

    var id: String {
        switch self {
        case let .mail(draft): "mail-\(draft.id)"
        case let .share(url): "share-\(url.absoluteString)"
        }
    }
}
