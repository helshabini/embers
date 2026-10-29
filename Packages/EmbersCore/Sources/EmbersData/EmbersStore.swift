import Foundation
import EmbersCore
import SwiftData

/// Builds the SwiftData container.
///
/// Syncing through CloudKit's private database is what makes a new phone pick the budget up on its
/// own, with no account to create and no server to run.
public enum EmbersStore {
    /// Every model the store holds, in one place for the schema and for `CloudKitSchema`.
    public static let modelTypes: [any PersistentModel.Type] = [
        PlanSettings.self,
        Account.self,
        Payee.self,
        CategoryGroup.self,
        BudgetCategoryModel.self,
        CategoryAssignment.self,
        LedgerTransaction.self,
        ExchangeRateSnapshot.self,
        BackupRecord.self,
    ]

    public static let schema = Schema(modelTypes)

    /// - Parameter cloudKitContainerIdentifier: The iCloud container, e.g.
    ///   `iCloud.com.helshabini.Embers`. Pass nil for a local-only store.
    public static func container(
        cloudKitContainerIdentifier: String?,
        url: URL? = nil
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let cloudKitContainerIdentifier {
            configuration = ModelConfiguration(
                schema: schema,
                url: url ?? defaultStoreURL,
                cloudKitDatabase: .private(cloudKitContainerIdentifier)
            )
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                url: url ?? defaultStoreURL,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// An ephemeral container, for checks and previews.
    public static func inMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    public static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "Embers.store")
    }
}

extension ModelContext {
    /// The plan's settings, created on first use.
    public func planSettings() throws -> PlanSettings {
        var descriptor = FetchDescriptor<PlanSettings>()
        descriptor.fetchLimit = 1
        if let existing = try fetch(descriptor).first { return existing }
        let created = PlanSettings()
        insert(created)
        return created
    }
}
