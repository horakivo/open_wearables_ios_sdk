import XCTest
@testable import OpenWearablesHealthSDK

/// `configure(endpoints:)`: the host app names every URL and the SDK only fills in
/// `{user_id}`.
final class EndpointsTests: XCTestCase {

    private let endpoints = OpenWearablesHealthSDK.Endpoints(
        sync: "https://api.example.test/sync/sdk/users/{user_id}/sync",
        logs: "https://api.example.test/sync/sdk/users/{user_id}/logs"
    )

    func testConfiguredEndpointsAreUsedAsGiven() throws {
        try withIsolatedSDK { sdk, _ in
            try sdk.configure(endpoints: endpoints)

            XCTAssertEqual(
                sdk.syncEndpoint?.absoluteString,
                "https://api.example.test/sync/sdk/users/test-user/sync"
            )
            XCTAssertEqual(
                sdk.logsEndpoint?.absoluteString,
                "https://api.example.test/sync/sdk/users/test-user/logs"
            )
        }
    }

    func testOmittedRefreshAndDisconnectStayOff() throws {
        try withIsolatedSDK { sdk, _ in
            try sdk.configure(endpoints: endpoints)

            XCTAssertNil(sdk.tokenRefreshEndpoint)
            XCTAssertNil(sdk.disconnectEndpoint)
        }
    }

    func testInvalidEndpointIsRejectedAndKeepsThePreviousConfiguration() throws {
        try withIsolatedSDK { sdk, _ in
            try sdk.configure(endpoints: endpoints)

            XCTAssertThrowsError(
                try sdk.configure(endpoints: .init(sync: "/sync/sdk/users/{user_id}/sync", logs: endpoints.logs))
            )
            XCTAssertEqual(OpenWearablesHealthSdkKeychain.getEndpoints(), endpoints)
        }
    }

    /// A background relaunch reads the persisted endpoints before `configure` runs.
    func testPersistedEndpointsServeAFreshProcess() throws {
        try withIsolatedSDK { sdk, _ in
            try sdk.configure(endpoints: endpoints)
            sdk.endpoints = nil

            XCTAssertEqual(
                sdk.syncEndpoint?.absoluteString,
                "https://api.example.test/sync/sdk/users/test-user/sync"
            )
        }
    }
}
