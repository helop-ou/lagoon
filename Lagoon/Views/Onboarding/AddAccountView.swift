import SwiftUI

/// A cancellable setup transaction, independent of the signed-in UI below.
struct AddAccountView: View {
    let session: SessionStore
    @State private var draft = SessionStore(accountDraft: true)
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch draft.phase {
                case .needsServer: ServerConnectView()
                case .needsSignIn: SignInView()
                case .signedIn, .choosingAccount: ProgressView("Signing In")
                }
            }
            .environment(draft)
            .navigationTitle("Add Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: cancel)
                        .accessibilityIdentifier("account.setup.cancel")
                }
            }
        }
        .onChange(of: draft.phase) { _, phase in
            guard phase == .signedIn else { return }
            do {
                try session.finishAddingAccount(from: draft)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onDisappear { draft.cancelAccountDraft() }
        .alert("Couldn't Save Account", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Close", role: .cancel, action: cancel)
        } message: {
            Text(errorMessage ?? "Please try signing in again.")
        }
        #if os(tvOS)
        .onExitCommand(perform: cancel)
        #endif
    }

    private func cancel() {
        draft.cancelAccountDraft()
        session.isAddingAccount = false
    }
}
