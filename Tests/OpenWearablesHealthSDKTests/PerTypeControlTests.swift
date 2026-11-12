import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Covers per-type pause / resume / resync: what is stored, what survives which reset,
/// and that a run already in flight cannot write back a cursor for a type that was
/// paused or resynced under it.
///
/// Background sync stays off, so no call here starts a sync or touches HealthKit
/// observers; the tests drive the state the sync loop reads.
final class PerTypeControlTests: XCTestCase {

    private let heartRate = HKQuantityTypeIdentifier.heartRate.rawValue
    private let steps = HKQuantityTypeIdentifier.stepCount.rawValue
    private let sleep = HKCategoryTypeIdentifier.sleepAnalysis.rawValue

    /// `withIsolatedSDK` redirects files and credentials but not the two UserDefaults
    /// suites, so everything written there for the test user is removed afterwards.
    private func withTypeControlSDK(_ body: (OpenWearablesHealthSDK) throws -> Void) rethrows {
        try withIsolatedSDK { sdk, _ in
            let previousTrackedTypes = sdk.trackedTypes
            let previousSyncActive = OpenWearablesHealthSdkKeychain.isSyncActive()
            OpenWearablesHealthSdkKeychain.setSyncActive(false)
            sdk.trackedTypes = [HealthDataType.heartRate, .steps, .sleep].compactMap { $0.toHKSampleType() }
            defer {
                sdk.trackedTypes = previousTrackedTypes
                OpenWearablesHealthSdkKeychain.setSyncActive(previousSyncActive)
                for userKey in ["user.test-user", "user.none"] {
                    OpenWearablesHealthSdkKeychain.savePausedTypes([], userKey: userKey)
                    for key in sdk.defaults.dictionaryRepresentation().keys where key.contains(userKey) {
                        sdk.defaults.removeObject(forKey: key)
                    }
                }
            }
            try body(sdk)
        }
    }

    private func storedAnchor(_ sdk: OpenWearablesHealthSDK, _ identifier: String) -> Data? {
        sdk.defaults.data(forKey: sdk.anchorKey(typeIdentifier: identifier, userKey: sdk.userKey()))
    }

    private func storeAnchor(_ sdk: OpenWearablesHealthSDK, _ identifier: String) {
        sdk.saveAnchorData(Data([1, 2, 3]), typeIdentifier: identifier, userKey: sdk.userKey())
    }

    private func status(_ sdk: OpenWearablesHealthSDK, _ key: String) -> [String]? {
        sdk.getSyncStatus()[key] as? [String]
    }

    // MARK: - Ids

    func testAliasesShareOneHealthKitType() {
        XCTAssertEqual(
            OpenWearablesHealthSDK.hkIdentifiers(forTypeIds: ["restingEnergy"]),
            OpenWearablesHealthSDK.hkIdentifiers(forTypeIds: ["basalEnergy"])
        )
        XCTAssertEqual(
            OpenWearablesHealthSDK.hkIdentifiers(forTypeIds: ["bloodPressure"]),
            [HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue, HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue]
        )
        XCTAssertTrue(OpenWearablesHealthSDK.hkIdentifiers(forTypeIds: ["notAType"]).isEmpty)
    }

    // MARK: - Pause / resume

    func testPausedTypesAreKeptAsSentWithoutDuplicates() {
        withTypeControlSDK { sdk in
            sdk.pauseTypes(types: ["heartRate", "notAType", "heartRate"])
            sdk.pauseTypes(types: ["sleep", "heartRate"])

            XCTAssertEqual(sdk.getPausedTypes(), ["heartRate", "notAType", "sleep"])
            XCTAssertEqual(status(sdk, "pausedTypes"), ["heartRate", "notAType", "sleep"])
            XCTAssertEqual(sdk.pausedHKIdentifiers(), [heartRate, sleep])
        }
    }

    func testResumeRemovesOnlyTheGivenTypes() {
        withTypeControlSDK { sdk in
            sdk.pauseTypes(types: ["heartRate", "sleep"])
            sdk.resumeTypes(types: ["heartRate"])

            XCTAssertEqual(sdk.getPausedTypes(), ["sleep"])
        }
    }

    /// `requestAuthorization` rewrites the tracked types and `resetAnchors` restarts the
    /// export; neither is a reason to forget what the user paused.
    func testPausedListSurvivesResetAndTrackedTypeChanges() {
        withTypeControlSDK { sdk in
            sdk.pauseTypes(types: ["heartRate"])

            sdk.resetAnchors()
            sdk.trackedTypes = []

            XCTAssertEqual(sdk.getPausedTypes(), ["heartRate"])
        }
    }

