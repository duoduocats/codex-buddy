import Foundation

// Only public pet catalogs and counters live here. A serial actor keeps a clear
// operation ordered with reads and writes; it never touches installed packages.
actor PetCatalogCache {
    static let shared = PetCatalogCache(directory:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("com.duoduocat.codexbuddy/Pets",isDirectory:true))
    let directory: URL
    init(directory: URL) { self.directory = directory.standardizedFileURL }
    private func validateDirectory() throws {
        for url in [directory,directory.deletingLastPathComponent()] {
            if (try? FileManager.default.attributesOfItem(atPath:url.path)[.type] as? FileAttributeType) == .typeSymbolicLink { throw CocoaError(.fileReadNoPermission) }
        }
    }
    private func file(_ name: String) throws -> URL {
        guard !name.isEmpty,name == (name as NSString).lastPathComponent,!name.hasPrefix("."),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else { throw CocoaError(.fileReadNoPermission) }
        try validateDirectory()
        let url = directory.appendingPathComponent(name)
        if (try? FileManager.default.attributesOfItem(atPath:url.path)[.type] as? FileAttributeType) == .typeSymbolicLink { throw CocoaError(.fileReadNoPermission) }
        return url
    }
    func read(_ name: String,limit: Int) -> Data? {
        guard !Task.isCancelled,let url = try? file(name), let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,
              size >= 0,size <= limit,let handle = try? FileHandle(forReadingFrom:url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount:limit+1),data.count <= limit else { return nil }
        return data
    }
    func write(_ data: Data,name: String) throws {
        try Task.checkCancellation()
        let url = try file(name)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }
    func trimPreviews() {
        guard !Task.isCancelled,(try? validateDirectory()) != nil,let entries=try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey,.isSymbolicLinkKey]) else { return }
        let files=entries.filter { $0.lastPathComponent.hasPrefix("preview-") && $0.pathExtension == "png" && (try? $0.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true }
            .sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var total:Int64=0
        for (index,url) in files.enumerated() { total += Int64((try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0);if index >= 256 || total > 32_000_000 { remove(url.lastPathComponent) } }
    }
    func pruneTagFiles(keeping:Set<String>) {
        guard !Task.isCancelled,(try? validateDirectory()) != nil,let entries=try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey]) else { return }
        for url in entries where !keeping.contains(url.lastPathComponent) && (url.lastPathComponent.hasPrefix("source-") || url.lastPathComponent.hasPrefix("taxonomy-")) && url.pathExtension == "json" {
            if (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true { remove(url.lastPathComponent) }
        }
    }
    func remove(_ name: String) { if let url = try? file(name) { try? FileManager.default.removeItem(at:url) } }
    func clear() throws {
        try validateDirectory()
        if FileManager.default.fileExists(atPath:directory.path) { try FileManager.default.removeItem(at:directory) }
    }
    func byteCount() throws -> Int64 {
        try validateDirectory()
        return ApplicationStorage.filesSize(directory)
    }
}
