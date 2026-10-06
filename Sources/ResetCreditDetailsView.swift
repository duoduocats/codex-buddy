import SwiftUI

struct ResetCreditDetailsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text(L("重置明细", "Reset details"))
                    .font(.system(size:13,weight:.semibold))
                Spacer()
                if model.resetDetailsOnlySoonest { Text(L("未来 \(model.resetExpiryWindowDays) 天内到期", "Expiring within \(model.resetExpiryWindowDays) days")).font(.system(size:10)).foregroundStyle(.secondary) }
                if model.resetCreditsRefreshing { ProgressView().controlSize(.mini) }
            }
            if let details = model.resetCreditDetails {
                let groups = model.resetDetailsOnlySoonest ? details.groupsExpiring(now:model.now,withinDays:model.resetExpiryWindowDays) : details.groups(now:model.now,onlySoonest:false)
                ForEach(groups) { group in
                    HStack(alignment:.top,spacing:12) {
                        Text(L("\(group.count) 次", "\(group.count) \(group.count == 1 ? "reset" : "resets")"))
                            .font(.system(size:12,weight:.medium)).monospacedDigit()
                        Spacer(minLength:8)
                        if let expiry = group.expiresAt {
                            VStack(alignment:.trailing,spacing:3) {
                                Text(expiryText(expiry)).monospacedDigit().multilineTextAlignment(.trailing)
                                Text(L("还有 \(remaining(expiry))", "In \(remaining(expiry))"))
                                    .font(.system(size:10)).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(group.expiryKnown ? L("无到期限制", "Does not expire") : L("到期时间未提供", "Expiry unavailable"))
                                .foregroundStyle(.secondary)
                        }
                    }.font(.system(size:11))
                }
                if groups.isEmpty {
                    let complete = details.credits.count == details.availableCount && details.credits.allSatisfy(\.expiryKnown)
                    Text(details.availableCount == 0 ? L("暂无可用重置", "No resets available")
                        : model.resetDetailsOnlySoonest && complete
                        ? L("未来 \(model.resetExpiryWindowDays) 天内没有到期的重置", "No resets expire within \(model.resetExpiryWindowDays) days")
                        : L("暂未提供完整到期明细", "Complete expiry details are unavailable"))
                        .font(.system(size:11)).foregroundStyle(.secondary)
                }
                if details.credits.count < details.availableCount {
                    Text(L("部分重置暂未提供明细。", "Details are unavailable for some resets."))
                        .font(.system(size:10)).foregroundStyle(.secondary)
                }
            } else if model.resetCreditsError == nil {
                Text(model.resetCreditsRefreshing ? L("正在获取重置明细…", "Loading reset details…") : L("暂未提供到期明细", "Expiry details are unavailable"))
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
            if let message = model.resetCreditsError {
                Text(message).font(.system(size:10)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func expiryText(_ date:Date) -> String {
        let formatter = DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium;formatter.timeStyle = .short
        return L("\(formatter.string(from:date)) 到期", "Expires \(formatter.string(from:date))")
    }
    private func remaining(_ date:Date) -> String {
        LimitWindow(usedPercent:0,windowDurationMins:nil,resetsAt:date.timeIntervalSince1970).detailCountdown(now:model.now)
    }
}
