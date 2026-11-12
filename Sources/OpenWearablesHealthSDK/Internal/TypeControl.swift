import Foundation
import HealthKit

/// Per-type pause / resume / resync.
///
/// The app speaks in wrapper ids (`HealthDataType` raw values); everything stored for
/// the app (paused list, pending resyncs) keeps those ids as sent, and the sync loop
/// works on HealthKit identifiers. Aliases fold through the mapping: `restingEnergy`
/// and `basalEnergy` are one HealthKit type, so pausing either stops both.
extension OpenWearablesHealthSDK {

    // MARK: - Id mapping

    /// HealthKit types a wrapper id stands for. Empty for unknown ids and for types
    /// this OS does not have. `bloodPressure` maps to its two quantity types, because
    /// the correlation itself is never queried (see `getQueryableTypes`).
    internal static func sampleTypes(forTypeId id: String) -> [HKSampleType] {
        guard let type = HealthDataType(rawValue: id) else { return [] }
        if type == .bloodPressure {
            return [HealthDataType.bloodPressureSystolic, .bloodPressureDiastolic].compactMap { $0.toHKSampleType() }
        }
        return type.toHKSampleType().map { [$0] } ?? []
    }

    internal static func hkIdentifiers(forTypeIds ids: [String]) -> Set<String> {
        Set(ids.flatMap { sampleTypes(forTypeId: $0) }.map { $0.identifier })
    }

    /// Order-preserving dedupe of the ids the app passed in.
    internal static func uniqueTypeIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Paused types

    internal func pausedHKIdentifiers() -> Set<String> {
        Self.hkIdentifiers(forTypeIds: OpenWearablesHealthSdkKeychain.getPausedTypes(userKey: userKey()))
    }

    // MARK: - Pending resyncs

    // Wrapper ids whose history is being read again. Lives in the state suite next to
    // the anchors it waits for and is cleared with them in `resetAllAnchors`: a full
    // export supersedes any pending resync.
    internal func resyncTypesKey() -> String {
        "resyncTypes.\(userKey())"
    }

    internal func loadResyncTypeIds() -> [String] {
        defaults.stringArray(forKey: resyncTypesKey()) ?? []
    }

    internal func saveResyncTypeIds(_ ids: [String]) {
        if ids.isEmpty {
            defaults.removeObject(forKey: resyncTypesKey())
        } else {
            defaults.set(ids, forKey: resyncTypesKey())
        }
    }

    internal func pendingResyncHKIdentifiers() -> Set<String> {
        Self.hkIdentifiers(forTypeIds: loadResyncTypeIds())
    }

    /// Called when a run finished reading `completed` cleanly. Drops the resyncs that
    /// cover it once all their tracked types have an anchor again. Resync removed those
    /// anchors and only a run that started after it can save one (see
    /// `updateTypeProgress`). Ids that map to no tracked type are dropped too.
    /// Only tracked types count (`bloodPressure` may have one side tracked). An id that
    /// maps to no tracked type is dropped, since no run will ever read it - unless no
    /// types are known yet (a background launch before `configure`), when it waits.
    internal func settleResyncs(completed: String) {
        let pending = loadResyncTypeIds()
        guard !pending.isEmpty else { return }
        let key = userKey()
        let queryable = Set(getQueryableTypes().map { $0.identifier })
        let remaining = pending.filter { id in
            let identifiers = Set(Self.sampleTypes(forTypeId: id).map { $0.identifier }).intersection(queryable)
            if identifiers.isEmpty { return queryable.isEmpty }
            // Waits for its own types: an anchor saved by a run that skipped the type on
            // an error must not settle it when some other type completes.
            guard identifiers.contains(completed) else { return true }
            return identifiers.contains {
                defaults.data(forKey: anchorKey(typeIdentifier: $0, userKey: key)) == nil
            }
        }
        if remaining.count != pending.count {
            saveResyncTypeIds(remaining)
            logMessage("Resync finished: \(pending.filter { !remaining.contains($0) }.joined(separator: ", "))")
        }
    }

    // MARK: - In-flight invalidation

    // A run snapshots `typeEpoch` when it starts. Pausing or resyncing a type stamps it
    // with a newer epoch, after which that run neither fetches the type again nor writes
    // its progress or anchor. Guarded by `typeStateLock`, the same lock that serializes
    // every read-modify-write of the sync state file.

    internal func currentTypeEpoch() -> Int {
        typeStateLock.lock()
        defer { typeStateLock.unlock() }
        return typeEpoch
    }

    internal func invalidateTypesInFlight(_ identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        typeStateLock.lock()
        typeEpoch += 1
        for id in identifiers { typeInvalidatedAt[id] = typeEpoch }
        typeStateLock.unlock()
    }

    internal func invalidateAllTypesInFlight() {
        typeStateLock.lock()
        typeEpoch += 1
        allTypesInvalidatedAt = typeEpoch
        typeStateLock.unlock()
    }

