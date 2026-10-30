import Foundation

/// Presentation-only translation for historical receipt text. Stored archives remain unchanged.
nonisolated enum ModelLibraryMessageLocalization {
    static func reason(_ raw: String) -> String {
        switch raw {
        case "非数据类型": return PalmiL10n.tr("ml.error.invalidDataType")
        case "无法解码远程搜索配置": return PalmiL10n.tr("ml.error.searchDecode")
        case "无法读取模型库文件": return PalmiL10n.tr("ml.error.fileRead")
        case "模型库文件格式无法识别": return PalmiL10n.tr("ml.error.fileFormat")
        default:
            if raw.hasPrefix("未知版本 ") {
                return PalmiL10n.tr("ml.error.unknownVersion", String(raw.dropFirst("未知版本 ".count)))
            }
            return raw
        }
    }

    static func receiptNote(_ raw: String) -> String {
        let patterns: [(String, String)] = [
            ("^旧当前方案主模型 (.+) 不属于主模型候选或已失效，保持未配置。$", "ml.migration.note.primaryInvalid"),
            ("^旧模型配置归档无法解析（(.+)），原始数据已保留且不会被覆盖。$", "ml.migration.note.unreadable"),
            ("^旧模型配置归档来自更新版本（v(.+)），原始数据已保留且不会被覆盖。$", "ml.migration.note.future")
        ]
        for (pattern, key) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw) else { continue }
            return PalmiL10n.tr(key, reason(String(raw[range])))
        }
        return raw
    }
}

extension ModelLibraryMigrationReceipt {
    var localizedNotes: [String] { notes.map(ModelLibraryMessageLocalization.receiptNote) }
}

extension ModelLibraryConflict {
    var localizedFieldTitle: String {
        if field.hasPrefix("scope.") { return PalmiL10n.tr("chat.model") }
        switch field.split(separator: ".").last {
        case "providerModelID": return PalmiL10n.tr("ml.model.providerID")
        case "alias": return PalmiL10n.tr("ml.model.name")
        case "vision": return PalmiL10n.tr("ml.model.imageInput")
        case "imageOnly": return PalmiL10n.tr("image.generation")
        case "connection": return PalmiL10n.tr("ml.web.service")
        case "endpoint": return PalmiL10n.tr("ml.web.endpoint")
        case "credential": return PalmiL10n.tr("model.field.apiKey")
        case "main": return PalmiL10n.tr("ml.mainModel")
        case "exists", "deleteVersusEdit": return PalmiL10n.tr("ml.conflicts.existence")
        default:
            switch subject {
            case .connection: return PalmiL10n.tr("ml.web.service")
            case .model: return PalmiL10n.tr("model.model.title")
            case .defaultMainModel: return PalmiL10n.tr("ml.mainModel")
            case .scope: return PalmiL10n.tr("chat.model")
            }
        }
    }
}
