import Foundation
import AppKit
import ImageIO

final class PetTestPreferences:UserDefaults {
    var values=[String:Any]()
    override func object(forKey key:String) -> Any? { values[key] }
    override func set(_ value:Any?,forKey key:String) { values[key]=value }
}

final class PetFixture:URLProtocol {
    static let lock=NSLock()
    static var bodies=[String:Data]()
    static var requests=[URLRequest]()
    static var cancelled=0
    static var delay=0.0
    private var stopped=false
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock();Self.requests.append(request)
        let data=Self.bodies[request.url!.absoluteString];let delay=Self.delay
        Self.lock.unlock()
        let deliver={ [self] in
            guard !stopped else { return }
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:data == nil ? 503 : 200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            if let data { client?.urlProtocol(self,didLoad:data) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay == 0 { deliver() } else { DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:deliver) }
    }
    override func stopLoading() { Self.lock.lock();stopped=true;Self.cancelled += 1;Self.lock.unlock() }
    static func reset(_ bodies:[String:Data] = [:],delay:Double = 0) {
        lock.lock();Self.bodies=bodies;requests=[];cancelled=0;Self.delay=delay;lock.unlock()
    }
}

@main struct PetStoreTests {
    static let feed=Data(#"{"schemaVersion":1,"name":"Synthetic Pets","websiteURL":"https://example.com/pets","pets":[{"id":"synthetic-cat","name":"Synthetic Cat","description":"A test-only cat","author":"Test Author","license":"CC0","manifestURL":"https://example.com/pets/cat/pet.json","previewURL":"https://example.com/pets/cat/idle.png","websiteURL":"https://example.com/pets/cat"}]}"#.utf8)
    static let manifest=Data(#"{"id":"synthetic-cat","displayName":"Cat & friend 猫","description":"Synthetic only","spritesheetPath":"spritesheet.png","spriteVersionNumber":2}"#.utf8)
    static func rejected(_ body:() throws -> Void) {
        do { try body();preconditionFailure("Expected rejection") } catch {}
    }
    static func sprite(version:Int,width:Int = 1536) -> Data {
        let height=version == 1 ? 1872 : 2288
        let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.2,green:0.5,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
        let data=NSMutableData();let destination=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil);precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--pet-package-lock-probe") {
            try PetPackageInstallerTests.run(root:URL(fileURLWithPath:"/private/tmp"),sprite:Data());return
        }
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("standalone-pet-tests-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        let source=try PetSource.custom(url:URL(string:"https://example.com/catalog.json")!)
        let decoded=try PetCatalog.decode(feed,source:source)
        precondition(decoded.name == "Synthetic Pets" && decoded.pets.count == 1)
        for url in ["http://example.com/pets.json","file:///tmp/pets.json","https://localhost/pets.json","https://127.0.0.1/pets.json","https://10.1.2.3/pets.json","https://169.254.169.254/latest","https://172.16.1.1/pets.json","https://192.168.1.1/pets.json","https://example.local/pets.json","https://user:pass@example.com/pets.json","https://example.com:8080/pets.json","https://example.com/pets.json?access_token=synthetic"] {
            rejected { _=try PetURL.parse(url) }
        }
        for replacement in [("\"schemaVersion\":1","\"schemaVersion\":2"),("\"id\":\"synthetic-cat\"","\"id\":\"../escape\""),("https://example.com/pets/cat/pet.json","file:///tmp/pet.json"),("\"license\":\"CC0\"","\"license\":\"\"")] {
            rejected { _=try PetCatalog.decode(Data(String(decoding:feed,as:UTF8.self).replacingOccurrences(of:replacement.0,with:replacement.1).utf8),source:source) }
        }
        rejected { _=try PetCatalog.decode(Data(repeating:32,count:2_000_001),source:source) }
        let hua=Data(#"{"pets":[{"id":"synthetic-dragon","name":"Dragon","description":"Fixture","category":"mascots","author":{"name":"Tester"},"url":"https://example.com/theme"}]}"#.utf8)
        let dragon=try PetCatalog.decode(hua,source:PetSource.defaults.first(where:{$0.id == "huaqing"})!).pets[0]
        precondition(dragon.manifestURL.absoluteString == "https://raw.githubusercontent.com/HuaqingAI/awesome-codex-pets/main/pets/synthetic-dragon/pet.json")
        let cute=Data(#"[{"slug":"synthetic-cat","name":"Cat","author":"Tester","license":"CC BY-NC 4.0","description":"Fixture","primary_category":"Animals"}]"#.utf8)
        let cat=try PetCatalog.decode(cute,source:PetSource.defaults.first(where:{$0.id == "cutechen"})!).pets[0]
        precondition(cat.previewURL!.absoluteString.hasSuffix("assets/previews/synthetic-cat/gifs/idle.gif"))
        let missingDescription=Data(String(decoding:cute,as:UTF8.self).replacingOccurrences(of:"\"description\":\"Fixture\",",with:"").utf8)
        precondition(try! PetCatalog.decode(missingDescription,source:PetSource.defaults.first(where:{$0.id == "cutechen"})!).pets[0].summary.isEmpty)
        precondition(cat.id != decoded.pets[0].id,"Catalogs must retain their source identities")

        precondition(PetSource.defaults.count == 12 && !PetSource.defaults.contains(where:{$0.id == "duoduocat"}))
        let gallerySource=PetSource.defaults.first(where:{$0.id == "legeling"})!
        let gallery=Data(#"[{"slug":"fixture-high--tester","name":"High","localized_names":{"zh":"测试高热度","en":"High"},"author":"Synthetic Author","license":"CC0","primary_category":"Animals"},{"slug":"fixture-zero--tester","name":"Zero","author":"Synthetic Author","license":"CC0","primary_category":"Animals"},{"slug":"fixture-unknown--tester","name":"Unknown","author":"Synthetic Author","license":"CC0","primary_category":"Animals"}]"#.utf8)
        let galleryPets=try PetCatalog.decode(gallery,source:gallerySource).pets
        precondition(galleryPets.count == 3 && galleryPets[0].previewIsSprite && galleryPets[0].summary.isEmpty)
        precondition(galleryPets[0].name == (AppLanguage.chinese ? "测试高热度" : "High"))
        let longLicense=String(repeating:"a",count:500)
        let detailedLicense=Data(String(decoding:gallery,as:UTF8.self).replacingOccurrences(of:"\"license\":\"CC0\"",with:"\"license\":\"\(longLicense)\"").utf8)
        precondition(try! PetCatalog.decode(detailedLicense,source:gallerySource).pets[0].license == longLicense,"Long source license notices must be retained verbatim")
        let senyoSource=PetSource.defaults.first(where:{$0.id == "senyo"})!
        let senyo=Data(#"{"schemaVersion":2,"pets":[{"id":"synthetic-guardian","displayName":"Guardian","description":"Synthetic","publicationState":"published","previewPath":"pets/synthetic-guardian/preview.gif","installPage":"https://example.com/install"},{"id":"synthetic-draft","displayName":"Draft","description":"Synthetic","publicationState":"draft","previewPath":"pets/synthetic-draft/preview.gif","installPage":"https://example.com/install"}]}"#.utf8)
        let senyoPets=try PetCatalog.decode(senyo,source:senyoSource).pets
        precondition(senyoPets.count == 1 && senyoPets[0].license == "CC BY 4.0" && senyoPets[0].manifestURL.absoluteString.hasSuffix("pets/synthetic-guardian/pet.json"))
        rejected { _=try PetCatalog.decode(Data(String(decoding:senyo,as:UTF8.self).replacingOccurrences(of:"pets/synthetic-guardian/preview.gif",with:"../../private.gif").utf8),source:senyoSource) }
        let generated=Int(Date().timeIntervalSince1970*1000)-1000
        let statistics=Data("{\"generatedAt\":\(generated),\"windowDays\":7,\"pets\":{\"fixture-high--tester\":{\"installs\":25,\"likes\":3,\"installs7d\":5},\"fixture-zero--tester\":{\"installs\":0,\"likes\":0}}}".utf8)
        let stats=try PetPopularitySnapshot.decode(statistics)
        precondition(stats.pets["fixture-high--tester"]?.likes == 3 && stats.pets["fixture-high--tester"]?.likes7d == nil && stats.pets["fixture-unknown--tester"] == nil)
        for replacement in [("\"installs\":25","\"installs\":-1"),("\"windowDays\":7","\"windowDays\":30"),("fixture-high--tester","../escape")] {
            rejected { _=try PetPopularitySnapshot.decode(Data(String(decoding:statistics,as:UTF8.self).replacingOccurrences(of:replacement.0,with:replacement.1).utf8)) }
        }
        let pixelFrame=try PetSprite.thumbnailImage(sprite(version:2),sprite:true)
        precondition(pixelFrame.width == 192 && pixelFrame.height == 208,"Atlas thumbnails must show one pet, not the entire sheet")

        let meta=try JSONDecoder().decode(PetManifest.self,from:manifest)
        let imageURL=try meta.imageURL(relativeTo:decoded.pets[0].manifestURL)
        let link=try meta.installURL(imageURL:imageURL,fallbackName:"Cat")
        let components=URLComponents(url:link,resolvingAgainstBaseURL:false)!
        precondition(components.scheme == "codex" && components.host == "pets" && components.path == "/install")
        let params=Dictionary(uniqueKeysWithValues:components.queryItems!.map { ($0.name,$0.value!) })
        precondition(params["name"] == "Cat & friend 猫" && params["imageUrl"] == imageURL.absoluteString && params["spriteVersionNumber"] == "2")
        precondition(Set(params.keys) == Set(["name","imageUrl","description","spriteVersionNumber"]))
        var plusManifest=meta;plusManifest.displayName="C++ Cat";plusManifest.description="A+B & 猫"
        let plusURL=URL(string:"https://example.com/sprite+name.png")!
        let plusLink=try plusManifest.installURL(imageURL:plusURL,fallbackName:"Cat")
        let encodedQuery=URLComponents(url:plusLink,resolvingAgainstBaseURL:false)!.percentEncodedQuery!
        precondition(!encodedQuery.contains("+") && encodedQuery.contains("%2B"),"Literal plus signs must be escaped for URLSearchParams")
        let receiverValues=Dictionary(uniqueKeysWithValues:encodedQuery.split(separator:"&").map { part -> (String,String) in
            let pair=part.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            return (String(pair[0]),String(pair[1]).replacingOccurrences(of:"+",with:" ").removingPercentEncoding!)
        })
        precondition(receiverValues["name"] == "C++ Cat" && receiverValues["description"] == "A+B & 猫" && receiverValues["imageUrl"] == plusURL.absoluteString)
        var blank=meta;blank.displayName="  "
        rejected { _=try blank.installURL(imageURL:imageURL,fallbackName:"  ") }
        for path in ["../spritesheet.png","/spritesheet.png","https://example.com/s.png","a/b.png","pet.json","auth.json"] {
            var bad=meta;bad.spritesheetPath=path;rejected { try bad.validate() }
        }
        var bad=meta;bad.spriteVersionNumber=3;rejected { try bad.validate() }
        let v1=sprite(version:1);let v2=sprite(version:2)
        try await PetCommunityCatalogTests.run(root:temp,sprite:v2)
        try PetFavoritesTests.run()
        let installerTestRoot=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("codex-pets-installer-tests-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:installerTestRoot,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:installerTestRoot) }
        try PetPackageInstallerTests.run(root:installerTestRoot,sprite:v2)
        try PetPackageUninstallerTests.run(root:installerTestRoot,sprite:v2)
        PetPreviewTests.run()
        _=try PetSprite.image(v1,version:1);_=try PetSprite.image(v2,version:2)
        rejected { _=try PetSprite.image(v1,version:2) }
        rejected { _=try PetSprite.image(sprite(version:1,width:512),version:1) }
        rejected { _=try PetSprite.image(Data("not an image".utf8),version:1) }
        _=try PetSprite.thumbnail(v1)

        let root=installerTestRoot.appendingPathComponent("synthetic-home",isDirectory:true)
        let petDir=root.appendingPathComponent("pets/synthetic-cat",isDirectory:true)
        try FileManager.default.createDirectory(at:petDir,withIntermediateDirectories:true)
        try manifest.write(to:petDir.appendingPathComponent("pet.json"));try v2.write(to:petDir.appendingPathComponent("spritesheet.png"))
        let escape=root.appendingPathComponent("pets/escape",isDirectory:true)
        try FileManager.default.createDirectory(at:escape,withIntermediateDirectories:true)
        try manifest.write(to:escape.appendingPathComponent("pet.json"))
        try FileManager.default.createSymbolicLink(at:escape.appendingPathComponent("spritesheet.png"),withDestinationURL:petDir.appendingPathComponent("spritesheet.png"))
        let local=PetLocalLibrary.scan(root:root)
        precondition(local.count == 1 && local[0].manifestID == "synthetic-cat")
        let originalMetadata=try Data(contentsOf:petDir.appendingPathComponent("pet.json"))
        precondition(originalMetadata == manifest,"Scanning must preserve original metadata")
        let client=PetHTTPClient(protocolClasses:[PetFixture.self])
        PetFixture.reset(["https://example.com/test":Data(repeating:0,count:100)])
        _=try await client.data(from:URL(string:"https://example.com/test")!,limit:100)
        precondition(PetFixture.requests[0].value(forHTTPHeaderField:"Authorization") == nil && PetFixture.requests[0].value(forHTTPHeaderField:"Cookie") == nil)
        do { _=try await client.data(from:URL(string:"https://example.com/test")!,limit:50);preconditionFailure("Oversized response must fail") } catch {}
        do { _=try await client.data(from:URL(string:"https://example.com/missing")!,limit:100);preconditionFailure("HTTP failure must fail") } catch {}
        PetFixture.reset(["https://example.com/test":Data([1])],delay:0.5)
        let pending=Task { try await client.data(from:URL(string:"https://example.com/test")!,limit:100) }
        for _ in 0..<100 where PetFixture.requests.isEmpty { try await Task.sleep(nanoseconds:5_000_000) }
        precondition(!PetFixture.requests.isEmpty);pending.cancel()
        do { _=try await pending.value;preconditionFailure("Cancellation must fail") } catch {}
        for _ in 0..<100 where PetFixture.cancelled == 0 { try await Task.sleep(nanoseconds:5_000_000) }
        precondition(PetFixture.cancelled > 0)

        let fakeApp=URL(fileURLWithPath:"/synthetic/Codex.app")
        var routed=[(URL,URL)]()
        let launcher=PetCodexLauncher(applicationURL:{fakeApp},send:{url,app in routed.append((url,app));return true})
        switch await launcher.open(link) { case .success:break;case .failure:preconditionFailure("Validated link must be routed") }
        precondition(routed.count == 1 && routed[0].0 == link && routed[0].1 == fakeApp,"Install handoff must target the Codex app explicitly")
        switch await launcher.open(URL(string:"https://example.com")!) { case .failure(.invalidLink):break;default:preconditionFailure("Non-Codex link must fail") }
        let missing=PetCodexLauncher(applicationURL:{nil},send:{_,_ in preconditionFailure("No app must not send")})
        switch await missing.open(link) { case .failure(.unavailable):break;default:preconditionFailure("Missing app must report failure") }
        let failed=PetCodexLauncher(applicationURL:{fakeApp},send:{_,_ in false})
        switch await failed.open(link) { case .failure(.failed):break;default:preconditionFailure("OS rejection must report failure") }

        let preferences=PetTestPreferences()
        preferences.set(try JSONEncoder().encode(PetSource.defaults.map { var s=$0;s.enabled=false;return s }+[source]),forKey:"pets.sources")
        var opened=[URL]()
        var copied=[String]()
        let modelTrash=root.appendingPathComponent("synthetic-trash",isDirectory:true)
        try FileManager.default.createDirectory(at:modelTrash,withIntermediateDirectories:false)
        let syntheticTrash:(URL) throws -> URL? = { url in
            let target=modelTrash.appendingPathComponent(UUID().uuidString,isDirectory:true)
            try FileManager.default.moveItem(at:url,to:target);return target
        }
        PetFixture.reset([source.catalogURL.absoluteString:feed,decoded.pets[0].manifestURL.absoluteString:manifest,imageURL.absoluteString:v2])
        let store=ThemeStoreModel(preferences:preferences,client:client,cacheDirectory:temp.appendingPathComponent("cache"),libraryRoot:root,openURL:{opened.append($0);return true},openCodexURL:{opened.append($0);return .success(())},trashItem:syntheticTrash,copyText:{copied.append($0);return true})
        precondition(PetFixture.requests.isEmpty,"Constructing a disabled or closed store must not fetch")
        store.open();try await wait(store)
        precondition(store.themes.count == 1 && store.installed.count == 1 && !store.isInstalled(store.themes[0]))
        store.toggleFavorite(store.themes[0]);precondition(store.favorites.count == 1 && store.isFavorite(store.themes[0]))
        store.select(store.themes[0]);try await wait(store)
        precondition(store.preparedLink != nil && store.sheet?.height == 2288 && opened.isEmpty,"Previewing must not activate or install")
        let package=store.preparedPackage!
        store.requestLocalInstallation();await store.finishInstallationCheck()
        precondition(store.localInstallRequest?.package.remoteID == "synthetic-cat" && store.localInstallRequest?.replacing == false)
        store.cancelLocalInstallation()
        precondition(!FileManager.default.fileExists(atPath:root.appendingPathComponent("pets/"+package.folderID).path),"Cancelling consent must not save a pet")
        store.requestLocalInstallation();await store.finishInstallationCheck()
        store.confirmLocalInstallation();await store.finishCurrentInstallation()
        precondition(store.localInstallDirectory != nil && store.isInstalled(store.themes[0]) && store.installed.count == 2 && opened.isEmpty,"Local install must update its owned-source badge without launching or selecting in Codex")
        var differentOrigin=store.themes[0];differentOrigin.sourceID="other-source"
        precondition(!store.isInstalled(differentOrigin),"Identical slugs from another source must not borrow installed status")
        store.requestLocalInstallation();await store.finishInstallationCheck()
        precondition(store.localInstallRequest == nil,"An unchanged saved package must not silently reinstall")
        store.requestLocalInstallation(reinstall:true);await store.finishInstallationCheck()
        precondition(store.localInstallRequest?.replacing == true,"Saving again must require separate replacement consent")
        store.cancelLocalInstallation()

        store.installSelected();try await wait(store)
        precondition(opened.count == 1 && opened[0].scheme == "codex" && store.notice != nil)
        store.copyInstallLink()
        precondition(copied == [store.preparedLink!.absoluteString] && opened.count == 1,"Copying must not send a second request or modify Codex")
        store.openDefaults();try await wait(store);precondition(opened.last?.absoluteString == "codex://settings")
        let unchangedMetadata=try Data(contentsOf:petDir.appendingPathComponent("pet.json"))
        precondition(unchangedMetadata == manifest,"Installer handoff must never edit Codex state")
        PetFixture.reset();store.refresh();try await wait(store)
        precondition(store.themes.count == 1 && store.cachedSources.contains(source.id) && store.sourceErrors[source.id] != nil,"Offline failures must keep cached themes")
        let requestCount=PetFixture.requests.count;store.close();store.refresh();store.installSelected();store.openDefaults()
        precondition(PetFixture.requests.count == requestCount && store.sheet == nil && opened.count == 2,"Closing must stop requests and clear the animation")
        PetFixture.reset([source.catalogURL.absoluteString:feed],delay:0.5)
        store.open();store.refresh()
        for _ in 0..<100 where PetFixture.requests.isEmpty { try await Task.sleep(nanoseconds:5_000_000) }
        store.close()
        for _ in 0..<100 where PetFixture.cancelled == 0 { try await Task.sleep(nanoseconds:5_000_000) }
        precondition(!store.loading && !store.preparing && PetFixture.cancelled > 0)
        PetFixture.reset([source.catalogURL.absoluteString:feed])
        store.open();try await wait(store);store.setEnabled(store.sources.last!,false);try await wait(store)
        precondition(store.themes.isEmpty && store.sources.last?.enabled == false)
        precondition(store.favorites.count == 1 && store.matchingThemes(query:"Synthetic",favoritesOnly:true).count == 1)
        let noFetch=PetFixture.requests.count
        store.select(store.favoriteThemes[0]);try await wait(store)
        precondition(PetFixture.requests.count == noFetch && store.preparedLink == nil,"Disabled favorites retain metadata but must not fetch a disabled source")
        let recreated=ThemeStoreModel(preferences:preferences,client:client,cacheDirectory:temp.appendingPathComponent("cache"),libraryRoot:root)
        precondition(recreated.sources.last?.enabled == false,"Source preferences must survive restart")
        precondition(recreated.favorites.count == 1,"Local favorites must survive restarting the store")
        store.close()
        PetFixture.reset([source.catalogURL.absoluteString:feed,decoded.pets[0].manifestURL.absoluteString:manifest,imageURL.absoluteString:v2])
        let failedStore=ThemeStoreModel(preferences:preferences,client:client,cacheDirectory:temp.appendingPathComponent("failed-cache"),libraryRoot:root,
            openCodexURL:{_ in .failure(.failed)},copyText:{_ in false})
        // Re-enable the synthetic source changed by the preference test above.
        failedStore.open();failedStore.setEnabled(failedStore.sources.last!,true);try await wait(failedStore)
        failedStore.select(failedStore.themes[0]);try await wait(failedStore);failedStore.installSelected();try await wait(failedStore)
        precondition(failedStore.notice == PetLaunchError.failed.localizedDescription && failedStore.installationHandoff && !failedStore.handingOff)
        failedStore.copyInstallLink();precondition(failedStore.notice?.contains(AppLanguage.chinese ? "无法复制" : "Could not copy") == true)
        failedStore.close()
        let slowStore=ThemeStoreModel(preferences:preferences,client:client,cacheDirectory:temp.appendingPathComponent("slow-cache"),libraryRoot:root,
            openCodexURL:{_ in try? await Task.sleep(nanoseconds:100_000_000);return .success(())})
        slowStore.open();try await wait(slowStore);slowStore.select(slowStore.themes[0]);try await wait(slowStore)
        slowStore.installSelected();precondition(slowStore.handingOff);slowStore.close()
        try await Task.sleep(nanoseconds:150_000_000)
        precondition(!slowStore.handingOff && slowStore.notice == nil,"Closing must discard a delayed handoff result")

        PetFixture.reset()
        let removalStore=ThemeStoreModel(preferences:preferences,client:client,cacheDirectory:temp.appendingPathComponent("remove-cache"),libraryRoot:root,trashItem:syntheticTrash)
        removalStore.open();try await wait(removalStore)
        let ownPet=removalStore.installed.first(where:{$0.sourceID == source.id})!
        removalStore.requestUninstall(ownPet);await removalStore.finishInstallationCheck()
        precondition(removalStore.uninstallRequest?.pet.id == ownPet.id)
        removalStore.cancelUninstall()
        precondition(FileManager.default.fileExists(atPath:ownPet.imageURL.path),"Cancelling uninstall must retain the theme")
        removalStore.requestUninstall(ownPet);await removalStore.finishInstallationCheck()
        removalStore.confirmUninstall();await removalStore.finishCurrentInstallation()
        precondition(!removalStore.installed.contains(where:{$0.id == ownPet.id}) && removalStore.trashedDirectory != nil)
        precondition(removalStore.favorites.count == 1,"Uninstalling a package must preserve local bookmarks")
        removalStore.close()

        let metricPreferences=PetTestPreferences()
        metricPreferences.set(try JSONEncoder().encode(PetSource.defaults.map { var item=$0;item.enabled=item.id == "legeling";return item }),forKey:"pets.sources")
        let statsURL=gallerySource.statisticsURL!
        PetFixture.reset([gallerySource.catalogURL.absoluteString:gallery,statsURL.absoluteString:statistics])
        let metricStore=ThemeStoreModel(preferences:metricPreferences,client:client,cacheDirectory:temp.appendingPathComponent("metric-cache"),libraryRoot:root)
        metricStore.open();try await wait(metricStore)
        precondition(metricStore.popularThemes.count == 2 && metricStore.popularThemes.first?.remoteID == "fixture-high--tester")
        precondition(metricStore.statistics(for:galleryPets[2]) == nil,"Missing source statistics must stay unknown, not become zero")
        precondition(metricStore.matchingThemes(query:"Synthetic Author",byInstalls:true).last?.remoteID == "fixture-unknown--tester")
        precondition(metricStore.matchingThemes(query:"",sourceID:"senyo").isEmpty)
        precondition(PetFixture.requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField:"Authorization") == nil && $0.value(forHTTPHeaderField:"Cookie") == nil },"Reading heat must not send telemetry, likes, or credentials")
        PetFixture.reset();metricStore.refresh();try await wait(metricStore)
        precondition(metricStore.statisticsCached && metricStore.statisticsUnavailable && metricStore.statisticsDate == stats.generatedAt && metricStore.popularThemes.count == 2,"Offline statistics retain the original snapshot date")
        PetFixture.reset([gallerySource.catalogURL.absoluteString:gallery],delay:0.5)
        metricStore.refresh()
        try await Task.sleep(nanoseconds:20_000_000);metricStore.close()
        try await Task.sleep(nanoseconds:50_000_000)
        precondition(!metricStore.loading && !metricStore.visible)
        PetFixture.reset();metricStore.open();try await wait(metricStore)
        metricStore.setEnabled(gallerySource,false);try await wait(metricStore)
        precondition(metricStore.themes.isEmpty && metricStore.popularity.isEmpty && metricStore.statisticsDate == nil)
        metricStore.close()
        try await PetIntegrationTests.run(root:installerTestRoot,sprite:v2)
        print("Pet store passed: twelve community sources, public popularity snapshots and fallback, sprite thumbnails, custom catalogs, URL and manifest validation, v1/v2 images, read-only local library, bounded credential-free requests, official install links, caching, source preferences and cancellation")
    }
    @MainActor static func wait(_ store:ThemeStoreModel) async throws {
        for _ in 0..<300 {
            if !store.loading && !store.preparing && !store.handingOff && !store.checkingLocalInstall && !store.modifyingLocalLibrary { try await Task.sleep(nanoseconds:20_000_000);return }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        preconditionFailure("Store requests did not finish")
    }
}
