import EmbersData
import SwiftData
import SwiftUI

/// Says that the budget is on its way down from iCloud, and how much of it has arrived.
///
/// Shown on a device with iCloud until its first download finishes. Without it a new Mac opened on
/// an empty sidebar and "No accounts yet" while ten thousand entries were arriving, and nothing said
/// whether anything was happening at all.
///
/// The counts are read from the store every few seconds rather than from the budget's figures: those
/// are worked out when a download finishes, and the first one can take minutes.
struct FirstDownloadNotice: View {
    /// A row in a list, or a panel of its own in place of an empty screen.
    var isProminent = false

    @Environment(\.modelContext) private var modelContext
    @Environment(CloudSync.self) private var cloud
    @State private var accounts = 0
    @State private var transactions = 0

    var body: some View {
        Group {
            if isProminent {
                ContentUnavailableView {
                    Label("Bringing your budget from iCloud", systemImage: "icloud.and.arrow.down")
                } description: {
                    VStack(spacing: 10) {
                        ProgressView()
                        details
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bringing your budget from iCloud")
                            .font(.callout.weight(.semibold))
                        details
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("first-download-notice")
        .task {
            while !Task.isCancelled {
                count()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var details: some View {
        VStack(alignment: isProminent ? .center : .leading, spacing: 3) {
            Text(arrived)
                .monospacedDigit()
            Text("Keep Embers open until it finishes. This happens once, the first time a device opens your budget.")
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(isProminent ? .center : .leading)
        // A sidebar row on the Mac is one line unless told otherwise.
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var arrived: String {
        if cloud.status == .checking {
            return String(localized: "Checking iCloud…")
        }
        if accounts == 0 && transactions == 0 {
            // iCloud fetches a large batch before it saves any, so a download under way can show
            // nothing for a minute; without this it looked as if nothing had started.
            return cloud.isImporting
                ? String(localized: "Downloading. The first entries appear once a batch has arrived.")
                : String(localized: "Looking for your budget…")
        }
        return String(
            localized: "So far: \(String(localized: "\(accounts) accounts", locale: .display)), \(String(localized: "\(transactions) transactions", locale: .display))",
            locale: .display
        )
    }

    private func count() {
        accounts = (try? modelContext.fetchCount(FetchDescriptor<Account>())) ?? 0
        transactions = (try? modelContext.fetchCount(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.parent == nil })
        )) ?? 0
    }
}
