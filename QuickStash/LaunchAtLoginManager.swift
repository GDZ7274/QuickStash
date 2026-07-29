import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool = false

    private init() {
        checkStatus()
    }

    func checkStatus() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            isEnabled = service.status == .enabled
        }
    }

    func toggle() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp

            do {
                if service.status == .enabled {
                    try service.unregister()
                    isEnabled = false
                } else {
                    try service.register()
                    isEnabled = true
                }
            } catch {
                print("❌ 开机自启动设置失败: \(error.localizedDescription)")
            }
        }
    }
}