    func testSignOutClearsThePausedList() {
        withTypeControlSDK { sdk in
            StubURLProtocol.install { _ in .status(204) }
            sdk.pauseTypes(types: ["heartRate"])

            sdk.signOut()

            XCTAssertEqual(OpenWearablesHealthSdkKeychain.getPausedTypes(userKey: "user.test-user"), [])
        }
    }

    /// Paused before its first export finished: no anchor, so resume reads its history.
    func testResumingATypeWithoutAnchorReportsAResync() {
        withTypeControlSDK { sdk in
            sdk.defaults.set(true, forKey: sdk.fullDoneKey())
            storeAnchor(sdk, steps)
            sdk.pauseTypes(types: ["heartRate", "steps"])

            sdk.resumeTypes(types: ["heartRate", "steps"])

            XCTAssertEqual(status(sdk, "resyncingTypes"), ["heartRate"])
        }
    }

    // MARK: - Resync

    func testResyncRemovesAnchorAndSessionProgress() {
        withTypeControlSDK { sdk in
            sdk.defaults.set(true, forKey: sdk.fullDoneKey())
            storeAnchor(sdk, heartRate)
            storeAnchor(sdk, steps)
            _ = sdk.startNewSyncState(fullExport: false, types: [])
            sdk.updateTypeProgress(typeIdentifier: heartRate, sentInChunk: 5, isComplete: true, anchorData: Data([9]))

            sdk.resyncTypes(types: ["heartRate"])

            XCTAssertNil(storedAnchor(sdk, heartRate))
            XCTAssertNotNil(storedAnchor(sdk, steps), "other types keep their anchor")
            let state = sdk.loadSyncState()
            XCTAssertNil(state?.typeProgress[heartRate], "a resumed session must not restore the old cursor")
            XCTAssertFalse(state?.completedTypes.contains(heartRate) ?? true)
            XCTAssertEqual(status(sdk, "resyncingTypes"), ["heartRate"])
        }
    }

    func testResyncIgnoresPausedUnknownAndUntrackedTypes() {
        withTypeControlSDK { sdk in
            sdk.defaults.set(true, forKey: sdk.fullDoneKey())
            storeAnchor(sdk, heartRate)
            sdk.pauseTypes(types: ["heartRate"])

            sdk.resyncTypes(types: ["heartRate", "notAType", "vo2Max"])

            XCTAssertNotNil(storedAnchor(sdk, heartRate))
            XCTAssertEqual(status(sdk, "resyncingTypes"), [])
        }
    }

    /// Before the first export is done, a type it has not finished is exported anyway;
    /// one it has finished is read again inside that export.
    func testResyncBeforeInitialExportOnlyTouchesCompletedTypes() {
        withTypeControlSDK { sdk in
            sdk.defaults.set(false, forKey: sdk.fullDoneKey())
            _ = sdk.startNewSyncState(fullExport: true, types: [])
            sdk.updateTypeProgress(typeIdentifier: steps, sentInChunk: 1, isComplete: true, anchorData: Data([7]))
            sdk.updateTypeProgress(typeIdentifier: heartRate, sentInChunk: 1, isComplete: false, anchorData: Data([8]), olderThan: Date())

            sdk.resyncTypes(types: ["heartRate", "steps"])

            let state = sdk.loadSyncState()
            XCTAssertNotNil(state?.typeProgress[heartRate], "the export keeps its cursor")
            XCTAssertNil(state?.typeProgress[steps])
            XCTAssertFalse(state?.completedTypes.contains(steps) ?? true)
            XCTAssertNil(storedAnchor(sdk, steps))
            XCTAssertEqual(status(sdk, "resyncingTypes"), ["steps"])
        }
    }

    func testResyncFinishesWhenTheTypeHasAnAnchorAgain() {
        withTypeControlSDK { sdk in
            sdk.defaults.set(true, forKey: sdk.fullDoneKey())
            storeAnchor(sdk, heartRate)
            sdk.resyncTypes(types: ["heartRate"])

            // The run that reads the history again starts after the resync.
            let runEpoch = sdk.currentTypeEpoch()
            _ = sdk.startNewSyncState(fullExport: false, types: [])
            sdk.updateTypeProgress(typeIdentifier: heartRate, sentInChunk: 3, isComplete: false, anchorData: Data([4]), runEpoch: runEpoch)
            XCTAssertEqual(status(sdk, "resyncingTypes"), ["heartRate"], "still crawling")

            sdk.updateTypeProgress(typeIdentifier: heartRate, sentInChunk: 2, isComplete: true, anchorData: Data([5]), runEpoch: runEpoch)

            XCTAssertEqual(storedAnchor(sdk, heartRate), Data([5]))
            XCTAssertEqual(status(sdk, "resyncingTypes"), [])
        }
    }

    func testAsyncResyncReturnsOnceScheduled() async {
        let sdk = OpenWearablesHealthSDK.shared
        await sdk.resyncTypes(types: [])
    }

