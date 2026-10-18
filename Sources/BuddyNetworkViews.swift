import SwiftUI
import AppKit

struct BuddyNetworkSettingsView:View {
    @ObservedObject var settings:BuddyNetworkSettings
    @ObservedObject var tags:PetTagStore
    var sample=false
    var compact=false
    var minimumHeight:CGFloat = 0
    var body:some View {
        GeneralAlignedSection(L("流量统计","Network usage"),symbol:"arrow.up.arrow.down",minimumHeight:minimumHeight) {
            VStack(alignment:.leading,spacing:16) {
                VStack(alignment:.leading,spacing:6) {
                    Text((settings.traffic.partial.isEmpty ? "" : "≥")+ByteCountFormatter.string(fromByteCount:settings.traffic.total,countStyle:.decimal))
                        .font(.system(size:28,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                    Text(L("自","Since ")+settings.traffic.startedAt.formatted(date:.abbreviated,time:.omitted)+L("起","")).font(.system(size:12)).foregroundStyle(.secondary)
                }
                VStack(spacing:0) {
                    trafficRow(L("标签","Tags"),symbol:"tag",value:settings.traffic.value(.tags),partial:settings.traffic.partial.contains("tags"))
                    Divider()
                    trafficRow(L("目录与预览","Catalog and previews"),symbol:"doc.text.image",value:BuddyTrafficSnapshot.sum(settings.traffic.value(.catalog),settings.traffic.value(.preview)),partial:!settings.traffic.partial.isDisjoint(with:["catalog","preview"]))
                    Divider()
                    trafficRow(L("宠物包","Pet assets"),symbol:"shippingbox",value:settings.traffic.value(.petPackage),partial:settings.traffic.partial.contains("petPackage"))
                        .help(L("包含详情预览与安装所需的完整素材。其他应用自行下载的内容不在此统计。","Includes complete assets for details and installation. Transfers performed by other applications are excluded."))
                }
                Spacer(minLength:0)
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    if let message=tags.message {Text(message).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                    else if let date=tags.lastSynced {Text(L("标签最近更新：","Tags updated: ")+date.formatted(date:.abbreviated,time:.shortened)).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                    Spacer(minLength:0)
                    Text(L("仅统计本应用。","This application only.")).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        .help(L("按系统HTTP传输计量，包含请求、响应和重试；不含系统协议开销。≥表示计量不完整时已记录的下限。","System HTTP transfer measurements include requests, responses and retries, excluding protocol overhead. ≥ marks a recorded lower bound when metrics are incomplete."))
                }.frame(minHeight:40,alignment:.center)
            }
        }.overlay(alignment:.topTrailing) {if sample {Text(L("模拟数据","Sample data")).font(.system(size:11)).foregroundStyle(.secondary).padding(20)}}
    }
    private func trafficRow(_ title:String,symbol:String,value:Int64,partial:Bool)->some View {
        HStack(spacing:12) {
            Image(systemName:symbol).font(.system(size:18)).foregroundStyle(.secondary).frame(width:24).accessibilityHidden(true)
            Text(title).font(.system(size:13)).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:8)
            Text((partial ? "≥" : "")+ByteCountFormatter.string(fromByteCount:value,countStyle:.decimal))
                .font(.system(size:19,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(minHeight:70)
    }
}

struct PetTagFilters:View {
    let facets:[PetTagFacet]
    @Binding var selected:Set<String>
    let coverage:PetTagCoverage
    let hasMetadata:Bool
    let syncing:Bool
    var onOpen:()->Void = {}
    var retry:()->Void = {}
    var body:some View {
        HStack(spacing:10) {
            ForEach(facets) { facet in
                PetTagFacetControl(facet:facet,selected:$selected,coverage:coverage,hasMetadata:hasMetadata,
                    syncing:syncing,onOpen:onOpen,retry:retry)
            }
            Button(L("清除","Clear")) { selected=[] }.buttonStyle(.plain).foregroundStyle(.blue).disabled(selected.isEmpty)
                .accessibilityIdentifier("pets-tags-clear")
        }
    }
}
private struct PetTagFacetControl:View {
    let facet:PetTagFacet
    @Binding var selected:Set<String>
    let coverage:PetTagCoverage
    let hasMetadata:Bool
    let syncing:Bool
    var onOpen:()->Void
    var retry:()->Void
    @State private var opened=false
    private var options:[PetTag] { facet.tags.filter { (coverage.tagCounts[$0.id] ?? 0) > 0 || selected.contains($0.id) } }
    var body:some View {
        Button { onOpen();opened.toggle() } label: {
            HStack(spacing:7) {
                Image(systemName:facet.id == "subject" ? "tag" : facet.id == "style" ? "paintpalette" : "drop")
                Text(facet.title)
                if selected.intersection(facet.tags.map(\.id)).count > 0 { Text("\(selected.intersection(facet.tags.map(\.id)).count)").foregroundStyle(.blue) }
                Image(systemName:"chevron.down").font(.system(size:10))
            }.font(.system(size:13)).padding(.horizontal,10).frame(height:34).contentShape(Rectangle())
                .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.12),lineWidth:0.7))
        }.buttonStyle(.plain).accessibilityIdentifier("pets-tags-"+facet.id)
            .popover(isPresented:$opened) {
                VStack(alignment:.leading,spacing:12) {
                    HStack { Text(facet.title).font(.system(size:16,weight:.semibold));Spacer();if syncing {ProgressView().controlSize(.small)} }
                    if !hasMetadata {
                        Text(syncing ? L("正在获取标签…","Loading tags…") : L("标签暂不可用","Tags are unavailable"))
                            .font(.system(size:13,weight:.medium))
                        if !syncing {
                            Text(L("获取成功后即可按标签筛选。","Filtering will be available once tags load."))
                                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            Button(L("重试","Retry"),action:retry).buttonStyle(.link)
                                .accessibilityIdentifier("pets-tags-retry-"+facet.id)
                        }
                    } else if options.isEmpty {
                        Text(L("当前范围暂无这类标签。","No tags of this kind in the current selection."))
                            .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    } else {
                        ForEach(options) { tag in
                            HStack(spacing:12) {
                                Toggle(tag.label.text,isOn:Binding(get:{selected.contains(tag.id)},set:{ value in if value { selected.insert(tag.id) } else { selected.remove(tag.id) } }))
                                    .toggleStyle(.checkbox).accessibilityIdentifier("pet-tag-"+tag.id)
                                Spacer(minLength:8)
                                Text((coverage.tagCounts[tag.id] ?? 0).formatted()).monospacedDigit().foregroundStyle(.secondary)
                                    .help(L("当前来源或收藏范围中，带有此标签的已标注宠物数量。","Tagged pets with this label in the current source or favorites scope."))
                            }.font(.system(size:13))
                        }
                    }
                    if hasMetadata && coverage.labeledThemeCount < coverage.themeCount {
                        Divider()
                        Text(L("已标注 \(coverage.labeledThemeCount.formatted()) / \(coverage.themeCount.formatted()) 只",
                            "\(coverage.labeledThemeCount.formatted()) of \(coverage.themeCount.formatted()) pets tagged"))
                            .font(.system(size:11)).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(width:240,alignment:.leading)
            }
    }
}
