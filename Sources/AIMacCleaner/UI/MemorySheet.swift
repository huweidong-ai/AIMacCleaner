import SwiftUI

/// 长期记忆面板：看、加、删。
///
/// 存在的理由不是「多一个界面」，而是**记忆不能是黑盒**。这里的每一条都会
/// 跟着每次提问发给模型，带路径的还会让残留扫描直接跳过对应目录 ——
/// 一个能悄悄改变删除行为的机制，必须有地方让用户看见它、并一键撤销。
///
/// 入口：「问 AI」头部的「⋯」菜单，或输入 `/memory`。
struct MemorySheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showClearConfirm = false
    /// 上一次操作的反馈（多为拒绝理由：太长 / 已满）。成功时清空。
    @State private var notice: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.memoryNotes.isEmpty { emptyState } else { list }
            Divider()
            composer
            Divider()
            SheetActionBar {
                EmptyView()
            } trailing: {
                SheetCloseButton(title: L10n.t("关闭", "Close")) { dismiss() }
            }
        }
        .frame(width: 580, height: 480)
        .confirmationDialog(L10n.t("清空全部记忆？", "Clear all memories?"),
                            isPresented: $showClearConfirm) {
            Button(L10n.t("全部删除", "Delete all"), role: .destructive) {
                state.forgetAllNotes()
                notice = nil
            }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("删除后不可恢复。对话记录不受影响。",
                        "This can't be undone. Your chat history is unaffected."))
        }
        .background(Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
        .blanketDismiss { dismiss() }
        .frame(width: 660, height: 560)
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Label(L10n.t("长期记忆", "Long-term memory"), systemImage: "brain")
                .font(.system(size: 14, weight: .semibold))
            if !state.memoryNotes.isEmpty {
                Text("\(state.memoryNotes.count) / \(MemoryPolicy.maxNotes)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !state.memoryNotes.isEmpty {
                Button(L10n.t("清空", "Clear all")) { showClearConfirm = true }
                    .controlSize(.small)
            }
            Button {
                RevealService.revealDataFile(MemoryStore.shared.fileURL)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(L10n.t("在 Finder 中显示 memory.json", "Reveal memory.json in Finder"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 空态

    private var emptyState: some View {
        EmptyStateView(
            icon: "brain",
            title: L10n.t("还没有记住任何事", "Nothing remembered yet"),
            message: L10n.t("""
                在这里或对话框里用 /remember 记下要我长期记住的信息，例如\
                「~/Library/Application Support/JetBrains 别动，IDEA 还装着」。
                记忆不会被 /new 清掉，也不会随 15 轮上下文滚走。
                """, """
                Use /remember here or in the chat to save something long-term — e.g. \
                "don't touch ~/Library/Application Support/JetBrains, IDEA is still installed".
                Memories survive /new and never scroll out of the 15-turn window.
                """)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 列表

    private var list: some View {
        List {
            ForEach(state.memoryNotes) { note in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(note.text)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Text(note.dateText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        Button {
                            state.forgetNote(note.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("删掉这条记忆", "Forget this"))
                    }
                    // 带路径的记忆会真正改变扫描结果，必须显式标出来 ——
                    // 用户有权知道哪一条正在让扫描器闭嘴。
                    if !note.paths.isEmpty {
                        ForEach(note.paths, id: \.self) { p in
                            HStack(spacing: 4) {
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.system(size: 9))
                                Text(MemoryPolicy.abbreviate(p))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(Theme.accent)
                        }
                        Text(L10n.t("扫描时跳过（含其子目录与父目录）",
                                    "Skipped when scanning (including sub- and parent dirs)"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - 新增

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(L10n.t("记住一件事…（提到的路径会自动加入扫描豁免）",
                                 "Remember something… (any path mentioned becomes scan-exempt)"),
                          text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(commit)
                Button(L10n.t("记住", "Remember"), action: commit)
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let notice {
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.t("这些内容会随每次提问一起发给模型，优先于它的默认判断。",
                            "These are sent with every question and override the model's default judgement."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 走和 `/remember` **完全相同**的那条路径（`AppState.rememberNote`），
    /// 所以两个入口的校验、抽路径、上限判定不可能出现分歧。
    private func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let before = state.memoryNotes.count
        let result = state.rememberNote(t)
        if state.memoryNotes.count > before {
            draft = ""
            notice = nil
        } else {
            // 没写进去 —— result 就是拒绝理由，原样端给用户。
            notice = result
        }
    }
}
