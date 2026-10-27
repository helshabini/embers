import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Writes a YNAB export into a store file, for populating a simulator or a device build during
/// development without tapping through the import flow every time.
///
/// Usage: swift run seed-store <export.zip> <Embers.store>

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: seed-store <export.zip> <Embers.store>\n".utf8))
    exit(2)
}

let exportURL = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath)
let storeURL = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)

do {
    try FileManager.default.createDirectory(
        at: storeURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let container = try EmbersStore.container(cloudKitContainerIdentifier: nil, url: storeURL)
    let context = ModelContext(container)

    let budget = try YNABImport.read(archiveAt: exportURL)
    let outcome = try YNABImport.commit(budget, into: context, replaceExisting: true)

    print("seeded \(storeURL.path)")
    print("  accounts      \(outcome.report.accountCount)")
    print("  payees        \(outcome.report.payeeCount)")
    print("  transactions  \(outcome.report.transactionCount)")
    if let reconciliation = outcome.reconciliation, !reconciliation.isClean {
        print("  reconciled    \(reconciliation.adjustments.count) categories")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
