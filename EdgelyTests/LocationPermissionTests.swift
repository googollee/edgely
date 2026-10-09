import XCTest
import CoreLocation
@testable import Edgely

/// 启动时申请定位权限的判断（PRD F6）：该问才问，已经决定的不重复打扰。
final class LocationPermissionTests: XCTestCase {
    func test_requestsWhenUndecidedOrOnlyWhenInUse() {
        XCTAssertTrue(LocationPermission.shouldRequest(for: .notDetermined))
        XCTAssertTrue(LocationPermission.shouldRequest(for: .authorizedWhenInUse), "后台持续定位需要升级到「始终」")
    }

    func test_doesNotRequestOnceDecided() {
        XCTAssertFalse(LocationPermission.shouldRequest(for: .authorizedAlways))
        XCTAssertFalse(LocationPermission.shouldRequest(for: .denied))
        XCTAssertFalse(LocationPermission.shouldRequest(for: .restricted))
    }
}
