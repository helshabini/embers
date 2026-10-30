#if DEBUG
import CoreData
import EmbersData
import Foundation
import SwiftData

/// Pushes every record type and field to CloudKit's Development environment, ready to deploy to
/// Production.
///
/// Syncing alone does not do it: CloudKit adds a field the first time a record carrying a value for
/// it is uploaded, so a field that has only ever been nil is missing from Development, and so from
/// whatever is deployed. A release build then fails to upload any record that sets it, silently.
/// Launch a debug build with `-initialize-cloudkit-schema` once before deploying; it writes nothing
/// to the real store and quits. `-check-cloudkit-schema` does the same without uploading.
@MainActor
enum CloudKitSchema {
    private static var started = false

    /// True when asked to run: the caller must then leave the real store unopened.
    ///
    /// Off the main thread: the push blocks for up to 30 seconds on CloudKit, and the Mac starts it
    /// from `applicationDidFinishLaunching`, where blocking would hang the launch.
    @discardableResult
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let upload = arguments.contains("-initialize-cloudkit-schema")
        guard upload || arguments.contains("-check-cloudkit-schema") else { return false }
        guard !started else { return true }
        started = true
        let identifier = CloudSync.containerIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try initialize(identifier: identifier, options: upload ? [] : [.dryRun, .printSchema])
                print("CloudKit schema: \(upload ? "uploaded to Development" : "valid, nothing uploaded")")
                exit(0)
            } catch {
                print("CloudKit schema failed: \(error)")
                exit(1)
            }
        }
        return true
    }

    nonisolated private static func initialize(
        identifier: String,
        options: NSPersistentCloudKitContainerSchemaInitializationOptions
    ) throws {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: EmbersStore.modelTypes) else {
            throw CocoaError(.coderInvalidValue)
        }
        // A throwaway store: the placeholder records this writes and deletes never touch the budget.
        let url = URL.temporaryDirectory.appending(path: "CloudKitSchema-\(UUID().uuidString).store")
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: identifier
        )
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentCloudKitContainer(name: "CloudKitSchema", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        defer {
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
        }
        try container.initializeCloudKitSchema(options: options)
    }
}
#endif
