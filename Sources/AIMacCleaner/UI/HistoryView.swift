import SwiftUI

struct HistoryView: View {
    @State private var records: [HistoryStore.RemovalRecord] = []
    @State private var selectedRecords = Set<String>()

    // 两个删除入口都需要确认弹窗保护：删除选中、滑动删除单条。
    @State private var showDeleteSelectedConfirm = false
    @State private var recordToDelete: HistoryStore.RemovalRecord?
    /// 点击查看某条历史记录的详情。
    @State private var selectedRecord: HistoryStore.RemovalRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // 多选用共用组件，放在左侧与列表勾选框列对齐。
                // 历史页没有体积概念，selectedSize 传 nil。
                SelectionToolbar(selectedCount: selectedRecords.count,
                                 totalCount: records.count,
                                 onSelectAll: { selectedRecords = Set(records.map(\.id)) },
                                 onDeselectAll: { selectedRecords.removeAll() })
                if !selectedRecords.isEmpty {
                    // 删除选中记录：可逆性弱、但非「清空全部」—— 安静红（红字）。
                    // 点击后先出确认弹窗。
                    Button(L10n.t("删除选中 (\(selectedRecords.count))", "Delete selected (\(selectedRecords.count))")) {
                        showDeleteSelectedConfirm = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.destructive)
                }
                Spacer()
                Text(L10n.t("\(records.count) 条", "\(records.count) records"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text(L10n.t("暂无卸载历史", "No uninstall history yet"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedRecords) {
                    ForEach(records) { record in
                        HStack(spacing: 8) {
                            // 勾选框常驻。左上角那个按钮现在是「全选/全不选」开关，
                            // 不再是模式切换 —— 藏起勾选框的话，「已选 N 项」
                            // 就无从核对，也没法只取消其中一条。
                            Image(systemName: selectedRecords.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedRecords.contains(record.id) ? Color.accentColor : .secondary)
                                .onTapGesture {
                                    if selectedRecords.contains(record.id) {
                                        selectedRecords.remove(record.id)
                                    } else {
                                        selectedRecords.insert(record.id)
                                    }
                                }
                            HistoryRow(record: record)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedRecord = record
                                }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                recordToDelete = record
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            records = HistoryStore.listAll()
        }
        // 删除选中
        .sheet(isPresented: $showDeleteSelectedConfirm) {
            HistoryConfirmSheet(
                title: L10n.t("确认删除选中记录", "Confirm delete selected"),
                message: L10n.t("即将删除 \(selectedRecords.count) 条选中的历史记录。此操作不可恢复。", "About to delete \(selectedRecords.count) selected history records. This cannot be undone."),
                confirmTitle: L10n.t("删除", "Delete"),
                isDestructive: true,
                onConfirm: {
                    for id in selectedRecords {
                        if let record = records.first(where: { $0.id == id }) {
                            HistoryStore.remove(record)
                        }
                    }
                    records = HistoryStore.listAll()
                    selectedRecords.removeAll()
                }
            )
        }
        // 滑动删除单条：recordToDelete 被赋值时弹出确认。
        .sheet(item: $recordToDelete) { record in
            HistoryConfirmSheet(
                title: L10n.t("确认删除记录", "Confirm delete record"),
                message: L10n.t("即将删除「\(record.targetName)」的历史记录。此操作不可恢复。", "About to delete the history record for \"\(record.targetName)\". This cannot be undone."),
                confirmTitle: L10n.t("删除", "Delete"),
                isDestructive: true,
                onConfirm: {
                    HistoryStore.remove(record)
                    records = HistoryStore.listAll()
                    selectedRecords.remove(record.id)
                }
            )
        }
        // 点击查看某条历史记录的完整日志。
        .sheet(item: $selectedRecord) { record in
            HistoryDetailSheet(record: record)
        }
    }
}

struct HistoryRow: View {
    let record: HistoryStore.RemovalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.targetName).font(.headline)
                Spacer()
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label(L10n.t("\(record.deletedCount) 项", "\(record.deletedCount) items"), systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.success)
                Label(L10n.t("\(record.failedCount) 失败", "\(record.failedCount) failed"), systemImage: "xmark.circle")
                    .foregroundStyle(record.failedCount > 0 ? Theme.destructive : .secondary)
                if let manual = record.manualCount, manual > 0 {
                    Label(L10n.t("\(manual) 需手动", "\(manual) manual"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                }
                // v1.3 起走废纸篓，trashedBytes 才是有值的那个；旧记录（v1.2 及
                // 更早）没有这个字段，回落到 freedBytes 才不会显示成 0 B。
                if let trashed = record.trashedBytes, trashed > 0 {
                    Label(SizeFormat.human(trashed), systemImage: "trash")
                        .foregroundStyle(Color.accentColor)
                        .help("已移到废纸篓，清空废纸篓后才真正释放磁盘空间")
                } else {
                    Label(SizeFormat.human(record.freedBytes), systemImage: "trash")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 历史页专用确认弹窗

/// 历史记录的删除只涉及本地数据库，但仍是不可逆操作，需要确认。
/// 与 ConfirmSheet 分开：不需要展示路径列表，只需要一句说明 + 红按钮。
private struct HistoryConfirmSheet: View {
    @Environment(\.dismiss) var dismiss

    let title: String
    let message: String
    let confirmTitle: String
    let isDestructive: Bool
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.title3.bold())
                .foregroundStyle(Theme.warning)

            Text(message)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.t("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    dismiss()
                    onConfirm()
                } label: {
                    Text(confirmTitle)
                }
                .buttonStyle(.borderedProminent)
                .tint(isDestructive ? Theme.destructive : Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - 历史记录详情弹窗

/// 历史记录详情：展示一次卸载的统计摘要与完整日志。
/// 日志与历史记录一起存在 JSONL 里；删除/清空历史时一并消失，不留痕迹。
private struct HistoryDetailSheet: View {
    @Environment(\.dismiss) var dismiss
    let record: HistoryStore.RemovalRecord
    @State private var toast: String? = nil
    @State private var toastTone: Bool = false

    var statusIcon: (name: String, color: Color) {
        if record.failedCount > 0 {
            return ("exclamationmark.triangle.fill", Theme.warning)
        }
        if let manual = record.manualCount, manual > 0 {
            return ("exclamationmark.triangle.fill", Theme.warning)
        }
        return ("checkmark.circle.fill", Theme.success)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(record.targetName, systemImage: statusIcon.name)
                    .font(.title2.bold())
                    .foregroundStyle(statusIcon.color)
                Spacer()
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            HStack(spacing: 10) {
                HistoryDetailStat(value: "\(record.deletedCount)", label: L10n.t("已处理", "Processed"), tint: Theme.success)
                if record.failedCount > 0 {
                    HistoryDetailStat(value: "\(record.failedCount)", label: L10n.t("失败", "Failed"), tint: Theme.destructive)
                }
                if let manual = record.manualCount, manual > 0 {
                    HistoryDetailStat(value: "\(manual)", label: L10n.t("需手动", "Manual"), tint: Theme.warning)
                }
                if record.freedBytes > 0 {
                    HistoryDetailStat(value: SizeFormat.human(record.freedBytes), label: L10n.t("直接释放", "Freed"), tint: .primary)
                }
                if let trashed = record.trashedBytes, trashed > 0 {
                    HistoryDetailStat(value: SizeFormat.human(trashed), label: L10n.t("进废纸篓", "To Trash"), tint: Theme.accent)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)

            Divider()

            if let log = record.log, !log.isEmpty {
                ScrollView {
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text(L10n.t("没有保存日志（可能是早期历史记录）", "No log saved (older history record)"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
            }

            Divider()
            SheetActionBar {
                if let log = record.log, !log.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log, forType: .string)
                        toast = L10n.t("已复制日志", "Log copied")
                        toastTone = false
                    } label: {
                        Label(L10n.t("复制日志", "Copy log"), systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
            } trailing: {
                SheetCloseButton(title: L10n.t("关闭", "Close")) { dismiss() }
            }
        }
        .frame(width: 560, height: 460)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(toastTone ? Theme.destructive : .primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 60)
                    .transition(.opacity)
            }
        }
    }
}

private struct HistoryDetailStat: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider, lineWidth: 1))
    }
}
