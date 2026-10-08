import SwiftUI
import AppKit

/// 用原生 `NSTextView` 渲染「可选中」文字，作为 SwiftUI `Text` + `.textSelection(.enabled)` 的替代。
///
/// 为什么不用 `Text(...).textSelection(.enabled)`：
/// 在 `ScrollView`（尤其对话很长时）里，SwiftUI 的 `Text` 选中要借助 AppKit 的字段编辑器，
/// 点击开始选词会让选区布局与 SwiftUI 的差量比对互相反复触发 —— 主线程陷入死循环，
/// 表现为「转圈 / 鼠标卡死 / 整段文字消失 / 未响应」。这是 macOS SwiftUI 一个长期存在的坑。
///
/// `NSTextView` 本身在滚动容器里选中、高亮、复制都是 AppKit 原生支持的，不会卡死。
///
/// 高度由 `SizingTextView.intrinsicContentSize` 按当前宽度算出（SwiftUI 用它给
/// `NSViewRepresentable` 定高）；宽度跟随 SwiftUI 给出的可用宽度自动换行。
struct SelectableText: NSViewRepresentable {
    /// 已排好版（含前景色 / 段落行高 / 加粗等）的富文本。
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> SizingTextView {
        let tv = SizingTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.usesFontPanel = false
        tv.allowsUndo = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.autoresizingMask = []
        tv.translatesAutoresizingMaskIntoConstraints = false
        if let tc = tv.textContainer {
            tc.widthTracksTextView = true
            tc.heightTracksTextView = false
            tc.lineFragmentPadding = 0
            tc.lineBreakMode = .byWordWrapping
            tc.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }
        return tv
    }

    func updateNSView(_ tv: SizingTextView, context: Context) {
        // 只在文字真正变化时才重设：保留用户已建立的选区 / 光标，避免每次父视图刷新都重置。
        if tv.textStorage == nil
            || tv.textStorage!.string != attributed.string
            || tv.textStorage!.length != attributed.length {
            tv.textStorage?.setAttributedString(attributed)
            tv.invalidateIntrinsicContentSize()
        }
    }
}

/// `NSTextView` 默认 `intrinsicContentSize` 的高度是 `NSViewNoIntrinsicMetric(-1)`，
/// 直接用在 SwiftUI 里会被当成 0 高、文字整段消失。
/// 这里用「当前 frame 宽度 → 排版 → 已用矩形高度」反推一个有效的固有高度。
final class SizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer, lm.numberOfGlyphs > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height
        return NSSize(width: NSView.noIntrinsicMetric, height: max(h, 0))
    }
}

extension SelectableText {
    /// 把「字体 + 前景色 + 行高」一次性烤进 `NSAttributedString`，供 `NSTextView` 使用
    /// （SwiftUI 的 `.font` / `.foregroundStyle` 对 NSViewRepresentable 无效）。
    ///
    /// - Parameters:
    ///   - raw: 原始字符串（可能含行内 markdown）。
    ///   - fontSize: 基础字号。
    ///   - markdown: 是否按行内 markdown 解析（保留换行 + 加粗 / 斜体 / 行内代码）。
    ///   - color: 前景色（用户气泡用白，AI 气泡用 label 色，随深色模式自适应）。
    static func styled(raw: String,
                      fontSize: CGFloat,
                      markdown: Bool,
                      color: NSColor) -> NSAttributedString {
        let base: NSAttributedString
        if markdown {
            let opts = AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            let asw = (try? AttributedString(markdown: raw, options: opts)) ?? AttributedString(raw)
            base = NSAttributedString(asw)
        } else {
            base = NSAttributedString(string: raw)
        }
        let m = NSMutableAttributedString(attributedString: base)
        let full = NSRange(location: 0, length: m.length)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = fontSize * 0.32      // 约 13pt→4.2，匹配 SwiftUI 默认观感
        para.paragraphSpacing = 0
        m.addAttribute(.foregroundColor, value: color, range: full)
        m.addAttribute(.paragraphStyle, value: para, range: full)
        // 没有显式字体（纯文本 / markdown 未标注处）补一个基础字体，保证字号正确。
        m.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil {
                m.addAttribute(.font,
                               value: NSFont.systemFont(ofSize: fontSize),
                               range: range)
            }
        }
        return m
    }
}
