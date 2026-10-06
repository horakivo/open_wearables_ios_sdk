import XCTest
@testable import OpenWearablesHealthSDK

/// `syncNow` is public API the React Native wrapper and the host app call directly.
/// Upstream dropped it once; this keeps it from disappearing again unnoticed.
final class SyncNowTests: XCTestCase {

    func testSyncNowRunsASyncAndCallsBack() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(200) }

            var completed = false
            sdk.syncNow { completed = true }

            XCTAssertTrue(waitUntil { completed })
        }
    }
}
