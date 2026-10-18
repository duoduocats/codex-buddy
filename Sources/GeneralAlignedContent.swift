import AppKit
import SwiftUI

struct GeneralAlignedSection<Content: View>: View {
    let title: String
    let symbol: String
    let minimumHeight: CGFloat
    let content: Content
    init(_ title: String,symbol: String,minimumHeight:CGFloat = 0,@ViewBuilder content: () -> Content) {
        self.title=title;self.symbol=symbol;self.minimumHeight=minimumHeight;self.content=content()
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:10) {
                Image(systemName:symbol).font(.system(size:19,weight:.regular)).foregroundStyle(Color.secondary)
                    .frame(width:23).accessibilityHidden(true)
                Text(title).font(.system(size:17,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength:12)

            }.frame(minHeight:24)
            Divider()
            content.frame(minHeight:max(0,minimumHeight-97),alignment:.topLeading)
        }.padding(20).frame(maxWidth:.infinity,minHeight:minimumHeight,alignment:.topLeading)
            .background(Color.primary.opacity(0.018),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.10),lineWidth:0.7))
    }
}

struct GeneralAlignedPreferenceRow: View {
    let title: String
    let detail: String
    var selection: Binding<Bool>
    var body: some View {
        HStack(spacing:20) {
            VStack(alignment:.leading,spacing:5) {
                Text(title).font(.system(size:16,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                Text(detail).font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(3)
                    .fixedSize(horizontal:false,vertical:true)
            }.frame(maxWidth:.infinity,alignment:.leading)
            Toggle(title,isOn:selection).labelsHidden().toggleStyle(OverviewSwitchStyle(title:title))
                .accessibilityHint(detail).help(detail)
        }.frame(minHeight:40)
    }
}

struct GeneralAlignedStorageView: View {
    @ObservedObject var storage: ApplicationStorageModel
    @ObservedObject var pets: BuddyPetsController
    @ObservedObject var updates: UpdateManager
    var minimumHeight:CGFloat = 0
    var body: some View {
        GeneralAlignedSection(L("应用数据", "Application data"),symbol:"internaldrive",minimumHeight:minimumHeight) {
            VStack(alignment:.leading,spacing:16) {
                VStack(alignment:.leading,spacing:6) {
                    Text(storage.snapshot.map { size($0.totalBytes) } ?? "—")
                        .font(.system(size:28,weight:.semibold)).monospacedDigit()
                        .accessibilityLabel(L("本机占用：", "Local storage: ")+(storage.snapshot.map {size($0.totalBytes)} ?? "—"))
                    Text(L("保留个人数据与用量历史。", "Keep personal data and usage history."))
                        .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                VStack(spacing:0) {
                    row(L("应用本体", "Application"),bytes:storage.snapshot?.applicationBytes)
                    Divider()
                    row(L("设置与消息记录", "Settings and message history"),bytes:storage.snapshot?.dataBytes)
                    Divider()
                    row(L("宠物目录缓存", "Pet catalog cache"),bytes:storage.snapshot?.cacheBytes)
                    Divider()
                    row(L("标签缓存", "Tag cache"),bytes:storage.snapshot?.tagBytes)
                    Divider()
                    row(L("额度历史", "Quota history"),bytes:storage.snapshot?.forecastBytes)
                }
                Spacer(minLength:0)
                HStack(spacing:12) {
                    Button { storage.clear(using:pets) } label: {
                        Label(storage.clearing ? L("清理中…", "Clearing…") : L("清理缓存", "Clear cache"),systemImage:"trash")
                            .font(.system(size:13,weight:.semibold)).padding(.horizontal,9).padding(.vertical,7)
                    }.buttonStyle(.bordered).disabled(storage.clearing || storage.loading || pets.modifyingLocalLibrary || updates.installing)
                    Spacer(minLength:8)
                    if storage.loading || storage.clearing { ProgressView().controlSize(.small) }
                    Button { storage.refresh() } label: {
                        Image(systemName:"arrow.clockwise").frame(width:32,height:32).contentShape(Rectangle())
                    }.buttonStyle(.bordered).disabled(storage.loading || storage.clearing)
                        .accessibilityLabel(L("刷新数据大小", "Refresh data sizes"))
                        .help(L("刷新数据大小", "Refresh data sizes"))
                }
                if let message=storage.message {
                    Text(message).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
        }
    }
    private func row(_ title: String,bytes: Int64?) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:20) {
            Text(title).font(.system(size:13)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                .frame(maxWidth:.infinity,alignment:.leading)
            Text(bytes.map(size) ?? "—").font(.system(size:13)).monospacedDigit().fixedSize()
        }.frame(minHeight:42)
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file) }
}
