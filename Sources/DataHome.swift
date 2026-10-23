import Foundation

enum AppDataHomeError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "找不到原来的 Pan's Desktop 数据文件夹。为保留现有分区，已停止启动；请恢复原文件夹后重试。没有创建替代分区或移动文件。"
    }
}

enum AppDataHome {
    // Only the locally installed app carries this bookmark. Portable downloads
    // keep their existing adjacent-folder layout and contain no personal paths.
    static func resolve(bundleURL: URL, bookmarkURL: URL?) throws -> URL {
        guard let bookmarkURL else { return bundleURL.deletingLastPathComponent() }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: Data(contentsOf: bookmarkURL),
                              options: [.withoutUI, .withoutMounting], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            guard url.isFileURL,
                  (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("Configuration/zones.json").path)
            else { throw AppDataHomeError.unavailable }
            return url.standardizedFileURL
        } catch { throw AppDataHomeError.unavailable }
    }
}
