import SwiftUI
import AppKit

struct ApplicationStorageView: View {
    @ObservedObject var storage: ApplicationStorageModel
    @ObservedObject var pets: BuddyPetsController
    @ObservedObject var updates: UpdateManager
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.firstTextBaseline) {
                Text(L("本机占用", "Local storage")).font(.system(size:14,weight:.semibold))
                Spacer()
                Text(storage.snapshot.map { size($0.totalBytes) } ?? "—").font(.system(size:24,weight:.semibold)).monospacedDigit()
            }
            Divider()
            row(L("应用本体", "Application"),bytes:storage.snapshot?.applicationBytes)
            row(L("设置与消息记录", "Settings and message history"),bytes:storage.snapshot?.dataBytes)
            row(L("宠物目录缓存", "Pet catalog cache"),bytes:storage.snapshot?.cacheBytes)
            row(L("用量预测记录", "Usage prediction history"),bytes:storage.snapshot?.forecastBytes)
            HStack(spacing:16) {
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
                if storage.loading || storage.clearing { ProgressView().controlSize(.small) }
                Spacer(minLength:0)
                if let message=storage.message { Text(message).font(.system(size:12)).foregroundStyle(.secondary) }
            }
            Text(L("清理后会按需重新下载，并重新记录用量预测。设置、收藏、消息记录与已安装宠物会保留。", "Cached data downloads again when needed and prediction history starts fresh. Settings, favorites, message history and installed pets are kept."))
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func row(_ title: String,bytes: Int64?) -> some View {
        HStack {
            Text(title).font(.system(size:13)).foregroundStyle(.secondary)
            Spacer()
            Text(bytes.map(size) ?? "—").font(.system(size:13)).monospacedDigit()
        }
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file) }
}