    // MARK: - In-flight runs

    func testRunStartedBeforePauseCannotSaveThatTypesProgress() {
        withTypeControlSDK { sdk in
            sdk.defaults.set(true, forKey: sdk.fullDoneKey())
            _ = sdk.startNewSyncState(fullExport: false, types: [])
            let runEpoch = sdk.currentTypeEpoch()

            sdk.pauseTypes(types: ["heartRate"])

            XCTAssertFalse(sdk.updateTypeProgress(
                typeIdentifier: heartRate, sentInChunk: 1, isComplete: true, anchorData: Data([1]), runEpoch: runEpoch
            ))
            XCTAssertNil(storedAnchor(sdk, heartRate))
            XCTAssertNil(sdk.loadSyncState()?.typeProgress[heartRate])

            XCTAssertTrue(sdk.updateTypeProgress(
                typeIdentifier: steps, sentInChunk: 1, isComplete: true, anchorData: Data([2]), runEpoch: runEpoch
            ), "other types of the same run still commit")
            XCTAssertEqual(storedAnchor(sdk, steps), Data([2]))
        }
    }

    func testRunStartedBeforeResyncCannotRestoreTheOldAnchor() {
        withTypeControlSDK { sdk in
            sdk.defaults.set(true, forKey: sdk.fullDoneKey())
            storeAnchor(sdk, heartRate)
            _ = sdk.startNewSyncState(fullExport: false, types: [])
            let runEpoch = sdk.currentTypeEpoch()

            sdk.resyncTypes(types: ["heartRate"])
            sdk.updateTypeProgress(typeIdentifier: heartRate, sentInChunk: 1, isComplete: true, anchorData: Data([6]), runEpoch: runEpoch)

            XCTAssertNil(storedAnchor(sdk, heartRate))
            XCTAssertEqual(status(sdk, "resyncingTypes"), ["heartRate"])
        }
    }

    /// The run in flight never picks the resynced type up again, so another one has to
    /// follow it. Needs a host without HealthKit data, where every run gives the slot
    /// back right away instead of querying.
    func testResyncDuringARunStartsAnotherOnceItEnds() throws {
        try XCTSkipIf(HKHealthStore.isHealthDataAvailable(), "would run live HealthKit queries")
        try withTypeControlSDK { sdk in
            var logs: [String] = []
            let previousOnLog = sdk.onLog
            let previousLogLevel = sdk.logLevel
            sdk.logLevel = .always
            sdk.onLog = { logs.append($0) }
            defer {
                sdk.onLog = previousOnLog
                sdk.logLevel = previousLogLevel
            }
            OpenWearablesHealthSdkKeychain.setSyncActive(true)
            sdk.defaults.set(true, forKey: sdk.fullDoneKey())
            storeAnchor(sdk, heartRate)

            let generation = try XCTUnwrap(sdk.beginSyncRun())
            sdk.resyncTypes(types: ["heartRate"])
            XCTAssertFalse(logs.contains("HealthKit not available"), "no second run while the slot is taken")

            sdk.finishSync(generation: generation)

            XCTAssertTrue(waitUntil { logs.contains("HealthKit not available") }, "the follow-up run should start")
            XCTAssertFalse(sdk.isSyncInProgress)
        }
    }

    func testFinishingARunWithNothingPendingStartsNoOther() throws {
        try XCTSkipIf(HKHealthStore.isHealthDataAvailable(), "would run live HealthKit queries")
        try withTypeControlSDK { sdk in
            var logs: [String] = []
            let previousOnLog = sdk.onLog
            let previousLogLevel = sdk.logLevel
            sdk.logLevel = .always
            sdk.onLog = { logs.append($0) }
            defer {
                sdk.onLog = previousOnLog
                sdk.logLevel = previousLogLevel
            }
            OpenWearablesHealthSdkKeychain.setSyncActive(true)

            let generation = try XCTUnwrap(sdk.beginSyncRun())
            sdk.finishSync(generation: generation)

            XCTAssertFalse(waitUntil(timeout: 0.5) { logs.contains("HealthKit not available") })
        }
    }

