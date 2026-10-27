import EmbersCore
import EmbersData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Saving, restoring, and starting over.
///
/// Syncing keeps every device the same, which includes a mistake: a deletion reaches them all. So a
/// backup in iCloud Drive or Files is still the way back, and without iCloud it is the only copy off
/// the device. Both destructive actions take a backup first and say what they are about to remove —
/// and, when syncing, that it goes from every device.
struct BackupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @Environment(CloudSync.self) private var cloud

    @State private var exportDocument: BackupDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var pendingRestore: BackupArchive?
    @State private var isConfirmingStartFresh = false
    @State private var isConfirmingDownloadAgain = false
    /// Asked for on a phone, which cannot close itself: the copy is set aside when Embers next opens.
    @State private var isWaitingToReopen = false
    @State private var message: String?
    /// What is under way, while a restore or Start Fresh writes the whole store.
    @State private var working: LocalizedStringKey?
    @State private var isError = false

    @Query private var accounts: [Account]
    @Query private var transactions: [LedgerTransaction]

    var body: some View {
        Form {
            Section {
                Button {
                    saveBackup()
                } label: {
                    Label("Save a Backup…", systemImage: "square.and.arrow.up")
                }
                Button {
                    isImporting = true
                } label: {
                    Label("Restore from a Backup…", systemImage: "square.and.arrow.down")
                }
                // A device still downloading can only replace the part it has; the rest arrives
                // afterwards beside what was restored.
                .disabled(cloud.isFirstDownload)
            } header: {
                Text("Backups")
            } footer: {
                if cloud.status == .syncing {
                    Text(
                        "Your budget syncs through iCloud. A backup is a copy of it as it is now, to go back to if something goes wrong."
                    )
                } else {
                    #if os(macOS)
                    Text(
                        "Your budget is kept on this Mac. Save a backup to iCloud Drive or another folder for a copy you can restore onto any device."
                    )
                    #else
                    Text(
                        "Your budget is kept on this iPhone. Save a backup to iCloud Drive or Files for a copy you can restore onto any phone."
                    )
                    #endif
                }
            }

            Section {
                LabeledContent("Accounts", value: accounts.count.formatted(.number.locale(.display)))
                LabeledContent("Transactions", value: transactions.count.formatted(.number.locale(.display)))
                LabeledContent("Currency", value: budget.baseCurrency.code)
            } header: {
                Text("This budget")
            }

            if cloud.status == .syncing {
                Section {
                    SyncStatusView(isDetailed: true)
                    Button {
                        isConfirmingDownloadAgain = true
                    } label: {
                        Label("Download Again from iCloud…", systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(isWaitingToReopen)
                    .accessibilityIdentifier("download-again")
                } header: {
                    Text("This device's copy")
                } footer: {
                    if isWaitingToReopen {
                        Text("Close Embers and open it again. Your budget then comes down from iCloud as it would on a new device.")
                    } else {
                        Text("If this device's budget looks wrong or incomplete, set its copy aside and bring the whole budget down from iCloud again. Nothing in iCloud or on your other devices changes.")
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingStartFresh = true
                } label: {
                    Label("Start Fresh", systemImage: "flame")
                }
                // Clearing half a budget is never what is meant, and the rest would arrive after.
                .disabled(cloud.isFirstDownload)
            } footer: {
                if cloud.isFirstDownload {
                    Text("Available once your budget has finished coming down from iCloud.")
                } else if cloud.status == .syncing {
                    Text("Saves a backup first, then clears every account, category and transaction — on every device signed in to your Apple Account. To fix only this device's copy, use Download Again.")
                } else {
                    Text("Saves a backup first, then clears every account, category and transaction.")
                }
            }

            if let working {
                Section {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(working).font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } else if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                }
            }
        }
        .disabled(working != nil)
        .navigationTitle("Backups")
        .inlineNavigationTitle()
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportDocument?.suggestedName ?? String(localized: "Embers Backup")
        ) { result in
            switch result {
            case .success:
                ReminderScheduler.backupSaved()
                report(String(localized: "Backup saved."), isError: false)
            case let .failure(error):
                report(String(describing: error), isError: true)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                loadBackup(from: url)
            case let .failure(error):
                report(String(describing: error), isError: true)
            }
        }
        .alert("Restore this backup?", isPresented: restoreAlertBinding) {
            Button("Cancel", role: .cancel) { pendingRestore = nil }
            Button("Replace Everything", role: .destructive) { restore() }
        } message: {
            Text(
                pendingRestore.map {
                    let saved = $0.createdAt.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .display)
                    )
                    return cloud.status == .syncing
                        ? String(localized: "\($0.summary), saved \(saved). This replaces everything currently in the app, on all your devices.")
                        : String(localized: "\($0.summary), saved \(saved). This replaces everything currently in the app.")
                } ?? ""
            )
        }
        .alert("Download your budget again?", isPresented: $isConfirmingDownloadAgain) {
            Button("Cancel", role: .cancel) {}
            Button("Download Again") { downloadAgain() }
        } message: {
            #if os(macOS)
            Text("This device's copy is set aside and Embers closes. When you open it again, the whole budget comes down from iCloud. Anything entered here that has not reached iCloud yet is lost; nothing in iCloud or on your other devices changes.")
            #else
            Text("This device's copy is set aside the next time Embers opens, and the whole budget comes down from iCloud. Anything entered here that has not reached iCloud yet is lost; nothing in iCloud or on your other devices changes.")
            #endif
        }
        .alert("Start fresh?", isPresented: $isConfirmingStartFresh) {
            Button("Cancel", role: .cancel) {}
            Button("Back Up and Clear", role: .destructive) { startFresh() }
        } message: {
            let removed = Counted.list([
                Counted.accounts(accounts.count), Counted.transactions(transactions.count),
            ])
            if cloud.status == .syncing {
                Text("\(removed) will be removed from all your devices, not only this one. A backup is saved to Files first.")
            } else {
                Text("\(removed) will be removed. A backup is saved to Files first.")
            }
        }
    }

    private var restoreAlertBinding: Binding<Bool> {
        Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    }

    private func saveBackup() {
        do {
            let archive = try BackupWriter.archive(from: modelContext)
            exportDocument = BackupDocument(
                data: try BackupWriter.data(from: modelContext),
                suggestedName: BackupWriter.suggestedFileName(for: archive)
            )
            isExporting = true
        } catch {
            report(String(describing: error), isError: true)
        }
    }

    private func loadBackup(from url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        do {
            pendingRestore = try BackupWriter.decode(try Data(contentsOf: url))
        } catch {
            report(String(describing: error), isError: true)
        }
    }

    /// Writes the store off the main actor, with its own context, showing what is happening
    /// meanwhile. The main context takes in the result when that context saves.
    private func writeAway(
        _ label: LocalizedStringKey,
        _ work: @escaping @Sendable (ModelContext) throws -> Void
    ) async throws {
        working = label
        defer { working = nil }
        let container = modelContext.container
        try await Task.detached(priority: .userInitiated) {
            try work(ModelContext(container))
        }.value
    }

    private func restore() {
        guard let archive = pendingRestore else { return }
        pendingRestore = nil
        Task {
            do {
                try await writeAway("Restoring your budget…") { try BackupWriter.write(archive, into: $0) }
                try BackupWriter.finishRestoring(in: modelContext)
                // A backup holds whatever an older version wrote, so it is mended on the way in
                // rather than at the next launch.
                budget.catchUpSchedules(in: modelContext)
                budget.refresh(in: modelContext)
                report(String(localized: "Restored \(archive.summary)."), isError: false)
            } catch {
                report(String(describing: error), isError: true)
            }
        }
    }

    private func downloadAgain() {
        CloudSync.requestDownloadAgain()
        #if os(macOS)
        // The files can only be moved while nothing holds them, which means the next launch.
        NSApplication.shared.terminate(nil)
        #else
        isWaitingToReopen = true
        #endif
    }

    private func startFresh() {
        Task { await clearAndSeed() }
    }

    private func clearAndSeed() async {
        do {
            let archive = try BackupWriter.archive(from: modelContext)
            let data = try BackupWriter.data(from: modelContext)
            let url = FileManager.default.temporaryDirectory
                .appending(path: BackupWriter.suggestedFileName(for: archive))
            try data.write(to: url)

            try await writeAway("Clearing your budget…") { try ImportWriter.deleteAllPlanData(in: $0) }
            try CategoryWriter.seedStarterPlan(in: modelContext)
            budget.refresh(in: modelContext)

            exportDocument = BackupDocument(
                data: data,
                suggestedName: BackupWriter.suggestedFileName(for: archive)
            )
            isExporting = true
            report(String(localized: "Cleared. Save the backup somewhere safe."), isError: false)
        } catch {
            report(String(describing: error), isError: true)
        }
    }

    private func report(_ text: String, isError: Bool) {
        message = text
        self.isError = isError
    }
}

/// Wraps the archive for `fileExporter`.
struct BackupDocument: FileDocument {
    static let readableContentTypes = [UTType.json]

    var data: Data
    var suggestedName: String

    init(data: Data, suggestedName: String) {
        self.data = data
        self.suggestedName = suggestedName
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        suggestedName = configuration.file.filename ?? "Embers Backup"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
