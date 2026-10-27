import SwiftUI

/// What iCloud is doing with this device's copy of the budget, said where it can be seen.
///
/// iCloud does not say how much is left to come — no total is ever given — so this reports what can
/// be known: changes coming down, changes going up, the last time both were quiet, and a failure
/// iCloud will retry. Without it a Mac that had brought down part of a budget looked finished.
struct SyncStatusView: View {
    /// One line, for the sidebar; or the line with what it means beneath, for settings.
    var isDetailed = false

    @Environment(CloudSync.self) private var cloud

    var body: some View {
        // Redrawn now and then, or "Last synced" would read "now" all afternoon.
        TimelineView(.periodic(from: .now, by: 30)) { _ in content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                symbol
                Text(headline)
            }
            if isDetailed, let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sync-status")
    }

    private var isBusy: Bool {
        cloud.status == .checking || cloud.isFirstDownload || cloud.isImporting || cloud.isExporting
    }

    @ViewBuilder
    private var symbol: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else if cloud.status == .localOnly {
            Image(systemName: Self.deviceSymbol).foregroundStyle(.secondary)
        } else if cloud.lastFailure != nil {
            Image(systemName: "exclamationmark.icloud").foregroundStyle(Flame.glow)
        } else {
            Image(systemName: "checkmark.icloud").foregroundStyle(Flame.inflow)
        }
    }

    private var headline: String {
        if cloud.status == .localOnly {
            #if os(macOS)
            return String(localized: "Stored on this Mac")
            #else
            return String(localized: "Stored on this iPhone")
            #endif
        }
        if cloud.status == .checking { return String(localized: "Checking iCloud…") }
        if cloud.isFirstDownload { return String(localized: "Bringing your budget from iCloud") }
        if cloud.isImporting { return String(localized: "Receiving changes from iCloud…") }
        if cloud.isExporting { return String(localized: "Sending changes to iCloud…") }
        if cloud.lastFailure != nil { return String(localized: "Not synced yet") }
        return String(localized: "Synced with iCloud")
    }

    private var detail: String? {
        if cloud.status == .localOnly { return nil }
        if let failure = cloud.lastFailure, !isBusy {
            return String(localized: "\(failure) iCloud tries again by itself.")
        }
        guard let last = cloud.lastSyncedAt else { return nil }
        let when = last.formatted(.relative(presentation: .named).locale(.display))
        return String(localized: "Last synced \(when).")
    }

    private static var deviceSymbol: String {
        #if os(macOS)
        "desktopcomputer"
        #else
        "iphone"
        #endif
    }
}
