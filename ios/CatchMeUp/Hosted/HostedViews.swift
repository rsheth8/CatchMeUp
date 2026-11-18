import SwiftUI
import Observation

/// The Settings section shown while CatchMeUp Cloud is the selected engine:
/// sign-in, this month's allowance, upgrading, and deleting the account.
struct HostedAccountSection: View {
    @Environment(AppSettings.self) private var settings
    /// Shared with `hostedAccountPresentations`, which owns the sheet, dialog and alert.
    var ui: HostedAccountUI

    private var session: HostedSession { .shared }

    var body: some View {
        Group {
            Section {
                if session.isSignedIn {
                    quotaRow
                    if session.quota?.isPlus != true {
                        Button { ui.showPaywall = true } label: {
                            Label("See CatchMeUp Plus", systemImage: "sparkles")
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign in so your recaps can be counted. Your Apple or Google account is only used to tell accounts apart.")
                            .font(.footnote).foregroundStyle(.secondary)
                        SignInButtons(cloud: true)
                        if let error = session.signInError {
                            Text(error).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("CatchMeUp Cloud")
            } footer: {
                Text("Never audio. Sent to write your notes: the transcript, text from documents you attached to a meeting, the agenda, and your questions with the notes found for them. Not kept after the reply.")
            }

            if session.isSignedIn {
                Section {
                    Button("Sign out of CatchMeUp Cloud") {
                        Task { await session.signOut() }
                    }
                    Button("Delete CatchMeUp Cloud account", role: .destructive) { ui.confirmDelete = true }
                        .disabled(ui.deleting)
                } footer: {
                    Text("Deleting removes your account from our service. Your recaps stay on this iPhone.")
                }
            }
        }
        .task { await session.refreshQuota() }
    }

    private var quotaRow: some View {
        HStack(spacing: 12) {
            IconTile(symbol: session.quota?.isPlus == true ? "sparkles" : "cloud.fill", tint: .brand, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.quota?.isPlus == true ? "Plus" : "Free plan")
                    .font(.subheadline.weight(.semibold))
                Text(quotaLine).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var quotaLine: String {
        guard let quota = session.quota else { return "Checking this month's allowance…" }
        let left = quota.recapsRemaining
        let noun = left == 1 ? "recap" : "recaps"
        let reset = quota.resetsAt.map { " · resets \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
        return "\(left) \(noun) left this month\(reset)"
    }
}

/// What the account section can put on screen. The sheet, dialog and alert are
/// attached to the whole Settings list (see `hostedAccountPresentations`), not to
/// rows inside it: a presentation hung on a list row can fail to appear.
@MainActor
@Observable
final class HostedAccountUI {
    var showPaywall = false
    var confirmDelete = false
    var deleting = false
    var notice: String?

    func delete() {
        deleting = true
        Task {
            defer { deleting = false }
            do {
                let stillActive = try await HostedSession.shared.deleteAccount()
                notice = stillActive
                    ? "Your account is deleted. Your subscription is still active: cancel it in Settings, under your name, then Subscriptions."
                    : "Your CatchMeUp Cloud account is deleted."
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? "Couldn't delete the account. Try again."
            }
        }
    }
}

extension View {
    func hostedAccountPresentations(_ ui: HostedAccountUI) -> some View {
        modifier(HostedAccountPresentations(ui: ui))
    }
}

private struct HostedAccountPresentations: ViewModifier {
    @Bindable var ui: HostedAccountUI

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $ui.showPaywall) { HostedPaywallView(limit: nil) }
            .confirmationDialog("Delete your CatchMeUp Cloud account?", isPresented: $ui.confirmDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) { ui.delete() }
            } message: {
                Text("This can't be undone. Your free recaps for the month do not come back if you sign up again.")
            }
            .alert("Account deleted", isPresented: Binding(get: { ui.notice != nil }, set: { if !$0 { ui.notice = nil } })) {
                Button("OK") { ui.notice = nil }
            } message: {
                Text(ui.notice ?? "")
            }
    }
}

/// Free against Plus, opened from Settings or when the free recaps run out.
/// Buying is not wired yet (StoreKit is the next piece), so the button says so
/// instead of pretending.
struct HostedPaywallView: View {
    let limit: HostedLimit?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    private var title: String {
        guard let limit else { return "CatchMeUp Plus" }
        return limit.plan == "plus" ? "You've reached this month's limit" : "You've used your free recaps"
    }

    private var subtitle: String {
        if let limit, let resets = limit.resetsAt {
            let date = resets.formatted(.dateTime.month(.wide).day())
            return limit.plan == "plus"
                ? "Your allowance renews on \(date)."
                : "They come back on \(date), or get more now with Plus."
        }
        return "More recaps, written by a stronger model."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.title2.weight(.bold))
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }

                    VStack(spacing: 12) {
                        PlanCard(name: "Free", highlight: false, lines: [
                            "3 recaps a month",
                            "Fast, solid notes",
                            "Ask questions about your notes",
                        ])
                        PlanCard(name: "Plus", highlight: true, lines: [
                            "Up to 200 recaps a month",
                            "A stronger model: it catches more of what was said and sticks closer to it",
                            "Meeting insights and questions included",
                        ])
                    }

                    Button {} label: {
                        Text("Plus is coming soon").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.prominent())
                    .disabled(true)

                    if limit != nil, FoundationBridge.isAvailable {
                        Button {
                            settings.engineKind = .onDevice
                            dismiss()
                        } label: {
                            Text("Use on-device for now").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.soft())
                    }
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct PlanCard: View {
    let name: String
    let highlight: Bool
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.headline)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.brand)
                    Text(line).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlight ? Color.brand : Color.clear, lineWidth: 1.5)
        )
    }
}