    private func sample(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, value: Double) -> HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType.quantityType(forIdentifier: identifier)!,
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: Date(timeIntervalSinceNow: -60), end: Date()
        )
    }

    private func round(_ sdk: OpenWearablesHealthSDK, _ samples: [HKQuantitySample]) -> OpenWearablesHealthSDK.PendingRound {
        let results = samples.map {
            OpenWearablesHealthSDK.TypeRoundResult(
                type: $0.sampleType, samples: [$0], deleted: [], count: 1,
                nextOlderThan: nil, newAnchor: nil, anchorData: nil, isDone: false
            )
        }
        return OpenWearablesHealthSDK.PendingRound(
            withData: results, emptyDone: [], itemCount: samples.count,
            prepared: sdk.prepareUpload(payload: sdk.buildCombinedPayload(samples: samples)),
            roundIndex: 1, fetchMs: 0, mapMs: 0
        )
    }

    /// A round fetched before the pause must not carry the paused type to the server,
    /// where the app may already be deleting it.
    func testRoundFetchedBeforeAPauseUploadsWithoutThatType() throws {
        try withTypeControlSDK { sdk in
            let runEpoch = sdk.currentTypeEpoch()
            let fetched = round(sdk, [
                sample(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), value: 60),
                sample(.stepCount, unit: .count(), value: 100),
            ])

            let unchanged = try XCTUnwrap(sdk.excludingInvalidatedTypes(fetched, typeEpoch: runEpoch))
            XCTAssertEqual(unchanged.itemCount, 2)

            sdk.pauseTypes(types: ["heartRate"])
            let sent = try XCTUnwrap(sdk.excludingInvalidatedTypes(fetched, typeEpoch: runEpoch))

            XCTAssertEqual(sent.withData.map { $0.type.identifier }, [steps])
            XCTAssertEqual(sent.itemCount, 1)
            let prepared = try XCTUnwrap(sent.prepared)
            XCTAssertLessThan(prepared.rawByteCount, try XCTUnwrap(fetched.prepared).rawByteCount)

            sdk.pauseTypes(types: ["steps"])
            let empty = try XCTUnwrap(sdk.excludingInvalidatedTypes(fetched, typeEpoch: runEpoch))
            XCTAssertTrue(empty.withData.isEmpty)
            XCTAssertNil(empty.prepared, "nothing left to upload")
        }
    }

    /// A type skipped on a HealthKit error keeps its position, but its resync has not
    /// read the rest of the history yet; another type completing must not settle it.
    func testResyncSkippedOnAnErrorStaysPendingUntilItsTypeCompletes() {
        withTypeControlSDK { sdk in
            sdk.defaults.set(true, forKey: sdk.fullDoneKey())
            storeAnchor(sdk, heartRate)
            sdk.resyncTypes(types: ["heartRate"])
            let runEpoch = sdk.currentTypeEpoch()
            _ = sdk.startNewSyncState(fullExport: false, types: [])

            sdk.updateTypeProgress(typeIdentifier: heartRate, sentInChunk: 1, isComplete: false, anchorData: Data([1]), runEpoch: runEpoch)
            sdk.updateTypeProgress(typeIdentifier: heartRate, sentInChunk: 0, isComplete: true, anchorData: nil, runEpoch: runEpoch, settlesResync: false)
            XCTAssertEqual(storedAnchor(sdk, heartRate), Data([1]), "the position is kept")
            XCTAssertEqual(status(sdk, "resyncingTypes"), ["heartRate"])

            sdk.updateTypeProgress(typeIdentifier: steps, sentInChunk: 0, isComplete: true, anchorData: Data([2]), runEpoch: runEpoch)
            XCTAssertEqual(status(sdk, "resyncingTypes"), ["heartRate"])

            _ = sdk.startNewSyncState(fullExport: false, types: [])
            sdk.updateTypeProgress(typeIdentifier: heartRate, sentInChunk: 0, isComplete: true, anchorData: Data([3]), runEpoch: sdk.currentTypeEpoch())
            XCTAssertEqual(status(sdk, "resyncingTypes"), [])
        }
    }

    func testPendingResyncOfAnUntrackedTypeIsDropped() {
        withTypeControlSDK { sdk in
            sdk.saveResyncTypeIds(["vo2Max", "heartRate"])
            _ = sdk.startNewSyncState(fullExport: false, types: [])

            sdk.updateTypeProgress(typeIdentifier: steps, sentInChunk: 0, isComplete: true, anchorData: Data([1]))

            XCTAssertEqual(status(sdk, "resyncingTypes"), ["heartRate"])
        }
    }

    // MARK: - Reset

    /// A paused or no-longer-tracked type must not keep its anchor into the next export.
    func testResetAnchorsClearsUntrackedTypesAndPendingResyncs() {
        withTypeControlSDK { sdk in
            sdk.defaults.set(true, forKey: sdk.fullDoneKey())
            storeAnchor(sdk, heartRate)
            storeAnchor(sdk, HKQuantityTypeIdentifier.vo2Max.rawValue)
            sdk.resyncTypes(types: ["heartRate"])
            let runEpoch = sdk.currentTypeEpoch()

            sdk.resetAnchors()

            XCTAssertNil(storedAnchor(sdk, HKQuantityTypeIdentifier.vo2Max.rawValue))
            XCTAssertEqual(status(sdk, "resyncingTypes"), [])
            XCTAssertTrue(sdk.isTypeInvalidated(steps, since: runEpoch), "a run in flight must not write anchors back")
        }
    }
}
