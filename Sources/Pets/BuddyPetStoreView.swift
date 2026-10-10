import SwiftUI
import AppKit

struct BuddyPetStoreView: View {
    @ObservedObject var store: ThemeStoreModel
    @ObservedObject var updates: UpdateManager
    @State private var page: PetStorePage = .discover
    @State private var search = ""
    @State private var installedSearch = ""
    @State private var sourceSearch = ""
    @State private var sourceFilter = ""
    @State private var sortByInstalls = true
    @State private var addingSource = false
    @State private var showingGuide = false
    @State private var showingOptions = false
    @State private var showingStatistics = false

    var body: some View {
        VStack(spacing:0) {
            header.padding(.horizontal,32).padding(.top,32).padding(.bottom,34)
            tabs.padding(.horizontal,32)
            Divider().padding(.horizontal,32)
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if let theme = store.selected { detail(theme) }
                    else {
                        switch page {
                        case .discover, .favorites:
                            BuddyPetDiscoverView(store:store,search:search,sourceFilter:$sourceFilter,
                                sortByInstalls:$sortByInstalls,favoritesOnly:page == .favorites)
                        case .installed: installed
                        case .sources: sources
                        }
                    }
                }.padding(.horizontal,32).padding(.top,18).padding(.bottom,32)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
            if store.modifyingLocalLibrary {
                HStack(spacing:10) {
                    ProgressView().controlSize(.small)
                    Text(store.uninstallingLocally ? L("正在卸载宠物…", "Removing pet…") : L("正在校验并保存宠物…", "Verifying and saving pet…"))
                    Spacer()
                }.font(.system(size:13)).padding(16).background(Color.accentColor.opacity(0.08))
            }
            if let notice = store.notice { noticeRow(notice) }
        }.disabled(store.modifyingLocalLibrary || updates.installing)
            .sheet(isPresented:$addingSource) { PetSourceSheet(store:store) }
            .sheet(isPresented:$showingGuide) {
                PetSettingsGuide(openSettings:{ showingGuide=false;store.chooseInstalled() },close:{ showingGuide=false })
            }
            .sheet(item:$store.localInstallRequest) { request in
                PetLocalInstallConsent(name:request.package.name,author:request.package.author,license:request.package.license,
                    source:request.sourceName,destination:request.displayPath,replacing:request.replacing,
                    cancel:{store.cancelLocalInstallation()},confirm:{store.confirmLocalInstallation()})
            }
            .sheet(item:$store.uninstallRequest) { request in
                PetUninstallConsent(name:request.pet.name,cancel:{store.cancelUninstall()},confirm:{store.confirmUninstall()})
            }
            .onChange(of:store.selected?.id) { _ in showingOptions=false }
            .onChange(of:store.visible) { if !$0 { addingSource=false;showingGuide=false;showingOptions=false } }
            .onChange(of:search) { _ in if store.selected != nil { store.select(nil) } }
            .onAppear {
                if let index=CommandLine.arguments.firstIndex(of:"--pets-page"),CommandLine.arguments.count > index+1 {
                    page=PetStorePage(rawValue:CommandLine.arguments[index+1]) ?? .discover
                }
            }
    }

    private var header: some View {
        HStack(spacing:14) {
            BuddyPageHeading(title:L("宠物", "Pets"))
            Spacer(minLength:16)
            if page == .sources {
                Button { addingSource=true } label: {
                    Label(L("添加来源", "Add source"),systemImage:"plus").padding(.horizontal,12).padding(.vertical,7)
                        .contentShape(RoundedRectangle(cornerRadius:9))
                }.buttonStyle(PetPrimaryButtonStyle()).disabled(store.sources.filter({!$0.builtIn}).count >= 8)
            } else {
                searchField(page == .installed ? L("搜索本机宠物", "Search installed pets") : L("搜索宠物、作者", "Search pets, authors"),text:page == .installed ? $installedSearch : $search)
                    .frame(width:265)
            }
            Button { if page == .installed { store.refreshInstalled() } else { store.refresh() } } label: {
                Image(systemName:"arrow.clockwise").font(.system(size:18)).frame(width:38,height:38)
                    .contentShape(RoundedRectangle(cornerRadius:9))
            }.buttonStyle(.plain).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9))
                .overlay(RoundedRectangle(cornerRadius:9).stroke(Color.primary.opacity(0.10),lineWidth:0.7))
                .disabled(store.loading).accessibilityLabel(L("刷新宠物", "Refresh pets"))
        }
    }
    private var tabs: some View {
        HStack(spacing:28) {
            ForEach(PetStorePage.allCases) { item in
                Button { page=item;store.select(nil);store.notice=nil } label: {
                    VStack(spacing:12) {
                        Label(item.title,systemImage:item.symbol).font(.system(size:15,weight:page == item ? .semibold : .regular))
                            .frame(minHeight:26).padding(.horizontal,3)
                        Rectangle().fill(page == item ? Color.accentColor : Color.clear).frame(height:3)
                    }.fixedSize(horizontal:true,vertical:false)
                        .foregroundStyle(page == item ? Color.accentColor : Color.primary.opacity(0.85))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
                    .accessibilityIdentifier("pets-tab-"+item.rawValue)
            }
            Spacer(minLength:0)
            if store.loading { ProgressView().controlSize(.small).accessibilityLabel(L("更新宠物目录", "Refreshing pet catalogs")) }
        }
    }
    private func searchField(_ prompt:String,text:Binding<String>) -> some View {
        HStack(spacing:8) {
            Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt,text:text).textFieldStyle(.plain).accessibilityLabel(prompt)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue="" } label:{Image(systemName:"xmark.circle.fill")}
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("清除搜索", "Clear search"))
            }
        }.font(.system(size:14)).padding(.horizontal,12).frame(height:38)
            .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9))
            .overlay(RoundedRectangle(cornerRadius:9).stroke(Color.primary.opacity(0.13),lineWidth:0.7))
    }

    private func detail(_ theme:PetTheme) -> some View {
        VStack(alignment:.leading,spacing:24) {
            Button { store.select(nil) } label: {
                Label(L("返回", "Back to ")+page.title,systemImage:"chevron.left").font(.system(size:14))
                    .padding(.vertical,7).padding(.trailing,14).contentShape(Rectangle())
            }.buttonStyle(.plain)
            PetDetailLayout {
                PetAnimatedPreview(image:store.sheet,loading:store.preparing,error:store.detailError).frame(height:610)
                detailInformation(theme)
            }
            if store.detailError != nil {
                Button(L("重新加载", "Retry")) { store.select(theme) }.buttonStyle(.link)
            }
        }
    }
    private func detailInformation(_ theme:PetTheme) -> some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(alignment:.top) {
                Text(theme.name).font(.system(size:32,weight:.bold)).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                Spacer(minLength:12)
                PetFavoriteButton(theme:theme,store:store)
            }
            Text(theme.author).font(.system(size:14)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(store.sourceName(theme.sourceID)).font(.system(size:14)).foregroundStyle(.secondary)
            Divider()
            Text(description(theme)).font(.system(size:14)).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            if let package=store.preparedPackage {
                Text("v\(package.spriteVersionNumber)").font(.system(size:12)).foregroundStyle(.secondary)
                    .padding(.horizontal,7).padding(.vertical,4).background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:5))
            }
            HStack(spacing:12) {
                Button {
                    if store.isInstalled(theme) { store.chooseInstalled() } else { store.requestLocalInstallation() }
                } label: {
                    Label(store.checkingLocalInstall ? L("正在检查…", "Checking…") : store.isInstalled(theme) ? L("打开 Codex 设置", "Open Codex settings") : L("安装到本机", "Install locally"),
                        systemImage:store.isInstalled(theme) ? "arrow.up.right" : "arrow.down.to.line")
                        .font(.system(size:15,weight:.semibold)).frame(maxWidth:.infinity,minHeight:50).contentShape(RoundedRectangle(cornerRadius:10))
                }.buttonStyle(PetPrimaryButtonStyle())
                    .disabled(store.preparedPackage == nil || store.preparing || store.checkingLocalInstall || store.handingOff)
                Button { showingOptions.toggle() } label: {
                    Image(systemName:"ellipsis").frame(width:44,height:44).contentShape(Circle())
                }.buttonStyle(.plain).background(Color.primary.opacity(0.045),in:Circle())
                    .accessibilityLabel(L("更多安装与使用操作", "More installation and usage options"))
                    .popover(isPresented:$showingOptions) {
                        PetInstallOptions(installed:store.isInstalled(theme),canReinstall:store.preparedPackage != nil && !store.preparing && !store.checkingLocalInstall,
                            canSend:store.preparedLink != nil && !store.handingOff && !store.preparing,canCopy:store.preparedLink != nil,
                            showGuide:{showingOptions=false;showingGuide=true},reinstall:{showingOptions=false;store.requestLocalInstallation(reinstall:true)},
                            sendToCodex:{showingOptions=false;store.installSelected()},copyLink:{showingOptions=false;store.copyInstallLink()})
                    }
            }
            Text(store.isInstalled(theme) ? L("设置 → 虚拟宠物 → 刷新并选择", "Settings → Pets → Refresh and choose") : L("安装后在 Codex 中选择使用。", "Choose the pet in Codex after installation."))
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if store.statistics(for:theme) != nil {
                HStack(spacing:10) {
                    PetPopularityLine(stats:store.statistics(for:theme))
                    Button { showingStatistics.toggle() } label:{ Image(systemName:"info.circle") }
                        .buttonStyle(.plain).accessibilityLabel(L("统计来源与时间", "Statistics source and time"))
                        .popover(isPresented:$showingStatistics) { PetStatisticsNote(store:store).padding(16).frame(width:340) }
                }
            }
            Divider()
            HStack(alignment:.top,spacing:18) {
                Text(L("授权", "License")).font(.system(size:13)).foregroundStyle(.secondary).frame(width:44,alignment:.leading)
                Text(theme.license).font(.system(size:13)).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            }
            Divider()
            Button { store.showWebsite(theme.websiteURL) } label: {
                Label(L("原始主题与授权", "Original pet and license"),systemImage:"arrow.up.right.square").font(.system(size:14))
            }.buttonStyle(.link)
        }
    }
    private func description(_ theme:PetTheme) -> String {
        let text=theme.summary.isEmpty ? store.preparedPackage?.description ?? "" : theme.summary
        return text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? L("暂无简介。", "No description provided.") : text
    }

    private var installed: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Spacer()
                Button { store.chooseInstalled() } label:{Label(L("打开 Codex 设置", "Open Codex settings"),systemImage:"arrow.up.right")}.buttonStyle(.link)
            }.padding(.bottom,18)
            let filtered=store.installed.filter { installedSearch.isEmpty || ($0.name+" "+($0.sourceID.map(store.sourceName) ?? "")).localizedCaseInsensitiveContains(installedSearch) }
            if filtered.isEmpty { emptyState(L("暂无本机宠物", "No installed pets")) }
            ForEach(filtered) { pet in
                HStack(spacing:18) {
                    PetLocalImage(pet:pet).frame(width:60,height:64)
                    VStack(alignment:.leading,spacing:5) {
                        Text(pet.name).font(.system(size:15,weight:.semibold))
                        Text(pet.sourceID.map(store.sourceName) ?? L("本机导入", "Local import")).font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("v\(pet.version)").font(.system(size:12)).foregroundStyle(.secondary)
                    Menu {
                        Button(L("安装后怎么使用？", "How do I use an installed pet?")) { showingGuide=true }
                        Button(L("显示主题文件", "Reveal theme files")) { store.revealInstalledFiles(pet) }
                        Button(L("卸载…", "Uninstall…"),role:.destructive) { store.requestUninstall(pet) }
                    } label:{ Image(systemName:"ellipsis").frame(width:30,height:30) }.menuStyle(.borderlessButton).fixedSize()
                    Button(role:.destructive) { store.requestUninstall(pet) } label:{ Image(systemName:"trash").frame(width:32,height:32).contentShape(Rectangle()) }
                        .buttonStyle(.plain).disabled(store.checkingLocalInstall).accessibilityLabel(L("卸载", "Uninstall ")+pet.name)
                }.padding(.vertical,10)
                Divider()
            }
        }
    }
    private var sources: some View {
        VStack(alignment:.leading,spacing:14) {
            searchField(L("搜索来源", "Search sources"),text:$sourceSearch).frame(width:320).padding(.bottom,10)
            sourceGroup(L("内置来源", "Built-in sources"),builtIn:true)
            sourceGroup(L("自定义来源", "Custom sources"),builtIn:false).padding(.top,10)
        }
    }
    private func sourceGroup(_ title:String,builtIn:Bool) -> some View {
        let all=store.sources.filter{$0.builtIn == builtIn}
        let filtered=all.filter { sourceSearch.isEmpty || ($0.name+" "+$0.websiteURL.absoluteString).localizedCaseInsensitiveContains(sourceSearch) }
        return VStack(alignment:.leading,spacing:0) {
            HStack {
                Text(title).font(.system(size:16,weight:.semibold))
                if builtIn { Text("\(all.count)").font(.system(size:12)).foregroundStyle(.secondary) }
                Spacer()
                if !builtIn { Text("\(all.count) / 8").font(.system(size:12)).foregroundStyle(.secondary) }
            }.padding(.bottom,10)
            Divider()
            ForEach(filtered) { source in
                HStack(spacing:18) {
                    Image(systemName:"globe").font(.system(size:21)).foregroundStyle(Color.accentColor.opacity(0.7)).frame(width:30)
                    VStack(alignment:.leading,spacing:3) {
                        Text(source.name).font(.system(size:14,weight:.semibold)).lineLimit(1)
                        Text(store.sourceErrors[source.id].map { $0+(store.cachedSources.contains(source.id) ? L(" · 本机缓存", " · cached") : "") } ?? sourceLocation(source))
                            .font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Button { store.showWebsite(source.websiteURL) } label:{ Image(systemName:"arrow.up.right.square").font(.system(size:17)).frame(width:32,height:32).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel(L("访问来源", "Visit source ")+source.name)
                    if !builtIn {
                        Button(role:.destructive) { store.removeSource(source) } label:{Image(systemName:"minus.circle").frame(width:30,height:30).contentShape(Rectangle())}
                            .buttonStyle(.plain).accessibilityLabel(L("移除来源", "Remove source ")+source.name)
                    }
                    Toggle(source.name,isOn:Binding(get:{source.enabled},set:{store.setEnabled(source,$0)})).labelsHidden()
                        .toggleStyle(OverviewSwitchStyle(title:L("启用来源", "Enable source ")+source.name)).frame(width:48)
                }.frame(minHeight:42).padding(.vertical,1)
                Divider()
            }
            if filtered.isEmpty {
                Text(all.isEmpty ? L("尚未添加自定义来源。", "No custom sources yet.") : L("没有匹配的来源", "No matching sources"))
                    .font(.system(size:13)).foregroundStyle(.secondary).padding(.vertical,18)
            }
        }
    }
    private func sourceLocation(_ source:PetSource) -> String {
        source.websiteURL.host == "github.com" ? source.websiteURL.path.trimmingCharacters(in:CharacterSet(charactersIn:"/")) : source.websiteURL.host ?? ""
    }
    private func emptyState(_ title:String) -> some View {
        VStack(spacing:16) { PetStoreMark(size:54);Text(title).font(.system(size:18,weight:.semibold)) }
            .frame(maxWidth:.infinity).padding(.vertical,80)
    }
    private func noticeRow(_ text:String) -> some View {
        HStack(alignment:.top,spacing:12) {
            Image(systemName:"info.circle").foregroundStyle(Color.accentColor)
            VStack(alignment:.leading,spacing:9) {
                Text(text).fixedSize(horizontal:false,vertical:true)
                HStack(spacing:16) {
                    if store.localInstallDirectory != nil || store.installationHandoff {
                        Button(L("打开 Codex 设置", "Open Codex settings")) { store.chooseInstalled() }.disabled(store.handingOff)
                    }
                    if store.localInstallDirectory != nil || store.recoveryDirectory != nil {
                        Button(store.recoveryDirectory != nil ? L("显示恢复文件", "Reveal recovery files") : L("显示主题文件", "Reveal theme files")) { store.revealLocalFiles() }
                    }
                    if store.installationHandoff { Button(L("复制安装链接", "Copy install link")) { store.copyInstallLink() } }
                    if store.trashedDirectory != nil { Button(L("显示废纸篓文件", "Reveal trashed files")) { store.revealTrashedFiles() } }
                }.buttonStyle(.link)
            }
            Spacer(minLength:0)
            Button { store.notice=nil } label:{Image(systemName:"xmark").frame(width:24,height:24).contentShape(Rectangle())}
                .buttonStyle(.plain).accessibilityLabel(L("关闭提示", "Dismiss notice"))
        }.font(.system(size:13)).padding(16).background(Color.accentColor.opacity(0.07))
    }
}

// Long source attribution must extend the scroll region rather than overflow a
// fixed-height GeometryReader. The preview stays at its chosen stage height.
private struct PetDetailLayout: Layout {
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        let width=proposal.width ?? 1028
        let left=max(0,(width-34)*0.58),right=max(0,width-34-left)
        return CGSize(width:width,height:max(subviews[0].sizeThatFits(.init(width:left,height:nil)).height,
                                             subviews[1].sizeThatFits(.init(width:right,height:nil)).height))
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        let left=max(0,(bounds.width-34)*0.58),right=max(0,bounds.width-34-left)
        subviews[0].place(at:bounds.origin,anchor:.topLeading,proposal:.init(width:left,height:nil))
        subviews[1].place(at:CGPoint(x:bounds.minX+left+34,y:bounds.minY),anchor:.topLeading,proposal:.init(width:right,height:nil))
    }
}