    /// True when the type was paused, resynced or reset after a run that started at `epoch`.
    internal func isTypeInvalidated(_ identifier: String, since epoch: Int) -> Bool {
        typeStateLock.lock()
        defer { typeStateLock.unlock() }
        return allTypesInvalidatedAt > epoch || (typeInvalidatedAt[identifier] ?? 0) > epoch
    }

    // MARK: - Resync scheduling

    /// Removes the anchor and the session progress of each type so the next run reads
    /// its whole history again, and returns the ids scheduled.
    ///
    /// After the initial export this is an anchored query from nil, oldest first, in a
    /// `live` session. Before it, only types the export has already completed are
    /// touched: they lose their completed mark, so the export - when it resumes - reads
    /// them again newest first with a fresh baseline (`historical`). If the run in flight
    /// finishes the export first, they have no anchor afterwards and the follow-up
    /// incremental run reads them from nil instead.
    internal func scheduleResync(typeIds: [String]) -> [String] {
        let paused = pausedHKIdentifiers()
        let queryable = Set(getQueryableTypes().map { $0.identifier })
        let key = userKey()

        typeStateLock.lock()
        defer { typeStateLock.unlock() }

        let fullDone = defaults.bool(forKey: fullDoneKey())
        var state = loadSyncState()
        var scheduled: [String] = []
        var targets = Set<String>()

        for id in Self.uniqueTypeIds(typeIds) {
            let identifiers = Set(Self.sampleTypes(forTypeId: id).map { $0.identifier })
            guard !identifiers.isEmpty else {
                logMessage("Resync: ignoring unknown type \(id)")
                continue
            }
            guard identifiers.isDisjoint(with: paused) else {
                logMessage("Resync: ignoring paused type \(id)")
                continue
            }
            var typeTargets = identifiers.intersection(queryable)
            guard !typeTargets.isEmpty else {
                logMessage("Resync: ignoring untracked type \(id)")
                continue
            }
            if !fullDone {
                // The first export reads every type it has not finished anyway.
                typeTargets.formIntersection(state?.completedTypes ?? [])
                guard !typeTargets.isEmpty else {
                    logMessage("Resync: \(id) not exported yet - initial export covers it")
                    continue
                }
            }
            targets.formUnion(typeTargets)
            scheduled.append(id)
        }

        guard !targets.isEmpty else { return [] }

        // Inside the lock, before anything is removed: a commit from an in-flight run
        // either finished before this point or sees the invalidation and skips.
        invalidateTypesInFlight(targets)
        for identifier in targets {
            defaults.removeObject(forKey: anchorKey(typeIdentifier: identifier, userKey: key))
            state?.typeProgress[identifier] = nil
            state?.completedTypes.remove(identifier)
        }
        if let state = state {
            saveSyncState(state)
        }

        let pending = loadResyncTypeIds()
        saveResyncTypeIds(pending + scheduled.filter { !pending.contains($0) })
        return scheduled
    }

    /// Marks resumed types that have no anchor (paused before their first export
    /// finished) as resyncing. Their next run reads the whole history either way; this
    /// only makes it visible in `getSyncStatus()`. Before the first export is done the
    /// export itself covers them.
    internal func markResyncForTypesWithoutAnchor(typeIds: [String]) -> [String] {
        guard defaults.bool(forKey: fullDoneKey()) else { return [] }
        let paused = pausedHKIdentifiers()
        let queryable = Set(getQueryableTypes().map { $0.identifier })
        let key = userKey()

        let missing = typeIds.filter { id in
            let identifiers = Set(Self.sampleTypes(forTypeId: id).map { $0.identifier }).intersection(queryable)
            guard !identifiers.isEmpty, identifiers.isDisjoint(with: paused) else { return false }
            return identifiers.contains {
                defaults.data(forKey: anchorKey(typeIdentifier: $0, userKey: key)) == nil
            }
        }
        guard !missing.isEmpty else { return [] }

        typeStateLock.lock()
        let pending = loadResyncTypeIds()
        saveResyncTypeIds(pending + missing.filter { !pending.contains($0) })
        typeStateLock.unlock()
        return missing
    }

    // MARK: - Observers

    /// Stops the observer query and background delivery for each type.
    internal func stopObservers(for types: [HKSampleType]) {
        let identifiers = Set(types.map { $0.identifier })
        guard !identifiers.isEmpty else { return }
        observerQueriesLock.lock()
        defer { observerQueriesLock.unlock() }
        activeObserverQueries.removeAll { query in
            guard let id = query.objectType?.identifier, identifiers.contains(id) else { return false }
            healthStore.stop(query)
            return true
        }
        for type in types {
            healthStore.disableBackgroundDelivery(for: type) { _, _ in }
        }
    }

    /// Registers observers for types that do not have one yet.
    internal func startObservers(for types: [HKSampleType]) {
        observerQueriesLock.lock()
        defer { observerQueriesLock.unlock() }
        let observed = Set(activeObserverQueries.compactMap { $0.objectType?.identifier })
        for type in types where !observed.contains(type.identifier) {
            registerObserver(for: type)
        }
    }
}
