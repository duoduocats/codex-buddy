import AppKit
import SwiftUI

struct GeneralAlignedSection<Content: View>: View {
    let title: String
    let symbol: String
    let trailingText: String?
    let content: Content
    init(_ title: String,symbol: String,trailingText: String? = nil,@ViewBuilder content: () -> Content) {
        self.title=title;self.symbol=symbol;self.trailingText=trailingText;self.content=content()
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:10) {
                Image(systemName:symbol).font(.system(size:19,weight:.regular)).foregroundStyle(Color.secondary)
                    .frame(width:23).accessibilityHidden(true)
                Text(title).font(.system(size:17,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength:12)
                if let trailingText {
                    Text(trailingText).font(.system(size:24,weight:.semibold)).monospacedDigit().fixedSize()
                        .accessibilityLabel(L("本机占用：", "Local storage: ")+trailingText)
                }
            }
            Divider()
            content
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
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

struct GeneralAlignedUpdatesView: View {
    @ObservedObject var updates: UpdateManager
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            HStack(spacing:20) {
                VStack(alignment:.leading,spacing:5) {
                    Text(L("当前版本", "Installed version")).font(.system(size:12)).foregroundStyle(.secondary)
                    Text(updates.currentVersion).font(.system(size:24,weight:.semibold)).monospacedDigit()
                        .fixedSize(horizontal:false,vertical:true)
                }.frame(maxWidth:.infinity,alignment:.leading)
                Button { updates.check(manual:true) } label: {
                    Text(updates.checking ? L("检查中…", "Checking…") : L("检查更新", "Check for updates"))
                        .font(.system(size:13,weight:.semibold)).foregroundStyle(.white).fixedSize()
                        .padding(.horizontal,18).padding(.vertical,10)
                        .background(Color.blue.opacity(updates.checking || updates.installing ? 0.45 : 1),in:RoundedRectangle(cornerRadius:8))
                        .contentShape(RoundedRectangle(cornerRadius:8))
                }.buttonStyle(.plain).disabled(updates.checking || updates.installing)
            }
            Divider()
            GeneralAlignedPreferenceRow(title:L("接收 Beta 更新", "Receive Beta updates"),
                detail:L("开启后检查正式版和 Beta 测试版。", "Check for stable and Beta releases when enabled."),
                selection:Binding(get:{updates.includesBeta},set:{updates.setIncludesBeta($0)})).disabled(updates.installing)
            if let release = updates.available {
                Divider()
                VStack(alignment:.leading,spacing:10) {
                    Text(L("新版本 \(release.tagName)", "Update \(release.tagName)")).font(.system(size:14,weight:.semibold))
                        .fixedSize(horizontal:false,vertical:true)
                    HStack(spacing:18) {
                        Spacer(minLength:0)
                        Button(L("更新说明", "Release notes")) { updates.openRelease() }.buttonStyle(.link)
                        Button(updates.installing ? L("更新中…", "Updating…") : updates.installFailed ? L("重试更新", "Retry update") : L("下载更新", "Download update")) { updates.installAvailable() }
                            .buttonStyle(.borderedProminent).disabled(updates.installing)
                    }
                }
            }
            if let message = updates.detailMessage {
                Text(message).font(.system(size:12)).foregroundStyle(updates.installFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
            if updates.lastSuccessfulCheckAt != nil || updates.nextRetryAt != nil { Divider() }
            if let checked = updates.lastSuccessfulCheckAt {
                Text(L("最近成功检查：", "Last successful check: ") + timestamp(checked)).font(.system(size:11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
            if let retry = updates.nextRetryAt {
                Text(L("下次重试：", "Next retry: ") + timestamp(retry)).font(.system(size:11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    private func timestamp(_ date: Date) -> String {
        let formatter=DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium;formatter.timeStyle = .short
        return formatter.string(from:date)+" "+(TimeZone.autoupdatingCurrent.abbreviation(for:date) ?? TimeZone.autoupdatingCurrent.identifier)
    }
}

struct GeneralAlignedStorageView: View {
    @ObservedObject var storage: ApplicationStorageModel
    @ObservedObject var pets: BuddyPetsController
    @ObservedObject var updates: UpdateManager
    var body: some View {
        GeneralAlignedSection(L("应用数据", "Application data"),symbol:"internaldrive",
            trailingText:storage.snapshot.map { size($0.totalBytes) } ?? "—") {
            VStack(alignment:.leading,spacing:20) {
                row(L("应用本体", "Application"),bytes:storage.snapshot?.applicationBytes)
                Divider()
                row(L("设置与消息记录", "Settings and message history"),bytes:storage.snapshot?.dataBytes)
                Divider()
                VStack(alignment:.leading,spacing:12) {
                    row(L("宠物目录缓存", "Pet catalog cache"),bytes:storage.snapshot?.cacheBytes)
                row(L("标签缓存", "Tag cache"),bytes:storage.snapshot?.tagBytes)
                    row(L("额度历史", "Quota history"),bytes:storage.snapshot?.forecastBytes)
                    HStack(spacing:12) {
                        Text(L("保留个人数据与用量历史。", "Keep personal data and usage history."))
                            .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            .frame(maxWidth:.infinity,alignment:.leading)
                        if storage.loading || storage.clearing { ProgressView().controlSize(.small) }
                        Button {
                            storage.clear(using:pets)
                        } label: {
                            Label(storage.clearing ? L("清理中…", "Clearing…") : L("清理缓存", "Clear cache"),systemImage:"trash")
                                .font(.system(size:13,weight:.semibold)).padding(.horizontal,14).padding(.vertical,9)
                                .contentShape(RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.bordered).disabled(storage.clearing || storage.loading || pets.modifyingLocalLibrary || updates.installing)
                        Button { storage.refresh() } label: {
                            Image(systemName:"arrow.clockwise").frame(width:30,height:30).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(storage.loading || storage.clearing)
                            .accessibilityLabel(L("刷新数据大小", "Refresh data sizes"))
                            .help(L("刷新数据大小", "Refresh data sizes"))
                    }
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
        }
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file) }
}
