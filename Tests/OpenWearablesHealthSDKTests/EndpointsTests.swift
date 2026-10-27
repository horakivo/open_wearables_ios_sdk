import XCTest
@testable import OpenWearablesHealthSDK

/// `configure(endpoints:)`: the host app names every URL and the SDK only fills in
/// `{user_id}`.
final class EndpointsTests: XCTestCase {

    private let endpoints = OpenWearablesHealthSDK.Endpoints(
        sync: "https://api.example.test/sync/sdk/users/{user_id}/sync",
        logs: "https://api.example.test/sync/sdk/users/{user_id}/logs"
    )

    func testConfiguredEndpointsAreUsedAsGiven() {
        withIsolatedSDK { sdk, _ in
            sdk.configure(endpoints: endpoints)

            XCTAssertEqual(
                sdk.syncEndpoint?.absoluteString,
                "https://api.example.test/sync/sdk/users/test-user/sync"
            )
            XCTAssertEqual(
                sdk.logsEndpoint?.absoluteString,
                "https://api.example.test/sync/sdk/users/test-user/logs"
            )
            XCTAssertNil(sdk.apiBaseUrl)
        }
    }

    func testOmittedRefreshAndDisconnectStayOff() {
        withIsolatedSDK { sdk, _ in
            sdk.configure(endpoints: endpoints)

            XCTAssertNil(sdk.tokenRefreshEndpoint)
            XCTAssertNil(sdk.disconnectEndpoint)
        }
    }

    func testOptionalEndpointsResolveWhenGiven() {
        withIsolatedSDK { sdk, _ in
            sdk.configure(endpoints: .init(
                sync: endpoints.sync,
                logs: endpoints.logs,
                tokenRefresh: "https://auth.example.test/refresh",
                disconnect: "https://api.example.test/users/{user_id}/apple"
            ))

            XCTAssertEqual(sdk.tokenRefreshEndpoint?.absoluteString, "https://auth.example.test/refresh")
            XCTAssertEqual(
                sdk.disconnectEndpoint?.absoluteString,
                "https://api.example.test/users/test-user/apple"
            )
        }
    }

    func testInvalidTemplateStopsUploadsInsteadOfUsingTheHost() {
        withIsolatedSDK(host: "https://api.example.test/data") { sdk, _ in
            sdk.endpoints = .init(sync: "not-a-url", logs: endpoints.logs)

            XCTAssertNil(sdk.syncEndpoint)
        }
    }

    /// A background relaunch reads the persisted endpoints before `configure` runs.
    func testPersistedEndpointsServeAFreshProcess() {
        withIsolatedSDK { sdk, _ in
            sdk.configure(endpoints: endpoints)
            sdk.endpoints = nil

            XCTAssertEqual(
                sdk.syncEndpoint?.absoluteString,
                "https://api.example.test/sync/sdk/users/test-user/sync"
            )
        }
    }

    func testConfigureHostClearsConfiguredEndpoints() {
        withIsolatedSDK { sdk, _ in
            sdk.configure(endpoints: endpoints)
            sdk.configure(host: "https://api.example.test/data")

            XCTAssertNil(OpenWearablesHealthSdkKeychain.getEndpoints())
            XCTAssertEqual(
                sdk.syncEndpoint?.absoluteString,
                "https://api.example.test/data/api/v1/sdk/users/test-user/sync"
            )
        }
    }
}
