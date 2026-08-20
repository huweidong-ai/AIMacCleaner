import SwiftUI
import AppKit

/// 应用自身图标，始终从 bundle 的 AppIcon 读取（与 Dock / Finder 图标同源）。
/// 改 `Sources/IconGen/AIMacCleaner.png` 并重打包后，关于页、侧栏品牌区、Dock 三处自动同步——
/// 不再各自维护一份独立的 SF Symbol / 渐变块。
struct AppIconView: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    init(size: CGFloat, cornerRadius: CGFloat? = nil) {
        self.size = size
        // macOS 标准图标圆角 ≈ 边长的 7/24
        self.cornerRadius = cornerRadius ?? size * 0.1875
    }

    var body: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // 极端兜底：读不到 AppIcon 时用品牌色块，避免空洞
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentActive],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        Image(systemName: "wand.and.rays")
                            .font(.system(size: size * 0.47, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
