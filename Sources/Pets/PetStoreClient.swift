import Foundation
import AppKit
import ImageIO

protocol PetFetching {
    func data(from url:URL,limit:Int) async throws -> Data
}

struct PetHTTPClient: PetFetching {
    var protocolClasses:[AnyClass]? = nil
    func data(from url:URL,limit:Int) async throws -> Data {
        _ = try PetURL.validate(url)
        let request = PetDataRequest(url:url,limit:limit,protocolClasses:protocolClasses)
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { request.start($0) }
        },onCancel:{ request.cancel() })
    }
}

// Each public request has no cookies, credentials or quota-client headers, and is bounded while receiving bytes.
private final class PetDataRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url:URL;let limit:Int
    let protocolClasses:[AnyClass]?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data,Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var buffer = Data()
    init(url:URL,limit:Int,protocolClasses:[AnyClass]?) { self.url=url;self.limit=limit;self.protocolClasses=protocolClasses }
    func start(_ continuation:CheckedContinuation<Data,Error>) {
        lock.lock()
        if cancelled { lock.unlock();continuation.resume(throwing:CancellationError());return }
        self.continuation=continuation
        let configuration=URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage=nil;configuration.httpShouldSetCookies=false
        configuration.urlCredentialStorage=nil;configuration.urlCache=nil
        if let protocolClasses { configuration.protocolClasses=protocolClasses }
        configuration.timeoutIntervalForRequest=20;configuration.timeoutIntervalForResource=35
        let session=URLSession(configuration:configuration,delegate:self,delegateQueue:nil)
        self.session=session
        var request=URLRequest(url:url);request.setValue("CodexBuddy-Pets",forHTTPHeaderField:"User-Agent")
        let task=session.dataTask(with:request);self.task=task
        lock.unlock();task.resume()
    }
    func cancel() {
        lock.lock();cancelled=true;lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result:Result<Data,Error>) {
        lock.lock()
        let continuation=self.continuation;self.continuation=nil
        let session=self.session;self.session=nil;self.task=nil
        lock.unlock()
        session?.invalidateAndCancel();continuation?.resume(with:result)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?) -> Void) {
        guard let url=request.url, (try? PetURL.validate(url)) != nil else {
            completionHandler(nil);finish(.failure(PetStoreError.invalidURL));return
        }
        completionHandler(request)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition) -> Void) {
        guard let http=response as? HTTPURLResponse, http.statusCode == 200,
              let url=http.url, (try? PetURL.validate(url)) != nil else {
            completionHandler(.cancel);finish(.failure(PetStoreError.unavailable));return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel);finish(.failure(PetStoreError.tooLarge));return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        guard buffer.count+data.count <= limit else { finish(.failure(PetStoreError.tooLarge));return }
        buffer.append(data)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(buffer)) }
    }
}

struct InstalledPet: Identifiable, Equatable {
    var id:String;var manifestID:String?;var name:String;var summary:String;var imageURL:URL;var version:Int
    var sourceID:String? = nil
    var sourceRemoteID:String? = nil
    var manifestChecksum:String? = nil
}

enum PetLocalLibrary {
    static var root:URL {
        let home=ProcessInfo.processInfo.environment["CODEX_HOME"]
        return home.map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex",isDirectory:true)
    }
    static func scan(root:URL) -> [InstalledPet] {
        let fm=FileManager.default
        var result=[InstalledPet]()
        for (folder,filename) in [("pets","pet.json"),("avatars","avatar.json")] {
            let directory=root.appendingPathComponent(folder,isDirectory:true)
            guard !isSymlink(directory), let entries=try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles]) else { continue }
            for entry in entries.prefix(500) {
                guard (try? entry.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true, !isSymlink(entry) else { continue }
                let manifestURL=entry.appendingPathComponent(filename)
                guard !isSymlink(manifestURL), let size=try? manifestURL.resourceValues(forKeys:[.fileSizeKey]).fileSize,
                      size <= 65_536, let data=try? Data(contentsOf:manifestURL),
                      let manifest=try? JSONDecoder().decode(PetManifest.self,from:data), (try? manifest.validate()) != nil else { continue }
                let image=entry.appendingPathComponent(manifest.imagePath)
                guard !isSymlink(image), let imageSize=try? image.resourceValues(forKeys:[.fileSizeKey]).fileSize,
                      imageSize <= 32_000_000, imageSize > 0 else { continue }
                let identity=PetPackageInstaller.recordedIdentity(in:entry)
                result.append(.init(id:folder+"/"+entry.lastPathComponent,manifestID:manifest.id,name:manifest.displayName ?? entry.lastPathComponent,summary:manifest.description ?? "",imageURL:image,version:manifest.version,sourceID:identity?.sourceID,sourceRemoteID:identity?.remoteID,manifestChecksum:PetPackageUninstaller.checksum(data)))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func isSymlink(_ url:URL) -> Bool { (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true }
}

enum PetSprite {
    static func image(_ data:Data,version:Int) throws -> CGImage {
        guard data.count <= 32_000_000, [1,2].contains(version),
              let source=CGImageSourceCreateWithData(data as CFData,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 1536,
              properties[kCGImagePropertyPixelHeight] as? Int == (version == 1 ? 1872 : 2288),
              let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw PetStoreError.invalidImage }
        return image
    }
    static func thumbnail(_ data:Data,sprite:Bool = false) throws -> NSImage {
        let image=try thumbnailImage(data,sprite:sprite)
        return NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
    }
    static func thumbnailImage(_ data:Data,sprite:Bool = false) throws -> CGImage {
        if sprite {
            guard data.count <= 32_000_000,let source=CGImageSourceCreateWithData(data as CFData,nil),
                  let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let height=properties[kCGImagePropertyPixelHeight] as? Int,
                  [1872,2288].contains(height),
                  let frame=try image(data,version:height == 2288 ? 2 : 1).cropping(to:CGRect(x:0,y:0,width:192,height:208)) else { throw PetStoreError.invalidImage }
            // A crop may retain the whole atlas. Copy its pixels before caching a tiny thumbnail.
            guard let context=CGContext(data:nil,width:192,height:208,bitsPerComponent:8,bytesPerRow:192*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PetStoreError.invalidImage }
            context.interpolationQuality = .none
            context.draw(frame,in:CGRect(x:0,y:0,width:192,height:208))
            guard let thumbnail=context.makeImage() else { throw PetStoreError.invalidImage }
            return thumbnail
        }
        guard data.count <= 6_000_000, let source=CGImageSourceCreateWithData(data as CFData,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int, let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:240] as CFDictionary) else { throw PetStoreError.invalidImage }
        return image
    }
}
