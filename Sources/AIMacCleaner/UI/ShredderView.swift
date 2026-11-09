import SwiftUI
import UniformTypeIdentifiers

/// 「文件粉碎」tab：把文件 / 目录拖进来，逐字节覆写多遍后彻底删除，不可恢复。
///
/// 安全取向：默认全选以便「拖进来就粉碎」的最短路径；但每次粉碎前必须二次确认，
/// 并明确告知不可逆。粉碎失败（权限不足等）保留在列表里标红，不静默吞掉。
struct ShredderView: View {
    @EnvironmentObject var state: AppState
    @State private var isDropTargeted = false
    @State private var showConfirm = false
    @State private var showResult = false
    @State private var shreddedCount = 0

    private var subtitle: String {
        guard !state.shredItems.isEmpty else {
            return L10n.t("拖入文件或文件夹，覆写后彻底删除",
                         "Drop files or folders to overwrite and permanently delete them")
        }
        let total = state.shredItems.reduce(0) { $0 + $1.size }
        return L10n.t("\(state.shredItems.count) 项 · 合计 \(SizeFormat.human(total))",
                      "\(state.shredItems.count) items · \(SizeFormat.human(total)) total")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(L10n.t("彻底粉碎所选文件？", "Permanently shred selected files?"),
               isPresented: $showConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("粉碎 \(state.selectedShredCount) 项",
                          "Shred \(state.selectedShredCount) items"),
                   role: .destructive) {
                Task {
                    shreddedCount = await state.shredSelected()
                    showResult = true
                }
            }
        } message: {
            Text(L10n.t("这些文件会被随机数据覆写多遍后删除，常规手段无法恢复。此操作不可撤销。",
                        "These files will be overwritten with random data and deleted. This cannot be undone."))
        }
        .alert(L10n.t("粉碎完成", "Shred complete"),
               isPresented: $showResult) {
            Button(L10n.t("好的", "OK"), role: .cancel) {}
        } message: {
            Text(L10n.t("已彻底粉碎 \(shreddedCount) 项。",
                        "\(shreddedCount) item(s) shredded permanently."))
        }
    }

    private var header: some View {
        PageHeader(title: L10n.t("文件粉碎", "File Shredder"), subtitle: subtitle) {
            if !state.shredItems.isEmpty {
                Button {
                    state.clearShredItems()
                } label: {
                    Label(L10n.t("清空列表", "Clear"), systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(state.isShredding)
            }
        }
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        if state.shredItems.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                if state.isShredding {
                    progressBanner
                }
                list
                bottomBar
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "flame.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.destructive.opacity(0.85))
            Text(L10n.t("把文件拖到这里粉碎", "Drop files here to shred"))
                .font(.title3)
            VStack(spacing: 4) {
                Text(L10n.t("支持文件与文件夹，拖入后会先覆写再删除，无法恢复。",
                            "Files and folders are supported. They are overwritten before deletion — unrecoverable."))
            }
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .padding(20)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            ingest(providers)
            return true
        }
    }

    private var progressBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.t("正在粉碎…", "Shredding…"))
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Theme.destructive.opacity(0.08))
    }

    private var list: some View {
        List {
            ForEach(state.shredItems) { item in
                HStack(alignment: .top, spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { item.selected },
                        set: { _ in state.toggleShredSelected(item.id) }
                    ))
                    .labelsHidden()
                    .disabled(item.status == .shredding)
                    .padding(.top, 3)

                    if let icon = NSWorkspace.shared.icon(forFile: item.path) as NSImage? {
                        Image(nsImage: icon)
                            .resizable().frame(width: 26, height: 26)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.name).font(.callout)
                            if item.isDirectory {
                                Text(L10n.t("文件夹", "Folder"))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.accentSubtle,
                                                in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        Text(item.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Text(SizeFormat.human(item.size))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            if item.isDirectory {
                                Text("· \(item.fileCount) \(L10n.t("个文件", "files"))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            if item.status == .shredding {
                                Text("· \(L10n.t("粉碎中", "shredding")) \(Int(item.progress * 100))%")
                                    .font(.caption2).foregroundStyle(Theme.destructive)
                            }
                            if item.status == .failed, let msg = item.message {
                                Text("· \(msg)")
                                    .font(.caption2).foregroundStyle(.red)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }

                        if item.status == .shredding {
                            ProgressView(value: item.progress)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 320)
                                .tint(Theme.destructive)
                        }
                    }
                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        Button {
                            RevealService.revealInFinder(path: item.path)
                        } label: {
                            Image(systemName: "folder").font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("在访达中显示", "Reveal in Finder"))
                        .disabled(item.status == .shredding)

                        Button {
                            state.removeShredItem(item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L10n.t("从列表移除", "Remove from list"))
                        .disabled(item.status == .shredding)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(L10n.t("复制路径", "Copy path")) {
                        RevealService.copyPath(item.path)
                    }
                    Button(L10n.t("在访达中显示", "Reveal in Finder")) {
                        RevealService.revealInFinder(path: item.path)
                    }
                }
            }
        }
        .listStyle(.inset)
        // 列表也支持拖入：追加到现有列表。
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            ingest(providers)
            return true
        }
    }

    private var bottomBar: some View {
        BottomActionBar(
            selectedCount: state.selectedShredCount,
            totalCount: state.shredItems.count,
            selectedSize: state.shredItems.filter { $0.selected }.reduce(0) { $0 + $1.size },
            hint: L10n.t("粉碎前会二次确认，不可逆",
                         "Confirmed before shredding; unrecoverable"),
            onToggleAll: { on in state.setAllShredSelected(on) }
        ) {
            Button {
                showConfirm = true
            } label: {
                Label(L10n.t("粉碎所选", "Shred selected"), systemImage: "flame.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.destructive)
            .disabled(state.selectedShredCount == 0 || state.isShredding)
            .help(state.selectedShredCount == 0
                  ? L10n.t("先拖入或勾选文件", "Drop or select files first")
                  : L10n.t("覆写并彻底删除选中项（二次确认）",
                           "Overwrite and permanently delete selected (with confirmation)"))
        }
    }

    // MARK: 拖入处理

    private func ingest(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                    urls.append(url)
                } else if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty { state.addShredItems(urls) }
        }
    }
}
