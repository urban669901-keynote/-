import Foundation

/// 把手機送來的文字整理成可安全顯示的一行彈幕。
public enum MessageSanitizer {
    /// 以「看得到的字元」（grapheme）計算，一個 Emoji（含膚色、家庭組合）算 1 個字。
    public static let defaultMaxLength = 40

    /// 每個字元最多保留的附加符號數，避免「Zalgo」亂碼把行高撐爆。
    static let maxMarksPerCharacter = 2

    public static func sanitize(_ raw: String, maxLength: Int = defaultMaxLength) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                // 換行、Tab 等一律變成空白。
                scalars.append(" ")
            case .format:
                // 只保留 Emoji 需要的 ZWJ 與 tag 字元（地區旗幟）；
                // 其他像 RTL override、零寬空白等直接丟掉。
                if scalar.value == 0x200D || (0xE0020...0xE007F).contains(scalar.value) {
                    scalars.append(scalar)
                }
            case .surrogate, .privateUse, .unassigned:
                continue
            default:
                scalars.append(scalar)
            }
        }

        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        var result = ""
        var count = 0
        for character in collapsed {
            guard count < maxLength else { break }
            result.append(limitMarks(character))
            count += 1
        }
        return result.isEmpty ? nil : result
    }

    private static func limitMarks(_ character: Character) -> String {
        var marks = 0
        var kept = String.UnicodeScalarView()
        for scalar in character.unicodeScalars {
            let category = scalar.properties.generalCategory
            let isMark = category == .nonspacingMark || category == .enclosingMark
            // 變體選擇符（FE0E/FE0F）與 keycap（20E3）是 Emoji 的一部分，不算數。
            let isEmojiComponent = (0xFE00...0xFE0F).contains(scalar.value) || scalar.value == 0x20E3
            if isMark && !isEmojiComponent {
                marks += 1
                if marks > maxMarksPerCharacter { continue }
            }
            kept.append(scalar)
        }
        return String(kept)
    }
}
