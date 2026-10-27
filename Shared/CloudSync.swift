import CloudKit
import CoreData
import EmbersData
import Observation
import SwiftUI

/// Syncing the store through the iCloud private database, and what the rest of the app has to wait
/// for because of it.
///
/// SwiftData does the syncing. What it does not do is say when the plan has arrived, and a new
/// device that seeds its starter groups or rolls repeats forward before then makes its own copies
/// of things the plan already has. So this watches the mirroring's own events.
@MainActor
@Observable
final class CloudSync {
    static let containerIdentifier = "iCloud.com.helshabini.Embers"

    /// UI tests run on a store of their own that never syncs. They share the simulator, and one
    /// signed into iCloud would otherwise upload their invented budgets into the real one.
    static let isEnabled = !ProcessInfo.processInfo.arguments.contains("-no-cloud-sync")

    static var storeURL: URL {
        isEnabled
            ? EmbersStore.defaultStoreURL
            : URL.applicationSupportDirectory.appending(path: "Embers-UITests.store")
    }

    enum Status: Equatable {
        case checking
        /// No iCloud account, or iCloud turned off for the app: the store is this device's alone.
        case localOnly
        case syncing
    }

    private(set) var status: Status = .checking

    /// Bumped each time changes from another device have been brought in.
    private(set) var importsCompleted = 0

    /// Whether this device has ever finished bringing the plan down. Remembered across launches: the
    /// first import of a large plan can outlast the launch that started it.
    private(set) var hasEverImported = UserDefaults.standard.bool(forKey: hasImportedKey)
    private static let hasImportedKey = "cloudImportCompleted"

    /// Imports and exports started and not yet finished, by event. Watched so the screens can say
    /// what iCloud is doing, rather than show half a budget as though it were the whole of it.
    private var inFlight: [UUID: NSPersistentCloudKitContainer.EventType] = [:]

    /// Whether changes are coming down from iCloud right now.
    var isImporting: Bool { inFlight.values.contains(.import) }

    /// Whether this device's changes are going up to iCloud right now.
    var isExporting: Bool { inFlight.values.contains(.export) }

    /// When a download or an upload last finished cleanly. Remembered across launches.
    private(set) var lastSyncedAt = UserDefaults.standard.object(forKey: lastSyncedKey) as? Date
    private static let lastSyncedKey = "cloudLastSyncedAt"

    /// Why the last download or upload failed, until one succeeds. iCloud retries by itself; this is
    /// for saying so rather than looking finished.
    private(set) var lastFailure: String?

    /// A device with iCloud whose first download has not finished: the budget on screen is whatever
    /// part of the plan has arrived, which may be nothing. Said on screen, because a new Mac showing
    /// "No accounts yet" while thousands of entries were on their way left its owner guessing.
    var isFirstDownload: Bool {
        Self.simulatesFirstDownload || (Self.isEnabled && status != .localOnly && !hasEverImported)
    }

