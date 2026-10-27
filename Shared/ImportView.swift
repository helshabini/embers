import EmbersCore
import EmbersData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImportCoordinator {
    enum Stage {
        case idle
        case reading
        case preview(ImportedBudget)
        case committing
        case done(ImportOutcome)
        case failed(String)
    }

    var stage: Stage = .idle
    var replaceExisting = false
    var reconcileClosingBalances = true

    /// Parsing 10,000 rows takes long enough to drop a frame, so it happens off the main actor. The
    /// file is read into memory first so the security-scoped URL can be released immediately.
    func read(from url: URL) async {
        stage = .reading
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let budget = try await Task.detached(priority: .userInitiated) {
                try YNABImport.read(archiveData: data)
            }.value
            stage = .preview(budget)
        } catch {
            stage = .failed(String(describing: error))
        }
    }

    /// Writing ten thousand rows blocks whatever thread it runs on, so it runs off the main actor
    /// with its own context. Left on the main actor it froze the screen with no sign of progress.
    func commit(_ budget: ImportedBudget, into context: ModelContext) async {
        stage = .committing
        let container = context.container
        let reconcile = reconcileClosingBalances
        let replace = replaceExisting
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                let writing = ModelContext(container)
                return try YNABImport.commit(
                    budget,
                    into: writing,
                    reconcileClosingBalances: reconcile,
                    replaceExisting: replace
                )
            }.value
            stage = .done(outcome)
        } catch {
            stage = .failed(String(describing: error))
        }
    }

    func reset() {
        stage = .idle
    }
}

struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @State private var coordinator = ImportCoordinator()
    @State private var isChoosingFile = false

    var body: some View {
        Form {
            switch coordinator.stage {
            case .idle:
                chooseSection
            case .reading:
                Section {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Reading the export…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            case let .preview(imported):
                PreviewSections(imported: imported, coordinator: coordinator)
                Section {
                    Button("Import \(imported.report.transactionCount) Transactions") {
                        Task {
                            await coordinator.commit(imported, into: modelContext)
                            budget.refresh(in: modelContext)
                        }
                    }
                    Button("Cancel", role: .cancel) { coordinator.reset() }
                }
            case .committing:
                Section {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Writing your transactions… this can take a moment.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            case let .done(outcome):
                DoneSections(outcome: outcome, baseCurrency: budget.baseCurrency)
                Section {
                    Button("Done") { coordinator.reset() }
                }
            case let .failed(message):
                Section("Could not import") {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                Section {
                    Button("Start Over") { coordinator.reset() }
                }
            }
        }
        .navigationTitle("Import from YNAB")
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.zip]
        ) { result in
            switch result {
            case let .success(url):
                Task { await coordinator.read(from: url) }
            case let .failure(error):
                coordinator.stage = .failed(String(describing: error))
            }
        }
    }

    private var chooseSection: some View {
        Section {
            Button {
                isChoosingFile = true
            } label: {
                Label("Choose YNAB Export…", systemImage: "doc.zipper")
            }
        } footer: {
            Text(
                "In YNAB, open your budget's settings and choose Export Budget. Pick the .zip file it gives you — nothing is imported until you review it."
            )
        }
    }
}

/// The dry run. Nothing has been written yet, so everything here is a statement of intent.
private struct PreviewSections: View {
    let imported: ImportedBudget
    @Bindable var coordinator: ImportCoordinator

    var body: some View {
        Section("Found") {
            LabeledContent("Accounts", value: imported.report.accountCount.formatted(.number.locale(.display)))
            LabeledContent("Payees", value: imported.report.payeeCount.formatted(.number.locale(.display)))
            LabeledContent("Categories", value: imported.report.categoryCount.formatted(.number.locale(.display)))
            LabeledContent("Transactions", value: imported.report.transactionCount.formatted(.number.locale(.display)))
            LabeledContent("Splits", value: imported.report.splitTransactionCount.formatted(.number.locale(.display)))
            LabeledContent("Transfers", value: imported.report.transferPairCount.formatted(.number.locale(.display)))
            if let first = imported.report.firstMonth, let last = imported.report.lastMonth {
                LabeledContent("Months", value: "\(first.displayName) – \(last.displayName)")
            }
        }

        Section {
            Toggle("Match YNAB's closing balances", isOn: $coordinator.reconcileClosingBalances)
            Toggle("Replace what's already here", isOn: $coordinator.replaceExisting)
        } footer: {
            Text(
                "A few of YNAB's internal credit-card movements can't be recalculated from the register. Matching records the difference as an adjustment so your starting balances agree with YNAB exactly."
            )
        }

        Section("Accounts") {
            ForEach(imported.accounts) { account in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(account.name)
                        Spacer()
                        Text(account.type.displayName).foregroundStyle(.secondary)
                    }
                    Text(account.inferenceNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if !imported.report.warnings.isEmpty {
            Section("Worth knowing") {
                ForEach(imported.report.warnings, id: \.self) { warning in
                    Text(warning).font(.footnote)
                }
            }
        }
    }

}

private struct DoneSections: View {
    let outcome: ImportOutcome
    let baseCurrency: Currency

    var body: some View {
        Section("Imported") {
            LabeledContent("Accounts", value: outcome.report.accountCount.formatted(.number.locale(.display)))
            LabeledContent("Transactions", value: outcome.report.transactionCount.formatted(.number.locale(.display)))
        }
        if let reconciliation = outcome.reconciliation, !reconciliation.isClean {
            Section("Adjusted to match YNAB") {
                ForEach(reconciliation.adjustments, id: \.categoryID) { adjustment in
                    LabeledContent(adjustment.categoryName) {
                        Text(Money(minorUnits: adjustment.amount, currency: baseCurrency).formatted())
                    }
                }
            }
        }
    }
}
