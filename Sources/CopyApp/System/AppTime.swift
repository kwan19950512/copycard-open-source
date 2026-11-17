import Foundation

enum AppTime {
    static func remaining(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) else { return "剩余时间估算中…" }
        if seconds >= 3600 {
            let minutes = Int(ceil(seconds / 60))
            return "预计剩余约 \(minutes / 60) 小时 \(minutes % 60) 分钟"
        }
        if seconds >= 60 { return "预计剩余约 \(Int(ceil(seconds / 60))) 分钟" }
        let rounded = seconds >= 10 ? ceil(seconds / 5) * 5 : ceil(seconds)
        return "预计剩余约 \(max(1, Int(rounded))) 秒"
    }
    static func minute(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"; return formatter.string(from: date)
    }
}
