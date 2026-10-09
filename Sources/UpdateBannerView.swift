import SwiftUI

/// A compact update action beside Settings; details stay in Settings.
struct PanelUpdateButton: View {
    @ObservedObject var updates: UpdateManager = .shared
    var body: some View {
        if updates.showsPanelUpdate, let release = updates.available {
            Button { updates.installAvailable() } label: {
                ZStack {
                    Circle().fill(Color.accentColor)
                    if updates.installing {
                        ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.75)
                    } else {
                        Image(systemName:updates.installFailed ? "arrow.clockwise" : "arrow.down")
                            .font(.system(size:11,weight:.semibold)).foregroundStyle(.white)
                    }
                }.frame(width:24,height:24)
            }.buttonStyle(.plain).disabled(updates.installing)
                .help(updates.installing ? updates.message : updates.installFailed ? updates.message : L("下载更新 \(release.tagName)", "Download update \(release.tagName)"))
                .accessibilityLabel(updates.installing ? L("正在更新", "Updating") : updates.installFailed ? L("重试更新", "Retry update") : L("下载更新", "Download update"))
        }
    }
}

struct SettingsUpdateSection: View {
    @ObservedObject var updates: UpdateManager = .shared
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            SettingsToggleRow(title:L("接收 Beta 更新", "Receive Beta updates"),
                detail:L("开启后检查正式版和 Beta 测试版。", "Check for stable and Beta releases when enabled."),
                selection:Binding(get:{updates.includesBeta},set:{updates.setIncludesBeta($0)}))
                .disabled(updates.installing)
            HStack {
                Text(L("当前版本 \(updates.currentVersion)", "Installed version \(updates.currentVersion)"))
                    .font(.system(size:12)).foregroundStyle(.secondary)
                Spacer(minLength:12)
                Button(updates.checking ? L("检查中…", "Checking…") : L("检查更新", "Check for updates")) { updates.check(manual:true) }
                    .controlSize(.small).disabled(updates.checking || updates.installing)
            }
            if let release = updates.available {
                HStack(alignment:.center,spacing:16) {
                    VStack(alignment:.leading,spacing:5) {
                        Text(L("新版本 \(release.tagName)", "Update \(release.tagName)"))
                            .font(.system(size:13,weight:.semibold))
                        Button(L("更新说明", "Release notes")) { updates.openRelease() }
                            .font(.system(size:11)).buttonStyle(.link)
                    }
                    Spacer(minLength:0)
                    Button(updates.installing ? L("更新中…", "Updating…") : updates.installFailed ? L("重试更新", "Retry update") : L("下载更新", "Download update")) { updates.installAvailable() }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(updates.installing)
                }
            }
            if let message = updates.detailMessage {
                Text(message).font(.system(size:11))
                    .foregroundStyle(updates.installFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
            if let checked = updates.lastSuccessfulCheckAt {
                Text(L("最近成功检查：", "Last successful check: ") + Self.timestamp(checked))
                    .font(.system(size:11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
            if let retry = updates.nextRetryAt {
                Text(L("下次重试：", "Next retry: ") + Self.timestamp(retry))
                    .font(.system(size:11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
        }.padding(.vertical,4)
    }
    private static func timestamp(_ date: Date) -> String {
        let formatter=DateFormatter();formatter.dateStyle = .medium;formatter.timeStyle = .short
        return formatter.string(from:date) + " " + (TimeZone.current.abbreviation(for:date) ?? TimeZone.current.identifier)
    }
}
