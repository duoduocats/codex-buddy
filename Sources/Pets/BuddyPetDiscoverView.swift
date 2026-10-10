import SwiftUI
import AppKit

struct PetTileImage: View {
    let theme: PetTheme
    @ObservedObject var store: ThemeStoreModel
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage:image).resizable().scaledToFit().padding(5) }
            else { PetStoreMark(size:44) }
        }.accessibilityHidden(true).task(id:theme.id) {
            image=nil;image=await store.thumbnail(for:theme)
        }
    }
}

struct BuddyPetDiscoverView:View {
    @ObservedObject var store:ThemeStoreModel
    var search:String
    @Binding var sourceFilter:String
    @Binding var sortByInstalls:Bool
    var favoritesOnly=false
    private var filtered:[PetTheme] { store.matchingThemes(query:search,sourceID:sourceFilter,byInstalls:sortByInstalls,favoritesOnly:favoritesOnly) }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            controls
            if filtered.isEmpty {
                VStack(spacing:12) {
                    PetStoreMark(size:52)
                    Text(favoritesOnly ? L("把喜欢的小伙伴留在这里", "Keep your favorites here") : (store.loading ? L("正在寻找小伙伴…", "Finding companions…") : L("暂无匹配主题", "No matching themes")))
                        .font(.system(size:17,weight:.semibold))
                    Text(favoritesOnly ? L("点击主题上的书签即可收藏，收藏只保存在这台 Mac。", "Bookmark a theme to save it on this Mac.") : L("换个关键词或来源试试。", "Try another keyword or source."))
                        .font(.system(size:12)).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity).padding(.vertical,72)
            } else {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:260),spacing:16)],alignment:.leading,spacing:16) {
                    ForEach(filtered) { theme in PetStoreCard(theme:theme,store:store) }
                }
            }
        }.onChange(of:store.sources) { sources in
            if !sources.contains(where:{$0.id == sourceFilter && $0.enabled}) { sourceFilter="" }
        }
    }
    private var controls:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                PetSourcePicker(sources:store.sources,selection:$sourceFilter)
                    .padding(.horizontal,10).frame(width:220,height:36)
                    .background(Color.primary.opacity(0.03),in:RoundedRectangle(cornerRadius:9))
                    .overlay(RoundedRectangle(cornerRadius:9).stroke(Color.primary.opacity(0.12),lineWidth:0.7))
                Spacer(minLength:8)
                SettingsSegments(labels:[L("名称", "Name"),L("热度", "Popular")],selection:Binding(
                    get:{sortByInstalls ? 1 : 0},set:{sortByInstalls = $0 == 1}),accessibilityLabel:L("排序", "Sort"))
                    .frame(width:190,height:36)

            }.frame(minHeight:30)
            if !store.sourceErrors.isEmpty || (!store.loading && !store.cachedSources.isEmpty) {
                Label(L("部分来源未更新，可在来源页重试。", "Some sources could not update. Retry in Sources."),systemImage:"wifi.exclamationmark")
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
            if store.statisticsUnavailable {
                Text(L("热度暂未更新，浏览与安装不受影响。", "Popularity could not update. Browsing remains available."))
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct PetStatisticsNote:View {
    @ObservedObject var store:ThemeStoreModel
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text(L("数据来自 Codex Pet Gallery 的公开统计，仅代表该来源记录，不是全球使用量。", "Public counters from Codex Pet Gallery reflect that source’s records, not worldwide usage."))
            if let date=store.statisticsDate { Text(snapshotLabel(date)) }
            Text(L("其他来源的主题未提供统计时显示为未知。", "Counters remain unknown when another source has not provided them."))
        }.font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }
    private func snapshotLabel(_ date:Date) -> String {
        let formatter=DateFormatter();formatter.locale=Locale.autoupdatingCurrent;formatter.timeZone=TimeZone.autoupdatingCurrent
        formatter.dateStyle = .medium;formatter.timeStyle = .short
        let zone=formatter.timeZone.abbreviation(for:date) ?? formatter.timeZone.identifier
        return L("统计快照：", "Snapshot: ")+formatter.string(from:date)+" "+zone+(store.statisticsCached ? L(" · 本机缓存", " · cached") : "")
    }
}

struct PetPopularityLine:View {
    var stats:PetPopularity?
    var body:some View {
        HStack(spacing:10) {
            if let installs=stats?.installs {
                Label(installs.formatted(),systemImage:"arrow.down")
                    .help(L("来源记录的安装次数", "Installs recorded by the source"))
                    .accessibilityLabel(L("来源安装记录：\(installs.formatted())", "Source-recorded installs: \(installs.formatted())"))
            }
            if let likes=stats?.likes {
                Label(likes.formatted(),systemImage:"heart")
                    .help(L("来源记录的喜欢次数", "Likes recorded by the source"))
                    .accessibilityLabel(L("来源喜欢：\(likes.formatted())", "Source-recorded likes: \(likes.formatted())"))
            }
            if stats?.installs == nil && stats?.likes == nil {
                Text("—").help(L("来源暂未提供热度", "Source popularity unavailable"))
                    .accessibilityLabel(L("来源暂未提供热度", "Source popularity unavailable"))
            }
        }.font(.system(size:10)).foregroundStyle(.secondary)
    }
}

struct PetFavoriteButton:View {
    let theme:PetTheme
    @ObservedObject var store:ThemeStoreModel
    var body:some View {
        Button { store.toggleFavorite(theme) } label:{
            Image(systemName:store.isFavorite(theme) ? "bookmark.fill" : "bookmark")
                .font(.system(size:13,weight:.medium)).frame(width:32,height:32).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .help(store.isFavorite(theme) ? L("取消本地收藏", "Remove local favorite") : L("收藏到这台 Mac", "Save on this Mac"))
            .accessibilityLabel(store.isFavorite(theme) ? L("取消收藏 \(theme.name)", "Unsave \(theme.name)") : L("收藏 \(theme.name)", "Save \(theme.name)"))
    }
}

private struct PetStoreCard:View {
    let theme:PetTheme
    @ObservedObject var store:ThemeStoreModel
    @State private var hovering=false
    var body:some View {
        ZStack(alignment:.topTrailing) {
            Button { store.select(theme) } label:{
                VStack(alignment:.leading,spacing:9) {
                    PetTileImage(theme:theme,store:store).frame(maxWidth:.infinity).frame(height:132)
                    VStack(alignment:.leading,spacing:3) {
                        HStack(spacing:6) {
                            Text(theme.name).font(.system(size:15,weight:.semibold)).lineLimit(1)
                            Spacer(minLength:0)
                            if store.isInstalled(theme) { Label(L("已安装", "Installed"),systemImage:"checkmark.circle.fill").font(.system(size:11)).foregroundStyle(Color.accentColor) }
                        }
                        Text(store.sourceName(theme.sourceID)).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(1)
                            .help(theme.author+" · "+store.sourceName(theme.sourceID))
                    }
                    if store.statistics(for:theme) != nil { PetPopularityLine(stats:store.statistics(for:theme)) }
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading).contentShape(RoundedRectangle(cornerRadius:12))
            }.buttonStyle(.plain)
            PetFavoriteButton(theme:theme,store:store).padding(5)
        }.background(hovering ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.06),lineWidth:0.5))
            .onHover { hovering=$0 }
    }
}
