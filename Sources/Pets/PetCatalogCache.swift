import Foundation

// Only public pet catalogs and counters live here. A serial actor keeps a clear
// operation ordered with reads and writes; it never touches installed packages.
actor PetCatalogCache {
    static let shared = PetCatalogCache(directory:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("com.duoduocat.codexbuddy/Pets",isDirectory:true))
    let directory: URL
    private struct PreviewFile { let bytes:Int;let date:Date }
    private var previewFiles:[String:PreviewFile]?
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
        if name.hasPrefix("preview-") { previewFiles=nil }
    }
    // Build the small LRU index once, then update it with each atomic write.
    // Scanning and sorting the directory after every card made a burst of N
    // thumbnails pay N full directory walks on the same serial cache actor.
    func writePreview(_ data:Data,name:String) throws {
        try Task.checkCancellation()
        guard name.hasPrefix("preview-"),name.hasSuffix(".png"),data.count <= 1_000_000 else { throw CocoaError(.fileWriteInvalidFileName) }
        var files=loadPreviewFiles()
        try write(data,name:name)
        files[name]=PreviewFile(bytes:data.count,date:Date());previewFiles=files
        trimPreviews()
    }
    private func loadPreviewFiles()->[String:PreviewFile] {
        if let previewFiles { return previewFiles }
        guard (try? validateDirectory()) != nil,let entries=try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey,.isSymbolicLinkKey]) else { return [:] }
        var files=[String:PreviewFile]()
        for url in entries where url.lastPathComponent.hasPrefix("preview-") && url.pathExtension == "png" {
            guard let values=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.isSymbolicLinkKey]),values.isSymbolicLink != true else { continue }
            files[url.lastPathComponent]=PreviewFile(bytes:max(0,values.fileSize ?? 0),date:values.contentModificationDate ?? .distantPast)
        }
        previewFiles=files;return files
    }
    func trimPreviews() {
        guard !Task.isCancelled,(try? validateDirectory()) != nil else { return }
        var files=loadPreviewFiles();var bytes=files.values.reduce(Int64(0)) { $0+Int64($1.bytes) }
        guard files.count > 256 || bytes > 32_000_000 else { return }
        for (name,file) in files.sorted(by:{$0.value.date < $1.value.date}) {
            guard files.count > 256 || bytes > 32_000_000 else { break }
            remove(name);files.removeValue(forKey:name);bytes -= Int64(file.bytes)
        }
        previewFiles=files
    }
    func pruneTagFiles(keeping:Set<String>) {
        guard !Task.isCancelled,(try? validateDirectory()) != nil,let entries=try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey]) else { return }
        for url in entries where !keeping.contains(url.lastPathComponent) && (url.lastPathComponent.hasPrefix("source-") || url.lastPathComponent.hasPrefix("taxonomy-")) && url.pathExtension == "json" {
            if (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true { remove(url.lastPathComponent) }
        }
    }
    func remove(_ name: String) {
        if let url = try? file(name) { try? FileManager.default.removeItem(at:url) }
        if name.hasPrefix("preview-") { previewFiles?.removeValue(forKey:name) }
    }
    func clear() throws {
        try validateDirectory()
        if FileManager.default.fileExists(atPath:directory.path) { try FileManager.default.removeItem(at:directory) }
        previewFiles=nil
    }
    func byteCount() throws -> Int64 {
        try validateDirectory()
        return ApplicationStorage.filesSize(directory)
    }
}
