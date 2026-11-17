import Foundation
import UserNotifications
import CopyCore

@MainActor final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var delivered = Set<String>()
    func install() { UNUserNotificationCenter.current().delegate = self }
    func requestPermission() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    func update(_ jobs: [TransferJob]) {
        for job in jobs where [.completed, .needsAttention, .cancelled].contains(job.state) {
            guard let ended = job.endedAt else { continue }
            let key = job.id.uuidString + String(ended.timeIntervalSince1970) + job.state.rawValue
            guard delivered.insert(key).inserted else { continue }
            let message = Self.message(for: job)
            send(title: message.title, message: message.body)
        }
    }
    static func message(for job: TransferJob) -> (title: String, body: String) {
        let title: String
        if job.state == .completed { title = job.excludedCount == 0 ? "拷贝并校验完成" : "复制范围校验通过（有排除项）" }
        else { title = job.state == .cancelled ? "拷贝任务已取消" : "拷贝未全部完成，需要处理" }
        let timestamp = job.historicalEndDate.map(AppTime.minute) ?? "未记录"
        var body = "\(job.displayName)\n目标：\(job.destination.path)\n\(job.state == .completed ? "完成" : "结束")时间：\(timestamp)"
        if job.excludedCount > 0 { body += "\n\(job.excludedCount) 项明确排除，未复制、未校验" }
        if job.state == .needsAttention { body += "\n" + (job.message ?? "有 \(job.problemCount) 项待处理，请查看详情") }
        if job.reportStatus == .failed { body += "\n报告未保存，请查看任务详情" }
        return (title, body)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound])
    }
    private func send(title: String, message: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = message
        if UserDefaults.standard.bool(forKey: "notificationSound") { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
