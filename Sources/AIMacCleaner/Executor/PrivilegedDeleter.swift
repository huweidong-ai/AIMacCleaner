import Foundation
import AppKit

/// 以管理员（root）权限删除文件/目录。仅在普通删除因权限不足失败时作为兜底使用。
///
/// ## 机制
/// 通过 `NSAppleScript` 执行：
/// `do shell script "rm -rf " & quoted form of "<path>" with administrator privileges`
/// 系统会弹出标准的密码 / Touch ID 框，验证通过后该命令以 **root** 身份运行。
///
/// 这是 macOS 上"借 root"最轻量的路子，且**不依赖 app 签名**——
/// 当前 app 是 ad-hoc 自签，`SMJobBless` 那种需要 Developer ID + 公证的特权 helper
/// 装不上，而这条路子照常能用（`with administrator privileges` 的鉴权由 SecurityAgent
/// 负责，与调用方签名无关）。
///
/// ## 安全红线（比 FileDeleter 更严）
/// - 仍先过 `FileDeleter.isAllowed` 白名单 + `forbiddenPrefixes` 系统路径保护，
///   **绝不对 `/System`、`/usr` 等动 root 刀**。不在白名单内的路径直接跳过，绝不悄悄用
///   root 删系统文件。
/// - root 删除**不可恢复**（废纸篓对 root 不可见），UI 必须明示"此操作不可撤销"。
/// - 多条失败合并成**一次** AppleScript 调用，只弹一次密码框，避免 N 项弹 N 次。
enum PrivilegedDeleter {

    /// 是否允许对这条路径提权删除（白名单 + 系统路径保护 + 家目录根除外）。
    static func isSafeToEscalate(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard FileDeleter.isAllowed(standardized) else { return false }
        for prefix in FileDeleter.forbiddenPrefixes where standardized.hasPrefix(prefix) {
            return false
        }
        // 不能提权删家目录根 / 废纸篓自身。
        let home = NSHomeDirectory()
        if standardized == home || standardized == home + "/" { return false }
        return true
    }

    /// 以管理员权限删除一组路径（合并为一次授权）。返回每条路径的结果。
    ///
    /// 任意一条不在白名单内都会被跳过（`success = false`），绝不悄悄用 root 删系统文件。
    /// 调用方（UI）应只传入 `FileDeleter.Result.needsElevation == true` 的项，
    /// 但本函数自身也会再校验一遍，双重保险。
    static func delete(_ paths: [String]) -> [FileDeleter.Result] {
        let safe = paths.filter { isSafeToEscalate($0) }
        let skipped = paths.filter { !isSafeToEscalate($0) }
        guard !safe.isEmpty else {
            // 全都不在安全范围内：原样返回失败，绝不执行任何删除。
            return paths.map {
                FileDeleter.Result(path: $0, success: false,
                                   message: L10n.t("路径不在白名单内，拒绝提权删除",
                                                  "Path not on allowlist; refused to escalate"))
            }
        }

        // 拼一条 AppleScript：rm -rf <qf> <qf> ...
        // `quoted form of` 会把路径正确 shell 转义（空格、括号等都安全）。
        let quoted = safe.map { path -> String in
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            return "quoted form of \"\(escaped)\""
        }.joined(separator: " & \" \" & ")
        let script = "do shell script \"rm -rf \" & \(quoted) with administrator privileges"

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        var results: [FileDeleter.Result] = []
        // 先放被安全网拦下的（不可能发生，因为上面已 guard，但保持完整语义）。
        for p in skipped {
            results.append(FileDeleter.Result(path: p, success: false,
                                              message: L10n.t("路径不在白名单内，拒绝提权删除",
                                                             "Path not on allowlist; refused to escalate")))
        }

        if let error {
            // 用户取消密码框 → errorNumber -128；鉴权失败等也有各自编号。
            let number = error[NSAppleScript.errorNumber] as? Int ?? -1
            let msg = (error[NSAppleScript.errorMessage] as? String)
                ?? L10n.t("管理员删除失败（错误 \(number)）", "Admin delete failed (error \(number))")
            for p in safe {
                results.append(FileDeleter.Result(path: p, success: false, message: msg))
            }
            return results
        }

        // 命令执行成功 ≠ 文件真的没了（例如文件被占用，rm 不报错但删不动）。
        // 逐条校验是否真的不存在，给出诚实的结果。
        for p in safe {
            let gone = !FileManager.default.fileExists(atPath: (p as NSString).standardizingPath)
            results.append(FileDeleter.Result(
                path: p,
                success: gone,
                message: gone
                    ? L10n.t("已用管理员权限删除（不可恢复）", "Deleted with admin privileges (unrecoverable)")
                    : L10n.t("管理员删除命令已执行，但文件仍在（可能被占用）",
                             "Admin command ran, but the file is still there (maybe in use)")
            ))
        }
        return results
    }
}
