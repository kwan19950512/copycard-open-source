import SwiftUI

struct PendingCopyBadge: View {
    var body: some View {
        Image(systemName: "doc.on.doc.fill")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .padding(5).background(Color(nsColor: .systemOrange), in: Circle())
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .help("已加入待拷贝栏，尚未提交任务")
            .accessibilityLabel("已加入待拷贝栏")
            .allowsHitTesting(false)
    }
}