    /// Shows the first-download notice whatever iCloud is doing, so a screenshot can show it: a real
    /// first download cannot be staged in a test. Changes nothing about what launch may write.
    private static let simulatesFirstDownload = ProcessInfo.processInfo.arguments.contains("-simulate-first-download")

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    func start() async {
        guard Self.isEnabled else {
            status = .localOnly
            return
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event
                else { return }
                let type = event.type
                let identifier = event.identifier
                let succeeded = event.succeeded
                let errorCode = (event.error as? CKError)?.code
                let error = event.error?.localizedDescription
                let hasEnded = event.endDate != nil
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if type == .import || type == .export {
                        self.inFlight[identifier] = hasEnded ? nil : type
                    }
                    if hasEnded {
                        self.finished(type, succeeded: succeeded, errorCode: errorCode, error: error)
                    }
                }
            }
        }
        let account = try? await CKContainer(identifier: Self.containerIdentifier).accountStatus()
        guard status == .checking else { return }
        // Only a definite answer decides. "Could not determine", "temporarily unavailable" or no
        // answer at all leave it checking, and launch writes nothing until it knows: a device that
        // wrongly believes it has no iCloud seeds a plan of its own beside the real one.
        switch account {
        case .available: status = .syncing
        case .noAccount, .restricted: status = .localOnly
        default: break
        }
    }

    private func finished(
        _ type: NSPersistentCloudKitContainer.EventType,
        succeeded: Bool,
        errorCode: CKError.Code?,
        error: String?
    ) {
        if type == .import || type == .export {
            if succeeded {
                lastFailure = nil
                lastSyncedAt = Date()
                UserDefaults.standard.set(lastSyncedAt, forKey: Self.lastSyncedKey)
            } else {
                lastFailure = error ?? String(localized: "iCloud could not be reached.")
            }
        }
        switch type {
        case .setup where !succeeded:
            // iCloud turned off for the app in Settings reports an account but cannot set up. Only
            // a failure that says so counts: a new Mac's first setups failed seven times with a
            // partial failure and then succeeded, and taking the first for "no iCloud" let it seed
            // a starter plan that, merged with the real one, cost its iPhone 5,900 categories.
            if let errorCode, Self.meansNoICloud.contains(errorCode) { status = .localOnly }
        case .setup:
            if status == .checking { status = .syncing }
        case .import where succeeded:
            status = .syncing
            if !hasEverImported {
                hasEverImported = true
                UserDefaults.standard.set(true, forKey: Self.hasImportedKey)
            }
            importsCompleted += 1
        default:
            break
        }
    }

    /// Setup failures that mean this app will not sync here, rather than that it has not yet.
    private static let meansNoICloud: Set<CKError.Code> = [
        .notAuthenticated, .permissionFailure, .managedAccountRestricted, .badContainer, .missingEntitlement,
    ]

    /// Whether launch may write the things a plan gets once: the starter groups, the credit card
    /// group, the next occurrence of a repeat.
    ///
    /// Only once this device has finished a download, or has no iCloud. Holding a plan is not
    /// enough: a plan arrives a piece at a time, and a new Mac that had its groups and three thousand
    /// entries but none of its accounts yet passed that test and ran the catch-up — rolling repeats
    /// forward from half a register and making a plan setting of its own — before the rest came.
    /// A store that held a plan before syncing was turned on waits one download, which is seconds.
    func mayWriteAtLaunch() -> Bool {
        hasEverImported || status == .localOnly
    }

    // MARK: - Downloading again

    /// Asks for this device's copy of the budget to be set aside at the next launch, so the whole of
    /// it comes down from iCloud again.
    ///
    /// For a copy that has gone wrong. Nothing is deleted in iCloud or on any other device: the files
    /// are moved, never removed, and the device starts as a new one would — waiting, writing nothing,
    /// until the plan has arrived. Start Fresh is the opposite, and erases the plan everywhere.
    ///
    /// At the next launch rather than now: iCloud holds the open store, and its files cannot be moved
    /// from under it.
    static func requestDownloadAgain() {
        UserDefaults.standard.set(true, forKey: downloadAgainKey)
    }

    static var isDownloadAgainRequested: Bool { UserDefaults.standard.bool(forKey: downloadAgainKey) }
    private static let downloadAgainKey = "cloudDownloadAgainOnLaunch"

    /// Run before the store opens. Moves the store and what iCloud keeps beside it into a folder of
    /// its own — the last one only — and forgets that this device has ever downloaded.
    static func setAsideLocalCopyIfRequested() {
        guard isEnabled, isDownloadAgainRequested else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: downloadAgainKey)

        let store = storeURL
        let folder = store.deletingLastPathComponent()
        let name = store.deletingPathExtension().lastPathComponent
        let setAside = folder.appending(path: "Replaced copy")
        let files = FileManager.default
        try? files.removeItem(at: setAside)
        try? files.createDirectory(at: setAside, withIntermediateDirectories: true)
        // The store, its journal, and what the mirroring keeps beside it under the same name.
        let companions = [
            store.lastPathComponent, store.lastPathComponent + "-shm", store.lastPathComponent + "-wal",
            "\(name)_ckAssets", ".\(name)_SUPPORT", name,
        ]
        for item in companions {
            let source = folder.appending(path: item)
            guard files.fileExists(atPath: source.path) else { continue }
            try? files.moveItem(at: source, to: setAside.appending(path: item))
        }
        defaults.removeObject(forKey: hasImportedKey)
        defaults.removeObject(forKey: lastSyncedKey)
    }
}
