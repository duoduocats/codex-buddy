import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

struct PetLocalInstallRequest:Identifiable {
    let id=UUID()
    let package:PetPackageInstaller.Package
    let destination:URL
    let sourceName:String
    let replacing:Bool
    var displayPath:String { (destination.path as NSString).abbreviatingWithTildeInPath }
}

struct PetUninstallRequest:Identifiable {
    let id=UUID()
    let pet:InstalledPet
    let root:URL
}

@MainActor final class ThemeStoreModel: ObservableObject {
    @Published private(set) var sources:[PetSource] { didSet { sourceNames = Dictionary(uniqueKeysWithValues:sources.map { ($0.id,$0.name) }) } }
    @Published private(set) var themes=[PetTheme]()
    @Published private(set) var installed=[InstalledPet]() { didSet { installedIDs = Set(installed.compactMap { pet in pet.sourceID.flatMap { source in pet.sourceRemoteID.map { source+":"+$0 } } }) } }
    @Published private(set) var favorites:[PetFavorite] { didSet { favoriteIDs = Set(favorites.map(\.id));searchRevision += 1 } }
    private let favoriteRepository:PetFavoritesRepository
    @Published private(set) var loading=false
    @Published private(set) var sourceErrors=[String:String]()
    @Published private(set) var cachedSources=Set<String>()
    @Published private(set) var popularity=[String:PetPopularity]() { didSet { searchRevision += 1 } }
    @Published private(set) var searchRevision = 0
    private var sourceNames = [String:String]()
    private var favoriteIDs = Set<String>(), installedIDs = Set<String>()
    private let searchEngine = PetSearchEngine()
    private var clearingCache = false
    private var installedScan: Task<Void,Never>?
    private var installedScanGeneration = 0
    private var installedRefreshed = Date.distantPast
    @Published private(set) var statisticsDate:Date?
    @Published private(set) var statisticsCached=false
    @Published private(set) var statisticsUnavailable=false
    @Published var selectedTagIDs=Set<String>()
    @Published var selected:PetTheme?
    @Published private(set) var sheet:CGImage?
    @Published private(set) var selectedThumbnail:NSImage?
    @Published private(set) var preparedLink:URL?
    @Published private(set) var preparedPackage:PetPackageInstaller.Package?
    @Published private(set) var preparing=false
    @Published private(set) var handingOff=false
    @Published private(set) var installationHandoff=false
    @Published private(set) var detailError:String?
    @Published var localInstallRequest:PetLocalInstallRequest?
    @Published private(set) var checkingLocalInstall=false
    @Published private(set) var installingLocally=false
    @Published private(set) var uninstallingLocally=false
    @Published var uninstallRequest:PetUninstallRequest?
    @Published private(set) var trashedDirectory:URL?
    @Published private(set) var deletingCloudPet=false
    var modifyingLocalLibrary:Bool { installingLocally || uninstallingLocally || deletingCloudPet }
    @Published private(set) var localInstallDirectory:URL?
    @Published private(set) var recoveryDirectory:URL?
    @Published var notice:String?
    @Published private(set) var visible=false
    let tagStore:PetTagStore?
    let cloudLibrary:PetCloudLibrary?
    private var installedPageVisible=false
    private var tagSubscription:AnyCancellable?
    private var tagStateSubscription:AnyCancellable?
    private var tagCoverageCache=[String:PetTagCoverage]()
    private var cloudTransactionSubscription:AnyCancellable?
    let client:PetFetching
    private let preferences:UserDefaults
    private let cache: PetCatalogCache
    private let libraryRoot:URL
    private let openURL:(URL) -> Bool
    private let openCodexURL:(URL) async -> Result<Void,PetLaunchError>
    private let copyText:(String) -> Bool
    private let trashItem:(URL) throws -> URL?
    private var localCheckTask:Task<Void,Never>?
    private var localInstallTask:Task<Void,Never>?
    private var localUninstallTask:Task<Void,Never>?
    private var localCheckGeneration=0
    private var handoffTask:Task<Void,Never>?
    private var handoffGeneration=0
    private var catalogs=[String:[PetTheme]]()
    private let thumbnailLoader:PetThumbnailLoader
    private var previewCache=PetPreviewMemoryCache()
    private var catalogTask:Task<Void,Never>?
    private var detailTask:Task<Void,Never>?
    private var catalogGeneration=0
    private var detailGeneration=0
    private var refreshed=Date.distantPast
    private var demonstration=false
    init(preferences:UserDefaults = .standard,client:PetFetching = PetHTTPClient(),cacheDirectory:URL? = nil,tags:PetTagStore? = nil,cloud:PetCloudLibrary? = nil,
         libraryRoot:URL = PetLocalLibrary.root,openURL:@escaping(URL) -> Bool = { NSWorkspace.shared.open($0) },
         openCodexURL:@escaping(URL) async -> Result<Void,PetLaunchError> = { await PetCodexLauncher().open($0) },
         trashItem:@escaping(URL) throws -> URL? = PetPackageUninstaller().trash,
         copyText:@escaping(String) -> Bool = { text in
             NSPasteboard.general.clearContents();return NSPasteboard.general.setString(text,forType:.string)
         }) {
        self.preferences=preferences;self.client=client;self.libraryRoot=libraryRoot;self.openURL=openURL;self.tagStore=tags;self.cloudLibrary=cloud
        favoriteRepository=PetFavoritesRepository(preferences:preferences)
        let savedFavorites=favoriteRepository.read();favorites=savedFavorites;favoriteIDs=Set(savedFavorites.map(\.id))
        self.openCodexURL=openCodexURL;self.copyText=copyText;self.trashItem=trashItem
        let thumbnailCache=cacheDirectory.map { PetCatalogCache(directory:$0) } ?? .shared
        cache=thumbnailCache;thumbnailLoader=PetThumbnailLoader(client:client,cache:thumbnailCache)
        let saved=(preferences.object(forKey:"pets.sources") as? Data).flatMap { try? JSONDecoder().decode([PetSource].self,from:$0) } ?? []
        var sources=PetSource.defaults
        for index in sources.indices {
            if let setting=saved.first(where:{$0.id == sources[index].id}) { sources[index].enabled=setting.enabled }
        }
        sources += saved.filter { !$0.builtIn && $0.format == .catalog && $0.id == "custom-"+PetURL.key($0.catalogURL.absoluteString) && (try? PetURL.validate($0.catalogURL)) != nil && (try? PetURL.validate($0.websiteURL)) != nil }.prefix(8)
        self.sources=sources;sourceNames=Dictionary(uniqueKeysWithValues:sources.map { ($0.id,$0.name) })
        cloudTransactionSubscription=cloud?.$deletingPetID.map {$0 != nil}.removeDuplicates().sink { [weak self] in self?.deletingCloudPet=$0 }
        // Forward loading/error changes too: the filter menu must not present
        // an unavailable metadata feed as a completed search with no matches.
        tagStateSubscription=tags?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        tagSubscription=tags?.$revision.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selectedTagIDs.formIntersection(Set(tags?.facets.flatMap(\.tags).map(\.id) ?? []));self.searchRevision += 1
            }
        }
    }
    func open() {
        guard !visible else { return }
        visible=true
        if demonstration || clearingCache { return }
        if installedPageVisible { cloudLibrary?.setVisible(true) }
        tagStore?.setVisible(true,sources:Set(sources.filter(\.enabled).map(\.id)))
        if Date().timeIntervalSince(refreshed) > 900 || themes.isEmpty { refresh() }
        if Date().timeIntervalSince(installedRefreshed) > 30 { refreshInstalled() }
    }
    func close() {
        cloudLibrary?.setVisible(false)
        localCheckGeneration += 1;localCheckTask?.cancel();localCheckTask=nil;checkingLocalInstall=false;localInstallRequest=nil;uninstallRequest=nil
        installedScanGeneration += 1;installedScan?.cancel();installedScan=nil
        tagStore?.setVisible(false)
        visible=false;catalogGeneration += 1;detailGeneration += 1;handoffGeneration += 1
        thumbnailLoader.cancelAll()
        handoffTask?.cancel();handoffTask=nil;handingOff=false;installationHandoff=false
        catalogTask?.cancel();catalogTask=nil;detailTask?.cancel();detailTask=nil
        loading=false;preparing=false;sheet=nil;selectedThumbnail=nil;preparedLink=nil;preparedPackage=nil;selected=nil;notice=nil
        previewCache.clear()
    }
    func setInstalledPageVisible(_ value:Bool) {
        installedPageVisible=value;guard visible,!demonstration else { return }
        cloudLibrary?.setVisible(value);if value { refreshInstalled() }
    }
    func mainWindowBecameKey() {
        guard visible,installedPageVisible,!demonstration else { return }
        if Date().timeIntervalSince(installedRefreshed) > 2 { refreshInstalled() };cloudLibrary?.refresh()
    }
    func refreshLibrary() { refreshInstalled();if installedPageVisible { cloudLibrary?.refresh(force:true) } }
    func refreshInstalled() {
        guard visible, !demonstration, installedScan == nil else { return }
        let root=libraryRoot
        installedScanGeneration += 1;let ticket=installedScanGeneration
        installedScan=Task {
            defer { if ticket == installedScanGeneration { installedScan=nil } }
            let pets=await Task.detached(priority:.utility) { PetLocalLibrary.scan(root:root) }.value
            guard !Task.isCancelled,visible,ticket == installedScanGeneration else { return }
            if installed != pets { installed=pets }
            installedRefreshed=Date()
        }
    }
    func refresh() {
        guard visible, !demonstration, !clearingCache else { return }
        catalogTask?.cancel();catalogGeneration += 1;thumbnailLoader.cancelAll()
        if !modifyingLocalLibrary,selected != nil,preparing || checkingLocalInstall || localInstallRequest != nil || handingOff { invalidatePreviewForCatalogRefresh() }
        let generation=catalogGeneration;let enabled=sources.filter(\.enabled);let client=client;let cache=cache
        loading=true;sourceErrors=[:];cachedSources=Set(enabled.compactMap { catalogs[$0.id] == nil ? nil : $0.id })
        catalogTask=Task {
            defer { if generation == catalogGeneration { loading=false;catalogTask=nil } }
            // Cache reads and validation happen away from the UI actor.
            for source in enabled where catalogs[source.id] == nil {
                let name=PetURL.key(source.catalogURL.absoluteString)+".json"
                if let data=await cache.read(name,limit:source.maximumCatalogBytes),
                   let feed=try? await Task.detached(priority:.utility,operation:{try PetCatalog.decode(data,source:source)}).value {
                    guard visible,generation == catalogGeneration,!Task.isCancelled else { return }
                    catalogs[source.id]=feed.pets;cachedSources.insert(source.id)
                }
            }
            rebuildThemes()
            await withTaskGroup(of:(PetSource,Data?,String?).self) { group in
                for source in enabled {
                    group.addTask {
                        do { return (source,try await client.data(from:source.catalogURL,limit:source.maximumCatalogBytes,kind:.catalog),nil) }
                        catch { return (source,nil,L("暂时无法更新", "Could not update")) }
                    }
                }
                for await (source,data,error) in group {
                    guard visible, generation == catalogGeneration, !Task.isCancelled else { group.cancelAll();return }
                    if let data {
                        do {
                            let feed=try await Task.detached(priority:.utility) { try PetCatalog.decode(data,source:source) }.value
                            guard visible,generation == catalogGeneration,!Task.isCancelled else { return }
                            catalogs[source.id]=feed.pets;cachedSources.remove(source.id)
                            if let index=sources.firstIndex(where:{$0.id == source.id}), !source.builtIn {
                                sources[index].name=feed.name;sources[index].websiteURL=feed.websiteURL
                            }
                            try? await cache.write(data,name:PetURL.key(source.catalogURL.absoluteString)+".json")
                        } catch { sourceErrors[source.id]=L("目录格式不受支持", "Unsupported catalog") }
                    } else { sourceErrors[source.id]=error }
                    rebuildThemes()
                }
            }
            guard visible, generation == catalogGeneration, !Task.isCancelled else { return }
            await refreshStatistics(enabled:enabled,generation:generation)
            guard visible, generation == catalogGeneration, !Task.isCancelled else { return }
            refreshed=Date();persistSources();refreshInstalled()
        }
    }
    private func refreshStatistics(enabled:[PetSource],generation:Int) async {
        statisticsUnavailable=false
        guard let source=enabled.first(where:{$0.statisticsURL != nil}),let url=source.statisticsURL else {
            popularity=[:];statisticsDate=nil;statisticsCached=false;return
        }
        let name="statistics-"+PetURL.key(url.absoluteString)+".json"
        func apply(_ snapshot:PetPopularitySnapshot,cached:Bool) {
            popularity=Dictionary(uniqueKeysWithValues:snapshot.pets.map { (source.id+":"+$0.key,$0.value) })
            statisticsDate=snapshot.generatedAt;statisticsCached=cached
        }
        if let data=await cache.read(name,limit:2_000_000),
           let snapshot=try? await Task.detached(priority:.utility,operation:{try PetPopularitySnapshot.decode(data)}).value {
            guard visible,generation == catalogGeneration,!Task.isCancelled else { return }
            apply(snapshot,cached:true)
        }
        do {
            let data=try await client.data(from:url,limit:2_000_000,kind:.catalog)
            try Task.checkCancellation()
            guard visible,generation == catalogGeneration else { return }
            let snapshot=try await Task.detached(priority:.utility) { try PetPopularitySnapshot.decode(data) }.value
            guard visible,generation == catalogGeneration,!Task.isCancelled else { return }
            apply(snapshot,cached:false)
            try? await cache.write(data,name:name)
        } catch {
            guard visible,generation == catalogGeneration,!Task.isCancelled else { return }
            statisticsUnavailable=true;statisticsCached = statisticsDate != nil
        }
    }
    func statistics(for theme:PetTheme) -> PetPopularity? { popularity[theme.id] }
    var favoriteThemes:[PetTheme] { favorites.sorted { $0.savedAt > $1.savedAt }.map(\.theme) }
    func isFavorite(_ theme:PetTheme) -> Bool { favoriteIDs.contains(theme.id) }
    func toggleFavorite(_ theme:PetTheme) {
        var next=favorites
        if let index=next.firstIndex(where:{$0.id == theme.id}) { next.remove(at:index) }
        else { next.append(.init(theme:theme,savedAt:Date())) }
        guard favoriteRepository.save(next) else {
            notice=L("无法保存收藏，请稍后重试。", "Could not save this favorite. Try again later.");return
        }
        favorites=next
    }
    func canFetch(_ theme:PetTheme) -> Bool { sources.contains { $0.id == theme.sourceID && $0.enabled } }
    func matchingThemes(query:String,sourceID:String = "",byInstalls:Bool = false,favoritesOnly:Bool = false) -> [PetTheme] {
        (favoritesOnly ? favoriteThemes : themes).filter { theme in
            (sourceID.isEmpty || theme.sourceID == sourceID) && (query.isEmpty ||
                [theme.name,theme.author,theme.summary,theme.category,sourceName(theme.sourceID)].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { a,b in
            if byInstalls {
                let x=statistics(for:a)?.installs,y=statistics(for:b)?.installs
                if x != y { return (x ?? -1) > (y ?? -1) }
            }
            let order=a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
    var popularThemes:[PetTheme] {
        themes.filter { statistics(for:$0)?.installs != nil }.sorted {
            let a=statistics(for:$0)?.installs ?? 0,b=statistics(for:$1)?.installs ?? 0
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a > b
        }
    }
    private func rebuildThemes() {
        themes=sources.filter(\.enabled).flatMap { catalogs[$0.id] ?? [] };searchRevision += 1
        if !modifyingLocalLibrary,let selected,let current=themes.first(where:{$0.id == selected.id}),current != selected {
            self.selected=current;invalidatePreviewForCatalogRefresh()
        }
        let refreshedFavorites=PetFavoritesRepository.updating(favorites,with:themes)
        if refreshedFavorites != favorites, favoriteRepository.save(refreshedFavorites) { favorites=refreshedFavorites }
    }
    func setEnabled(_ source:PetSource,_ enabled:Bool) {
        guard let index=sources.firstIndex(where:{$0.id == source.id}) else { return }
        sources[index].enabled=enabled;persistSources();rebuildThemes()
        if selected?.sourceID == source.id { select(nil) }
        refreshed = .distantPast;refresh()
    }
    func addSource(_ text:String) async throws {
        guard visible, sources.filter({!$0.builtIn}).count < 8 else { throw PetStoreError.invalidCatalog }
        var source=try PetSource.custom(url:PetURL.parse(text.trimmingCharacters(in:.whitespacesAndNewlines)))
        guard !sources.contains(where:{$0.catalogURL == source.catalogURL}) else { throw PetStoreError.invalidCatalog }
        let generation=catalogGeneration
        let data=try await client.data(from:source.catalogURL,limit:2_000_000,kind:.catalog)
        try Task.checkCancellation();guard visible, generation == catalogGeneration else { throw CancellationError() }
        let feed=try PetCatalog.decode(data,source:source)
        source.name=feed.name;source.websiteURL=feed.websiteURL;sources.append(source);catalogs[source.id]=feed.pets
        persistSources();rebuildThemes()
    }
    func removeSource(_ source:PetSource) {
        guard !source.builtIn else { return }
        sources.removeAll { $0.id == source.id };catalogs[source.id]=nil
        if selected?.sourceID == source.id { select(nil) }
        let cache=cache;let name=PetURL.key(source.catalogURL.absoluteString)+".json"
        Task { await cache.remove(name) }
        persistSources();rebuildThemes();refresh()
    }
    private func persistSources() { if let data=try? JSONEncoder().encode(sources) { preferences.set(data,forKey:"pets.sources") } }
    func sourceName(_ id:String) -> String { sourceNames[id] ?? id }
    func sourceCatalogState(_ id:String) -> (count:Int?,cached:Bool) {
        guard let count=catalogs[id]?.count else {return (nil,false)}
        let enabled=sources.first(where:{$0.id == id})?.enabled == true
        return (count,!enabled || cachedSources.contains(id))
    }
    func isInstalled(_ theme:PetTheme) -> Bool {
        installedIDs.contains(theme.id)
    }
    func tagCoverage(sourceID:String = "",favoritesOnly:Bool = false) -> PetTagCoverage {
        let key="\(searchRevision)|\(tagStore?.revision ?? "")|\(sourceID)|\(favoritesOnly)"
        if let value=tagCoverageCache[key] { return value }
        let candidates=favoritesOnly ? favorites.map(\.theme) : themes
        let value=tagStore?.coverage(for:candidates,sourceID:sourceID)
            ?? .init(themeCount:candidates.filter { sourceID.isEmpty || $0.sourceID == sourceID }.count,labeledThemeCount:0,tagCounts:[:])
        if tagCoverageCache.count >= 24 { tagCoverageCache.removeAll(keepingCapacity:true) }
        tagCoverageCache[key]=value
        return value
    }
    func search(_ request: PetSearchRequest) async throws -> [PetTheme] {
        let all=favorites.map(\.theme)+themes
        var labels=[String:[PetTag]]()
        for theme in all { labels[theme.id]=tagStore?.tags(for:theme) ?? [] }
        let snapshot=PetSearchSnapshot(themes:themes,favorites:favorites.map(\.theme),popularity:popularity,names:sourceNames,tags:labels)
        return try await searchEngine.query(request,snapshot:snapshot)
    }
    func clearCache() async throws {
        guard !modifyingLocalLibrary,!clearingCache else { throw PetStoreError.unavailable }
        clearingCache=true
        let wasVisible=visible;close();visible=wasVisible
        defer { let resume=visible;visible=false;clearingCache=false;if resume { open() } }
        cloudLibrary?.clearImages()
        try await tagStore?.clear()
        try await cache.clear()
        catalogs=[:];themes=[];cachedSources=[];popularity=[:];statisticsDate=nil
        thumbnailLoader.cancelAll(clearImages:true);previewCache.clear();await searchEngine.clear();searchRevision += 1;refreshed = .distantPast
    }
    func thumbnail(for theme:PetTheme) async -> NSImage? {
        guard visible,!clearingCache,!Task.isCancelled else { return nil }
        let generation=catalogGeneration
        guard let loaded=await thumbnailLoader.image(for:theme,canFetch:canFetch(theme)),
              visible,!clearingCache,generation == catalogGeneration,!Task.isCancelled else { return nil }
        if let sprite=loaded.sprite,let url=theme.previewURL {
            previewCache.rememberSprite(sprite,url:url,theme:theme,generation:generation)
        }
        return loaded.image
    }
    private func invalidatePreviewForCatalogRefresh() {
        guard !modifyingLocalLibrary else { return }
        localCheckGeneration += 1;localCheckTask?.cancel();localCheckTask=nil;checkingLocalInstall=false;localInstallRequest=nil;uninstallRequest=nil
        handoffGeneration += 1;handoffTask?.cancel();handoffTask=nil;handingOff=false;installationHandoff=false
        detailGeneration += 1;detailTask?.cancel();detailTask=nil;preparing=false
        sheet=nil;preparedLink=nil;preparedPackage=nil
        detailError=L("目录已更新，请重新加载预览。", "The catalog changed. Reload the preview.")
    }
    func cachedThumbnail(for theme:PetTheme) -> NSImage? { thumbnailLoader.cached(for:theme) }
    func select(_ theme:PetTheme?) {
        guard !modifyingLocalLibrary else { return }
        localCheckGeneration += 1;localCheckTask?.cancel();localCheckTask=nil;checkingLocalInstall=false;localInstallRequest=nil;uninstallRequest=nil
        detailTask?.cancel();detailTask=nil;detailGeneration += 1;selected=theme
        handoffGeneration += 1;handoffTask?.cancel();handoffTask=nil;handingOff=false;installationHandoff=false
        sheet=nil;selectedThumbnail=theme.flatMap(cachedThumbnail);preparedLink=nil;preparedPackage=nil;detailError=nil;notice=nil;preparing=false
        guard let theme, visible, !demonstration else { return }
        guard canFetch(theme) else {
            detailError=L("该来源已关闭或移除。请在主题来源中开启，再加载预览。", "This source is disabled or removed. Enable it in Sources to load the preview.");return
        }
        if let cached=previewCache.detail(for:theme,generation:catalogGeneration) {
            sheet=cached.image;preparedLink=cached.link;preparedPackage=cached.package;return
        }
        preparing=true;let generation=detailGeneration;let catalogTicket=catalogGeneration
        detailTask=Task {
            defer { if generation == detailGeneration { preparing=false;detailTask=nil } }
            do {
                let manifest:PetManifest
                if let inline=theme.inlineManifest { manifest=inline }
                else { manifest=try JSONDecoder().decode(PetManifest.self,from:await client.data(from:theme.manifestURL,limit:65_536,kind:.petPackage)) }
                try manifest.validate();try Task.checkCancellation()
                guard visible,generation == detailGeneration,catalogTicket == catalogGeneration else { return }
                let imageURL=try theme.spriteURL.map(PetURL.validate) ?? manifest.imageURL(relativeTo:theme.manifestURL)
                let bytes:Data
                if let cached=previewCache.spriteData(url:imageURL,theme:theme,generation:catalogTicket) { bytes=cached }
                else { bytes=try await client.data(from:imageURL,limit:20_971_520,kind:.petPackage) }
                try Task.checkCancellation()
                let image=try await Task.detached(priority:.userInitiated) { try PetSprite.image(bytes,version:manifest.version) }.value
                try Task.checkCancellation()
                guard visible,generation == detailGeneration,catalogTicket == catalogGeneration else { return }
                sheet=image
                let link=try manifest.installURL(imageURL:imageURL,fallbackName:theme.name)
                var license=theme.license
                if let url=theme.licenseURL {
                    let notice=try await client.data(from:url,limit:40_000,kind:.petPackage)
                    guard let text=String(data:notice,encoding:.utf8),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw PetStoreError.invalidCatalog }
                    license += "\n\n"+text
                }
                try Task.checkCancellation()
                guard visible,generation == detailGeneration,catalogTicket == catalogGeneration else { return }
                preparedLink=link
                let package=PetPackageInstaller.Package(sourceID:theme.sourceID,remoteID:theme.remoteID,
                    name:manifest.displayName?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false ? manifest.displayName! : theme.name,
                    description:manifest.description,author:theme.author,license:license,sourceURL:theme.websiteURL,imageURL:imageURL,
                    spriteVersionNumber:manifest.version,spriteData:bytes)
                preparedPackage=package
                if catalogTicket == catalogGeneration { previewCache.insert(theme:theme,generation:catalogTicket,image:image,link:link,package:package) }
            } catch is CancellationError {} catch {
                guard visible,generation == detailGeneration,catalogTicket == catalogGeneration,!Task.isCancelled else { return }
                detailError=(error as? PetStoreError)?.localizedDescription ?? L("主题暂时无法加载，请重试。", "Could not load this theme. Try again.")
            }
        }
    }
    func requestLocalInstallation(reinstall:Bool = false) {
        guard visible,!checkingLocalInstall,!modifyingLocalLibrary,let package=preparedPackage else { return }
        let destination=libraryRoot.appendingPathComponent("pets",isDirectory:true)
        let name=sourceName(package.sourceID)
        checkingLocalInstall=true;notice=nil;localInstallDirectory=nil;recoveryDirectory=nil;trashedDirectory=nil
        localCheckGeneration += 1;let generation=localCheckGeneration
        localCheckTask=Task {
            defer { if generation == localCheckGeneration { checkingLocalInstall=false;localCheckTask=nil } }
            do {
                let status=try await Task.detached(priority:.utility) { try PetPackageInstaller().status(of:package,in:destination) }.value
                guard visible,generation == localCheckGeneration,!Task.isCancelled else { return }
                switch status {
                case .absent:localInstallRequest = .init(package:package,destination:destination,sourceName:name,replacing:false)
                case .current:
                    if reinstall { localInstallRequest = .init(package:package,destination:destination,sourceName:name,replacing:true) }
                    else {
                        localInstallDirectory=destination.appendingPathComponent(package.folderID,isDirectory:true)
                        notice=L("这个主题已保存到本机。打开 Codex 设置，点击左侧“虚拟宠物”，刷新后选择使用。", "This theme is already saved locally. Open Codex settings, choose Pets in the sidebar, refresh, and select it.")
                        refreshInstalled()
                    }
                case .update:localInstallRequest = .init(package:package,destination:destination,sourceName:name,replacing:true)
                case .unrelated:notice=L("同名目录中的文件不属于此主题或已被修改，已保留原样。", "Files in the destination are unrelated or modified and have been left intact.")
                }
            } catch {
                guard visible,generation == localCheckGeneration,!Task.isCancelled else { return }
                showLocalInstallError(error)
            }
        }
    }
    func cancelLocalInstallation() { localInstallRequest=nil }
    func confirmLocalInstallation() {
        guard visible,!modifyingLocalLibrary,let request=localInstallRequest else { return }
        localInstallRequest=nil;installingLocally=true;notice=nil;localInstallDirectory=nil;recoveryDirectory=nil;trashedDirectory=nil
        let root=libraryRoot
        localInstallTask=Task {
            defer { installingLocally=false;localInstallTask=nil }
            do {
                let receipt=try await Task.detached(priority:.utility) {
                    try PetPackageInstaller().install(request.package,in:request.destination,replacingOwnedPackage:request.replacing)
                }.value
                let local=await Task.detached(priority:.utility) { PetLocalLibrary.scan(root:root) }.value
                installed=local;localInstallDirectory=receipt.directory
                notice=L("已安装到本机。打开 Codex 设置后，请手动点击左侧“虚拟宠物”，刷新并选择使用。", "Saved locally. Open Codex settings, manually choose Pets in the sidebar, refresh, and select your companion.")
            } catch { showLocalInstallError(error) }
        }
    }
    func requestUninstall(_ pet:InstalledPet) {
        guard visible,!checkingLocalInstall,!modifyingLocalLibrary else { return }
        checkingLocalInstall=true;notice=nil;trashedDirectory=nil
        localCheckGeneration += 1;let generation=localCheckGeneration;let root=libraryRoot
        localCheckTask=Task {
            defer { if generation == localCheckGeneration { checkingLocalInstall=false;localCheckTask=nil } }
            do {
                _=try await Task.detached(priority:.utility) { try PetPackageUninstaller().validate(pet,in:root) }.value
                guard visible,generation == localCheckGeneration,!Task.isCancelled else { return }
                uninstallRequest = .init(pet:pet,root:root)
            } catch {
                guard visible,generation == localCheckGeneration,!Task.isCancelled else { return }
                showUninstallError(error)
            }
        }
    }
    func cancelUninstall() { uninstallRequest=nil }
    func confirmUninstall() {
        guard visible,!modifyingLocalLibrary,let request=uninstallRequest else { return }
        uninstallRequest=nil;uninstallingLocally=true;notice=nil;localInstallDirectory=nil;recoveryDirectory=nil;trashedDirectory=nil
        let moveToTrash=trashItem
        localUninstallTask=Task {
            defer { uninstallingLocally=false;localUninstallTask=nil }
            do {
                let receipt=try await Task.detached(priority:.utility) {
                    try PetPackageUninstaller(trash:moveToTrash).uninstall(request.pet,in:request.root)
                }.value
                let pets=await Task.detached(priority:.utility) { PetLocalLibrary.scan(root:request.root) }.value
                installed=pets;trashedDirectory=receipt.trashDirectory
                notice=L("主题已卸载并移到废纸篓，收藏已保留。请在 Codex 设置 → 虚拟宠物中切换并刷新。", "Theme removed to Trash; favorites were kept. Switch and refresh in Codex Settings → Pets.")
            } catch { showUninstallError(error) }
        }
    }
    private func showUninstallError(_ error:Error) {
        guard visible else { return }
        if case PetPackageUninstaller.Failure.extraFiles=error {
            notice=L("主题目录包含额外文件，已保留原样。可先显示主题文件检查。", "The theme folder contains additional files and was left intact. Reveal the files to inspect them.")
        } else if case PetPackageUninstaller.Failure.changedPackage=error {
            notice=L("主题文件自列表刷新后已变化。请刷新列表再重试。", "The theme changed since the list was refreshed. Refresh the list and retry.")
        } else if case PetPackageInstaller.Failure.busy=error {
            notice=L("另一个主题操作正在进行，请稍后重试。", "Another theme operation is in progress. Try again shortly.")
        } else {
            notice=L("无法将主题移到废纸篓，文件已保留。请检查目录权限后重试。", "Could not move the theme to Trash. Its files were kept; check folder permissions and retry.")
        }
    }
    func revealInstalledFiles(_ pet:InstalledPet) {
        let root=libraryRoot
        Task {
            if let directory=try? await Task.detached(priority:.utility,operation:{try PetPackageUninstaller().validate(pet,in:root,checkingExtras:false)}).value {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        }
    }
    func revealTrashedFiles() { if let url=trashedDirectory { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func finishCurrentInstallation() async { await localInstallTask?.value;await localUninstallTask?.value;await cloudLibrary?.finishDeletion() }
    func finishInstallationCheck() async { await localCheckTask?.value }
    func revealLocalFiles() {
        guard let url=recoveryDirectory ?? localInstallDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    private func showLocalInstallError(_ error:Error) {
        guard visible else { return }
        switch error {
        case PetPackageInstaller.Failure.rollbackFailed(let backup,let displaced):
            recoveryDirectory=backup ?? displaced
            notice=L("安装未完成，已保留可恢复的主题文件。请显示恢复文件后检查。", "Installation could not finish. Recovery files were retained; reveal them to inspect.")
        case PetPackageInstaller.Failure.busy:
            notice=L("另一个安装正在进行，请稍后重试。", "Another installation is in progress. Try again shortly.")
        case PetPackageInstaller.Failure.unsafePath:
            notice=L("安装目录不可用。请确认 Codex 已在本机运行，且主题目录不是链接。", "The installation directory is unavailable. Check that Codex has run locally and the pets directory is not a link.")
        case PetPackageInstaller.Failure.unrelatedCollision:
            notice=L("目标目录中的文件已修改或不属于此主题，已保留原样。", "The destination contains modified or unrelated files and has been left intact.")
        default:notice=L("无法保存主题。请检查目录权限和可用空间，再重试。", "Could not save the theme. Check folder permissions and free space, then retry.")
        }
    }
    func installSelected() {
        guard visible,!handingOff,let url=preparedLink else { return }
        launchCodex(url,install:true)
    }
    func copyInstallLink() {
        guard visible,let url=preparedLink else { return }
        notice=copyText(url.absoluteString)
            ? L("安装链接已复制。可粘贴到浏览器地址栏后打开；安装仍需在 Codex 中确认。", "Installation link copied. Open it from your browser’s address bar; confirm installation in Codex.")
            : L("无法复制安装链接，请重试。", "Could not copy the installation link. Try again.")
    }
    func openDefaults() { openPetSettings(restoreDefault:true) }
    func chooseInstalled() { openPetSettings(restoreDefault:false) }
    private func openPetSettings(restoreDefault:Bool) {
        guard visible,!handingOff else { return }
        launchCodex(URL(string:"codex://settings")!,install:false,restoreDefault:restoreDefault)
    }
    private func launchCodex(_ url:URL,install:Bool,restoreDefault:Bool = false) {
        handingOff=true;installationHandoff=install;notice=nil
        handoffGeneration += 1;let generation=handoffGeneration
        handoffTask=Task {
            guard visible,generation == handoffGeneration,!Task.isCancelled else { return }
            let result=await openCodexURL(url)
            guard visible,generation == handoffGeneration,!Task.isCancelled else { return }
            handingOff=false;handoffTask=nil
            switch result {
            case .success:
                notice=install
                    ? L("已向 Codex 请求打开安装确认窗口。若没有弹窗，请直接通过本商店安装或重新安装。", "Requested an installation window in Codex. If none appears, install or reinstall through this store.")
                    : (restoreDefault ? L("已请求打开设置。请手动点击左侧“虚拟宠物”，选择内置主题以恢复默认。", "Requested settings. Manually choose Pets in the sidebar and select a built-in theme to restore the default.") : L("已请求打开设置。请手动点击左侧“虚拟宠物”，刷新后选择已安装的小伙伴。", "Requested settings. Manually choose Pets in the sidebar, refresh, and select your installed companion."))
            case .failure(let error):notice=error.localizedDescription
            }
        }
    }
    func showWebsite(_ url:URL) { if (try? PetURL.validate(url)) != nil { _=openURL(url) } }
    func usePreview(themes:[PetTheme],sheet:CGImage? = nil) {
        close();demonstration=true;self.themes=themes;searchRevision += 1;visible=true;self.sheet=sheet
    }
}
