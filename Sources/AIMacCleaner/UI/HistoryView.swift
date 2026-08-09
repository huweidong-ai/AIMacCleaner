import SwiftUI

struct HistoryView: View {
    @State private var records: [HistoryStore.RemovalRecord] = []
    @State private var selectedRecords = Set<String>()

    // 两个删除入口都需要确认弹窗保护：删除选中、滑动删除单条。
    @State private var showDeleteSelectedConfirm = false
    @State private var recordToDelete: HistoryStore.RemovalRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                if !selectedRecords.isEmpty {
                    // 删除选中记录：可逆性弱、但非「清空全部」—— 安静红（红字，
                    // 不抢过「清空」）。点击后先出确认弹窗。
                    Button(L10n.t("删除选中 (\(selectedRecords.count))", "Delete selected (\(selectedRecords.count))")) {
                        showDeleteSelectedConfirm = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.destructive)
                }
                Text(L10n.t("\(records.count) 条", "\(records.count) records"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                // 刷新按钮去掉了：历史只在本 app 卸载后增长，而那条路径
                // 已经会主动重读（onAppear + 卸载完成后刷新）。留一个永远
                // 不改变任何东西的按钮，只会让人怀疑是不是漏了什么要手动同步。
                //
                // 多选用共用组件，和扫描页、残留页同一套交互。历史页没有
                // 体积概念，selectedSize 传 nil。
                SelectionToolbar(selectedCount: selectedRecords.count,
                                 totalCount: records.count,
                                 onSelectAll: { selectedRecords = Set(records.map(\.id)) },
                                 onDeselectAll: { selectedRecords.removeAll() })
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
