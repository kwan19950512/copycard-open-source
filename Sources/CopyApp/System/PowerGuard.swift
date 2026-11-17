import Foundation

@MainActor final class PowerGuard {
    private var activity: NSObjectProtocol?
    func update(activeCount: Int) {
        if activeCount > 0 && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "正在拷贝并校验素材")
        } else if activeCount == 0, let activity {
            ProcessInfo.processInfo.endActivity(activity); self.activity = nil
        }
    }
}
