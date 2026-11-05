import SwiftUI

/// 「大文件清理」tab：扫描体积大且久未访问的文件 / 缓存文件夹，勾选后移到废纸篓。
///
/// 与安全取向一致：默认全不选、删除前二次确认、走废纸篓（可恢复），不碰系统目录。
struct LargeFilesView: View {
    @EnvironmentObject var state: AppState
    @State private var showDeleteConfirm = false
    @State private var showDeleteResult = false
    @State private var deletedCount = 0
    @State private var searchText = ""
    @State private var categoryFilter: FileCategory? = nil

    private var subtitle: String {
        guard state.hasScannedLargeFiles, !state.largeFiles.isEmpty else {
            return L10n.t("找出体积大且久未访问的文件与缓存，腾出磁盘空间",
                          "Find large, long-unused files and caches to free up disk space")
        }
        let total = state.largeFiles.reduce(0) { $0 + $1.size }
        return L10n.t("\(state.largeFiles.count) 个大文件 · 共 \(SizeFormat.human(total))",
                      "\(state.largeFiles.count) large items · \(SizeFormat.human(total)) total")
    }

    private var filtered: [LargeFileItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.largeFiles.filter { item in
            if let c = categoryFilter, item.category != c { return false }
            if q.isEmpty { return true }
            return item.name.lowercased().contains(q) || item.parent.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(L10n.t("移到废纸篓", "Move to Trash"),
               isPresented: $showDeleteConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("移入废纸篓 \(state.selectedLargeFileCount) 项",
                          "Trash \(state.selectedLargeFileCount) items"),
                   role: .destructive) {
                deletedCount = state.deleteSelectedLargeFiles()
                showDeleteResult = true
            }
        } message: {
            Text(L10n.t("将把 \(state.selectedLargeFileCount) 个文件 / 缓存文件夹（约 \(SizeFormat.human(state.selectedLargeFileSize))）移到废纸篓。从废纸篓拖回即可恢复，清空废纸篓才真正删除。",
                          "\(state.selectedLargeFileCount) files/caches (~\(SizeFormat.human(state.selectedLargeFileSize))) will be moved to Trash. Drag them back to recover; emptying Trash deletes for good."))
        }
        .alert(L10n.t("已移到废纸篓", "Moved to Trash"),
               isPresented: $showDeleteResult) {
            Button(L10n.t("好的", "OK"), role: .cancel) {}
        } message: {
            Text(L10n.t("成功移入废纸篓 \(deletedCount) 项，已自动重新扫描。",
                        "Moved \(deletedCount) item(s) to Trash and re-scanned automatically."))
        }
    }

    // MARK: - 头部

