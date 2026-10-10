import Foundation
import CoreLocation

/// App 启动时申请定位权限（PRD F-006、F-014：遵循 iOS 标准弹窗，不做额外引导）。
/// 放在启动时而不是开始录制时：首次使用的系统弹窗不能压在录制界面上，否则弹窗期间的 GPS 点会丢。
final class LocationPermission {
    private let manager = CLLocationManager()

    /// 还没决定、或只授权了"使用期间"（后台持续定位需要"始终"）时才请求；系统对同一次升级只弹一次。
    static func shouldRequest(for status: CLAuthorizationStatus) -> Bool {
        status == .notDetermined || status == .authorizedWhenInUse
    }

    func requestIfNeeded() {
        if LocationPermission.shouldRequest(for: manager.authorizationStatus) {
            manager.requestAlwaysAuthorization()
        }
    }
}

/// F-006：GPS 轨迹记录。权限在 App 启动时已经申请过（见 `LocationPermission`），这里只负责开始 / 停止定位。
final class LocationLogger: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        onLocation?(loc)
    }
}
