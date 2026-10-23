import Foundation

enum AppLanguage {
    // The override is used only by isolated test processes and test app bundles.
    // Production bundles omit the key and follow the system's preferred language.
    static var preferredLanguage: String {
        ProcessInfo.processInfo.environment["PANS_DESKTOP_TEST_LANGUAGE"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "PansDesktopTestingLanguage") as? String)
            ?? Locale.preferredLanguages.first ?? "en"
    }
    static var usesChinese: Bool { preferredLanguage.lowercased().hasPrefix("zh") }

    static func byteCount(_ count: Int) -> String {
        if usesChinese { return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }
        return Int64(count).formatted(.byteCount(style: .file).locale(Locale(identifier: "en_US")))
    }

    static func isInboxTitle(_ title: String) -> Bool {
        title == "待处理" || title == "Inbox"
    }

    // Translate old activity labels for display only; never rewrite saved records.
    static func historyTitle(_ title: String) -> String {
        guard !usesChinese else { return title }
        if title == "放回原位置" { return "Return to Original Location" }
        if title == "拖出分区移动" { return "Move out by dragging" }
        if title.hasPrefix("撤销：") { return "Undo: " + historyTitle(String(title.dropFirst(3))) }
        if title.hasPrefix("移到废纸篓：") { return "Move to Trash: " + String(title.dropFirst(6)) }
        let formats: [(String, String)] = [
            ("^收纳至“(.*)”$", "Collect into “%@”"),
            ("^调整“(.*)”内的排列$", "Reorder items in “%@”"),
            ("^转移引用至“(.*)”$", "Transfer references to “%@”"),
            ("^移入文件夹“(.*)”$", "Move into folder “%@”"),
            ("^移出分区至“(.*)”$", "Move out of partition to “%@”"),
            ("^移出 ([0-9]+) 个文件至“(.*)”$", "Move %@ items out to “%@”")
        ]
        for (pattern, format) in formats {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { continue }
            var translated = format
            for i in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: i), in: title), let slot = translated.range(of: "%@") else { continue }
                translated.replaceSubrange(slot, with: title[range])
            }
            return translated
        }
        return title
    }
}

// Translate interface text only. User titles, file names, file paths, identifiers,
// storage directory names, and existing configuration values are never translated.
func L(_ chinese: String, _ english: String) -> String {
    AppLanguage.usesChinese ? chinese : english
}