private struct PetLocalImage:View {
    let pet:InstalledPet
    @State private var image:NSImage?
    var body:some View {
        Group {
            if let image { Image(nsImage:image).resizable().scaledToFit() }
            else { PetStoreMark(size:44) }
        }.accessibilityHidden(true).task(id:pet.id) {
            let pet=pet
            let frame=await Task.detached(priority:.utility) { () -> CGImage? in
                guard let file=try? FileHandle(forReadingFrom:pet.imageURL) else { return nil }
                defer { try? file.close() }
                guard let bytes=try? file.read(upToCount:32_000_001), let sheet=try? PetSprite.image(bytes,version:pet.version) else { return nil }
                return sheet.cropping(to:CGRect(x:0,y:0,width:192,height:208))
            }.value
            guard !Task.isCancelled else { return }
            image=frame.map { NSImage(cgImage:$0,size:NSSize(width:192,height:208)) }
        }
    }
}


private struct PetSourceSheet:View {
    @ObservedObject var store:ThemeStoreModel
    @Environment(\.dismiss) private var dismiss
    @State private var url=""
    @State private var error:String?
    @State private var loading=false
    @State private var task:Task<Void,Never>?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("添加主题来源", "Add a theme source")).font(.system(size:20,weight:.bold))
            Text(L("粘贴兼容主题目录的公开 HTTPS 地址。", "Paste a public HTTPS URL for a compatible theme catalog."))
                .font(.system(size:13)).foregroundStyle(.secondary)
            TextField("https://example.com/pets/catalog.json",text:$url).textFieldStyle(.roundedBorder)
                .accessibilityLabel(L("主题目录地址", "Theme catalog URL"))
            if let error { Text(error).font(.system(size:12)).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("取消", "Cancel")) { task?.cancel();dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("添加", "Add")) {
                    loading=true;error=nil
                    task=Task {
                        do { try await store.addSource(url);dismiss() }
                        catch is CancellationError {} catch { self.error=(error as? PetStoreError)?.localizedDescription ?? L("暂时无法连接该来源。", "Could not connect to this source.") }
                        loading=false
                    }
                }.keyboardShortcut(.defaultAction).disabled(loading || url.isEmpty)
            }
        }.padding(24).frame(width:450).onDisappear { task?.cancel() }
    }
}
