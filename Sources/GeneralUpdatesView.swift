import SwiftUI

struct GeneralPreferenceRow: View {
    let title: String
    let detail: String
    var selection: Binding<Bool>
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:12) {
                Text(title).font(.system(size:15,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                    .frame(maxWidth:.infinity,alignment:.leading)
                Toggle(title,isOn:selection).labelsHidden().toggleStyle(OverviewSwitchStyle(title:title)).help(detail)
            }
            Text(detail).font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
        }
    }
}

struct GeneralUpdatesView: View {
    @ObservedObject var updates: UpdateManager
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            VStack(alignment:.leading,spacing:12) {
                Text(L("当前版本", "Installed version")).font(.system(size:12)).foregroundStyle(.secondary)
                HStack(spacing:24) {
                    Text(updates.currentVersion).font(.system(size:36,weight:.semibold)).monospacedDigit()
                    Button { updates.check(manual:true) } label: {
                        Text(updates.checking ? L("检查中…", "Checking…") : L("检查更新", "Check for updates"))
                            .font(.system(size:13,weight:.semibold)).foregroundStyle(.white)
                            .padding(.horizontal,18).padding(.vertical,10)
                            .background(Color.blue.opacity(updates.checking || updates.installing ? 0.45 : 1),in:RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain).disabled(updates.checking || updates.installing)
                    Spacer(minLength:0)
                }
            }
            Divider()
            GeneralPreferenceRow(title:L("接收 Beta 更新", "Receive Beta updates"),
                detail:L("开启后检查正式版和 Beta 测试版。", "Check for stable and Beta releases when enabled."),
                selection:Binding(get:{updates.includesBeta},set:{updates.setIncludesBeta($0)})).disabled(updates.installing)
            if let release = updates.available {
                Divider()
                VStack(alignment:.leading,spacing:10) {
                    Text(L("新版本 \(release.tagName)", "Update \(release.tagName)")).font(.system(size:14,weight:.semibold))
                    HStack(spacing:18) {
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