    private var header: some View {
        PageHeader(title: L10n.t("大文件清理", "Large files"),
                   subtitle: subtitle) {
            Button {
                Task { await state.scanLargeFiles() }
            } label: {
                Label(state.hasScannedLargeFiles
                      ? L10n.t("重新扫描", "Rescan")
                      : L10n.t("开始扫描", "Scan"),
                      systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(state.isScanningLargeFiles)
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if state.isScanningLargeFiles {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.t("正在扫描下载、文档、桌面与缓存目录…",
                            "Scanning Downloads, Documents, Desktop and Caches…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !state.hasScannedLargeFiles {
            VStack(spacing: 14) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("磁盘空间不够了？", "Running out of disk space?"))
                    .font(.title3)
                VStack(spacing: 4) {
                    Text(L10n.t("一键扫描下载、桌面、文档、影片、图片和缓存目录里「体积大且久未访问」的文件，挑着移到废纸篓。",
                                "One click scans your Downloads, Desktop, Documents, Movies, Pictures and Caches for large, long-unused files — pick what to trash."))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                Button {
                    Task { await state.scanLargeFiles() }
                } label: {
                    Label(L10n.t("开始扫描", "Start scan"), systemImage: "magnifyingglass")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if state.largeFiles.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 48))
                    .foregroundStyle(.green.opacity(0.7))
                Text(L10n.t("没有符合条件的大文件", "No large files matching the criteria"))
                    .font(.title3)
                Text(L10n.t("把阈值调低，或缩短「最少多少天未访问」再试。",
                            "Lower the size threshold or shorten the age filter and try again."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                controls
                Divider()
                list
                bottomBar
            }
        }
    }

    // MARK: - 筛选控件

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // 体积阈值
                HStack(spacing: 6) {
                    Text(L10n.t("大于", "Larger than"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $state.largeFileThresholdMB) {
                        Text("50 MB").tag(50)
                        Text("100 MB").tag(100)
                        Text("200 MB").tag(200)
                        Text("500 MB").tag(500)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                // 最少未访问天数
                HStack(spacing: 6) {
                    Text(L10n.t("未访问超", "Unused for"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $state.largeFileMinAgeDays) {
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await state.scanLargeFiles() }
                } label: {
                    Label(L10n.t("应用并重扫", "Apply & rescan"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(state.isScanningLargeFiles)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField(L10n.t("搜索文件名或路径…", "Search by name or path…"),
                          text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 8)
                // 类别筛选
                Picker(L10n.t("类别", "Category"), selection: $categoryFilter) {
                    Text(L10n.t("全部", "All")).tag(FileCategory?.none)
                    ForEach(FileCategory.allCases) { c in
                        Text(c.displayName).tag(FileCategory?.some(c))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }
        }
        .padding(16)
        .background(Theme.bgCanvas)
    }

    // MARK: - 列表

    private var list: some View {
        List {
            ForEach(filtered) { item in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { state.largeFiles.first(where: { $0.id == item.id })?.selected ?? false },
                        set: { _ in state.toggleLargeFileSelected(item.id) }
                    ))
                    .labelsHidden()
                    .padding(.top, 3)

                    Image(systemName: item.category.icon)
                        .font(.system(size: 15))
                        .frame(width: 18)
                        .foregroundStyle(Theme.accent)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.name)
                                .font(.callout)
                                .lineLimit(1)
                            CategoryPill(category: item.category)
                        }
                        Text(item.parent)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            Text(SizeFormat.human(item.size))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(item.isDirectory ? Theme.riskUserDataText : .primary)
                            Text("·").foregroundStyle(.tertiary)
                            Text(L10n.t("访问于 \(Self.dateStr(item.lastAccess))",
                                        "accessed \(Self.dateStr(item.lastAccess))"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if item.isDirectory {
                                Text(L10n.t("文件夹", "folder"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(L10n.t("在访达中显示", "Reveal in Finder")) {
                        RevealService.revealInFinder(path: item.path)
                    }
                    Button(L10n.t("复制路径", "Copy path")) {
                        RevealService.copyPath(item.path)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        BottomActionBar(
            selectedCount: state.selectedLargeFileCount,
            totalCount: state.largeFiles.count,
            selectedSize: state.selectedLargeFileSize,
            hint: L10n.t("默认全不选，逐项确认", "Nothing selected by default; confirm each"),
            onToggleAll: { on in state.setAllLargeFilesSelected(on) }
        ) {
            Button {
                showDeleteConfirm = true
            } label: {
                Label(L10n.t("移到废纸篓…", "Trash…"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.destructive)
            .disabled(state.selectedLargeFileCount == 0)
            .help(state.selectedLargeFileCount == 0
                  ? L10n.t("先勾选要清理的文件", "Select files first")
                  : L10n.t("把选中的文件移到废纸篓（可恢复）", "Move selected files to Trash (recoverable)"))
        }
    }

    private static func dateStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
}

/// 大文件列表里的小类别标签（色 + 字，不靠纯色传达）。
private struct CategoryPill: View {
    let category: FileCategory
    var body: some View {
        Text(category.displayName)
            .font(.caption2)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.accentSubtle, in: RoundedRectangle(cornerRadius: 4))
    }
}
