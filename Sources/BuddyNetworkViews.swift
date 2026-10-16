import SwiftUI
import AppKit

struct BuddyNetworkSettingsView:View {
    @ObservedObject var settings:BuddyNetworkSettings
    @ObservedObject var tags:PetTagStore
    var sample=false
    var compact=false
    var body:some View {
        GeneralAlignedSection(L("流量统计","Network usage"),symbol:"arrow.up.arrow.down") {
            VStack(alignment:.leading,spacing:20) {
                HStack {
                    Text(L("累计流量","Network usage")).font(.system(size:15,weight:.semibold))
                    Spacer()
                    Text(L("自","Since ")+settings.traffic.startedAt.formatted(date:.abbreviated,time:.omitted)+L("起","")).font(.system(size:12)).foregroundStyle(.secondary)
                }
                if compact {
                    Grid(horizontalSpacing:18,verticalSpacing:22) {
                        GridRow {
                            metric(L("标签","Tags"),value:settings.traffic.value(.tags),partial:settings.traffic.partial.contains("tags"))
                            metric(L("目录与预览","Catalog and previews"),value:BuddyTrafficSnapshot.sum(settings.traffic.value(.catalog),settings.traffic.value(.preview)),partial:!settings.traffic.partial.isDisjoint(with:["catalog","preview"]))
                        }
                        GridRow {
                            metric(L("宠物包","Pet assets"),value:settings.traffic.value(.petPackage),partial:settings.traffic.partial.contains("petPackage"))
                            metric(L("合计","Total"),value:settings.traffic.total,partial:!settings.traffic.partial.isEmpty)
                        }
                    }
                } else {
                HStack(spacing:0) {
                    metric(L("标签","Tags"),value:settings.traffic.value(.tags),partial:settings.traffic.partial.contains("tags"))
                    Divider().frame(height:48)
                    metric(L("目录与预览","Catalog and previews"),value:BuddyTrafficSnapshot.sum(settings.traffic.value(.catalog),settings.traffic.value(.preview)),partial:!settings.traffic.partial.isDisjoint(with:["catalog","preview"]))
                    Divider().frame(height:48)
                    metric(L("宠物包","Pet assets"),value:settings.traffic.value(.petPackage),partial:settings.traffic.partial.contains("petPackage"))
                        .help(L("包含详情预览与安装所需的完整素材。其他应用自行下载的内容不在此统计。","Includes complete assets for details and installation. Transfers performed by other applications are excluded."))
                    Divider().frame(height:48)
                    metric(L("合计","Total"),value:settings.traffic.total,partial:!settings.traffic.partial.isEmpty)
                }
                }
                HStack(alignment:.firstTextBaseline) {
                if let message=tags.message { Text(message).font(.system(size:12)).foregroundStyle(.secondary) }
                else if let date=tags.lastSynced { Text(L("标签最近更新：","Tags updated: ")+date.formatted(date:.abbreviated,time:.shortened)).font(.system(size:12)).foregroundStyle(.secondary) }
                    Spacer(minLength:12)
                Text(L("仅统计本应用。","This application only.")).font(.system(size:12)).foregroundStyle(.secondary)
                    .help(L("按系统HTTP传输计量，包含请求、响应和重试；不含系统协议开销。≥表示计量不完整时已记录的下限。","System HTTP transfer measurements include requests, responses and retries, excluding protocol overhead. ≥ marks a recorded lower bound when metrics are incomplete."))
                }

            }
        }.overlay(alignment:.topTrailing) { if sample { Text(L("模拟数据","Sample data")).font(.system(size:12)).foregroundStyle(.secondary).padding(24) } }
    }
    private func metric(_ title:String,value:Int64,partial:Bool)->some View {
        VStack(alignment:.leading,spacing:7) {
            Text(title).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(2)
            Text((partial ? "≥" : "")+ByteCountFormatter.string(fromByteCount:value,countStyle:.decimal))
                .font(.system(size:22,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.padding(.horizontal,12).frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct PetTagFilters:View {
    let facets:[PetTagFacet]
    @Binding var selected:Set<String>
    var onOpen:()->Void = {}
    var body:some View {
        HStack(spacing:10) {
            ForEach(facets) { facet in PetTagFacetControl(facet:facet,selected:$selected,onOpen:onOpen) }
            Button(L("清除","Clear")) { selected=[] }.buttonStyle(.plain).foregroundStyle(.blue).disabled(selected.isEmpty)
                .accessibilityIdentifier("pets-tags-clear")
        }
    }
}
private struct PetTagFacetControl:View {
    let facet:PetTagFacet
    @Binding var selected:Set<String>
    var onOpen:()->Void
    @State private var opened=false
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
                    Text(facet.title).font(.system(size:16,weight:.semibold))
                    ForEach(facet.tags) { tag in
                        Toggle(tag.label.text,isOn:Binding(get:{selected.contains(tag.id)},set:{ value in if value { selected.insert(tag.id) } else { selected.remove(tag.id) } }))
                            .toggleStyle(.checkbox).accessibilityIdentifier("pet-tag-"+tag.id)
                    }
                }.padding(20).frame(width:220,alignment:.leading)
            }
    }
}

