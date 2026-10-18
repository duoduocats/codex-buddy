import AppKit

// Session-only public preview resources. No pet package is persisted by browsing.
// Exact catalog metadata and a short lifetime prevent a shared URL or renamed pet
// from borrowing another source's prepared installation payload.
struct PetPreviewMemoryCache {
    struct Detail {
        let theme:PetTheme
        let generation:Int
        let image:CGImage
        let link:URL
        let package:PetPackageInstaller.Package
        let expires:Date
        var cost:Int { package.spriteData.count + image.bytesPerRow*image.height }
    }
    private var details=[Detail]()
    private struct Sprite {
        let url:URL
        let theme:PetTheme
        let generation:Int
        let data:Data
        let expires:Date
    }
    private var sprites=[Sprite]()
    var retainedByteCount:Int { details.reduce(0,{$0+$1.cost})+sprites.reduce(0,{$0+$1.data.count}) }
    static let lifetime:TimeInterval=120
    static let maximumBytes=48_000_000
    mutating func detail(for theme:PetTheme,generation:Int,now:Date = Date()) -> Detail? {
        expire(generation:generation,now:now)
        guard let index=details.firstIndex(where:{$0.theme == theme}) else { return nil }
        let value=details.remove(at:index);details.append(value);return value
    }
    mutating func insert(theme:PetTheme,generation:Int,image:CGImage,link:URL,package:PetPackageInstaller.Package,now:Date = Date()) {
        expire(generation:generation,now:now)
        details.removeAll { $0.theme == theme }
        let entry=Detail(theme:theme,generation:generation,image:image,link:link,package:package,expires:now.addingTimeInterval(Self.lifetime))
        guard entry.cost <= Self.maximumBytes else { return }
        details.append(entry)
        sprites.removeAll { $0.theme == theme }
        trim()
    }
    mutating func rememberSprite(_ data:Data,url:URL,theme:PetTheme,generation:Int,now:Date = Date()) {
        guard data.count <= 20_971_520 else { return }
        expire(generation:generation,now:now)
        sprites.removeAll { $0.url == url && $0.theme == theme }
        sprites.append(.init(url:url,theme:theme,generation:generation,data:data,expires:now.addingTimeInterval(Self.lifetime)))
        trim()
    }
    mutating func spriteData(url:URL,theme:PetTheme,generation:Int,now:Date = Date()) -> Data? {
        expire(generation:generation,now:now)
        guard let index=sprites.firstIndex(where:{$0.url == url && $0.theme == theme}) else { return nil }
        let value=sprites.remove(at:index);sprites.append(value);return value.data
    }
    mutating func clear() { details=[];sprites=[] }
    private mutating func expire(generation:Int,now:Date) {
        details.removeAll { $0.expires <= now || $0.generation != generation }
        sprites.removeAll { $0.expires <= now || $0.generation != generation }
    }
    private mutating func trim() {
        // Byte pressure takes priority over entry counts. Scrolling new cards
        // sheds old transient atlases before evicting a ready detail preview.
        while retainedByteCount > Self.maximumBytes {
            if !sprites.isEmpty { sprites.removeFirst() }
            else if !details.isEmpty { details.removeFirst() }
            else { break }
        }
        while sprites.count > 8 { sprites.removeFirst() }
        while details.count > 2 { details.removeFirst() }
    }
}
