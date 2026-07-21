import Foundation
import HealthKit

extension OpenWearablesHealthSDK {

    // MARK: - Keys (per-user)
    internal func userKey() -> String {
        guard let userId = userId, !userId.isEmpty else { return "user.none" }
        return "user.\(userId)"
    }

    internal func anchorKey(for type: HKSampleType) -> String {
        "anchor.\(userKey()).\(type.identifier)"
    }
    
    internal func fullDoneKey() -> String {
        "fullDone.\(userKey())"
    }

    internal func anchorKey(typeIdentifier: String, userKey: String) -> String {
        return "anchor.\(userKey).\(typeIdentifier)"
    }

    internal func saveAnchorData(_ data: Data, typeIdentifier: String, userKey: String) {
        defaults.set(data, forKey: anchorKey(typeIdentifier: typeIdentifier, userKey: userKey))
    }

    // MARK: - Anchors
    internal func loadAnchor(for type: HKSampleType) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: anchorKey(for: type)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    internal func saveAnchor(_ anchor: HKQueryAnchor, for type: HKSampleType) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            defaults.set(data, forKey: anchorKey(for: type))
        }
    }

    internal func resetAllAnchors() {
        for t in trackedTypes {
            defaults.removeObject(forKey: anchorKey(for: t))
        }
        defaults.set(false, forKey: fullDoneKey())
        defaults.removeObject(forKey: syncGenerationKey())
    }

    // MARK: - Sync generation

    // The server's per-user data generation, echoed on every sync response. It is
    // bumped server-side when the user's synced data is deleted; a change means
    // every local cursor points into a dataset that no longer exists. Stored with
    // the same lifecycle as the anchors it validates (cleared in resetAllAnchors).
    internal func syncGenerationKey() -> String {
        "syncGeneration.\(userKey())"
    }

    internal func loadSyncGeneration() -> Int? {
        defaults.object(forKey: syncGenerationKey()) as? Int
    }

    internal func saveSyncGeneration(_ value: Int) {
        defaults.set(value, forKey: syncGenerationKey())
    }

    /// Applies a generation observed on an upload response. Returns true when the
    /// generation changed (server-side data was reset): anchors and the sync session
    /// are cleared and the caller must restart as a full export. A first-seen value
    /// is adopted silently — "nothing stored" must never count as a mismatch, or
    /// every fresh sign-in would trigger a second, redundant full export.
    internal func applyServerSyncGeneration(_ serverGeneration: Int?) -> Bool {
        guard let serverGeneration = serverGeneration else { return false }
        guard let known = loadSyncGeneration() else {
            saveSyncGeneration(serverGeneration)
            return false
        }
        if known == serverGeneration { return false }
        logMessage("Sync generation changed (\(known) -> \(serverGeneration)): server-side data was reset")
        resetAllAnchors()
        clearSyncSession()
        saveSyncGeneration(serverGeneration)
        return true
    }

    // MARK: - Initial sync
    internal func initialSyncKickoff(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            logMessage("HealthKit not available")
            completion(false)
            return
        }
        
        guard syncEndpoint != nil, hasAuth else {
            logMessage("No endpoint or auth credential")
            completion(false)
            return
        }
        
        guard !trackedTypes.isEmpty else {
            logMessage("No tracked types")
            completion(false)
            return
        }
        
        let fullDone = defaults.bool(forKey: fullDoneKey())
        if fullDone {
            logMessage("Incremental sync")
            syncAll(fullExport: false, completion: { completion(true) })
        } else {
            logMessage("Full export")
            isInitialSyncInProgress = true
            syncAll(fullExport: true, completion: { completion(true) })
        }
    }
}
