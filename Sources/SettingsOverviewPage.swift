import AppKit
import SwiftUI

struct SettingsOverviewPage: View {
    @ObservedObject var model: AppModel
    let preview: UsagePreviewModel
    let previewHighlight: UsagePreviewHighlight
    var previewFramesChanged: ([UsagePreviewAnchor: CGRect]) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        overview.onAppear { preview.apply(UsagePreviewStyle(model)) }
            .onChange(of:UsagePreviewStyle(model)) { preview.apply($0) }
    }
    private var overview: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:32) {
                    Group {
                        if geometry.size.width >= 1066 {
                            UsageOverviewColumns {
                                menuControls.frame(width:270)
                                previewColumn
                                panelControls.frame(width:300)
                            }
                        } else {
                            HStack(alignment:UsagePreviewAlignment.menuTop,spacing:36) {
                                VStack(spacing:22) { menuControls;panelControls }.frame(width:270)
                                    .alignmentGuide(UsagePreviewAlignment.menuTop) { $0[.top] }
                                previewColumn
                            }
                        }
                    }.frame(maxWidth:.infinity,minHeight:max(0,geometry.size.height-40),alignment:.center)
                        .environment(\.usagePreviewEnabled,true)
                        .overlayPreferenceValue(UsagePreviewAnchors.self) { anchors in
                            GeometryReader { proxy in
                                UsagePreviewLines(frames:anchors.mapValues { proxy[$0] },highlight:previewHighlight,framesChanged:previewFramesChanged)
                            }
                        }
                }.padding(.horizontal,28).padding(.vertical,20).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
    private var previewColumn: some View {
        VStack(spacing:16) {
            Text(L("模拟数据预览", "Sample data preview")).font(.system(size:12)).foregroundStyle(.secondary)
                .frame(maxWidth:.infinity,alignment:.leading)
            UsagePreviewCanvas(model:preview.model,updates:preview.updates)
        }.frame(width:380)
    }
    private var menuControls: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("顶栏", "Menu bar")).font(.system(size:18,weight:.semibold))
            control(.theme) {
                VStack(alignment:.leading,spacing:18) {
                    Text(L("顶栏主题", "Menu bar theme")).font(.system(size:14,weight:.semibold))
                    HStack(spacing:4) {
                        ForEach(MenuBarTheme.allCases) { theme in
                            Button { model.menuBarTheme = theme } label: {
                                VStack(spacing:8) {
                                    Image(nsImage:DuoDrawing.image(size:NSSize(width:32,height:26),
                                        window:LimitWindow(usedPercent:0,windowDurationMins:nil,resetsAt:nil),
                                        credits:4,now:preview.model.now,menu:true,dark:model.menuBarTheme == theme || colorScheme == .dark,
                                        menuTheme:theme,showsLabel:false)).frame(width:32,height:26).accessibilityHidden(true)
                                    Text(theme.title).font(.system(size:13,weight:.medium))
                                }.frame(maxWidth:.infinity).frame(height:72)
                                    .foregroundStyle(model.menuBarTheme == theme ? Color.white : Color.primary)
                                    .background(model.menuBarTheme == theme ? Color.blue : Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:8))
                                    .overlay(RoundedRectangle(cornerRadius:8).stroke(model.menuBarTheme == theme ? Color.blue.opacity(0.9) : .clear,lineWidth:1))
                                    .contentShape(RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.plain).accessibilityLabel(theme.title)
                                .accessibilityAddTraits(model.menuBarTheme == theme ? .isSelected : [])
                        }
                    }
                    HStack(spacing:12) {
                        ForEach(MenuBarTheme.allCases) { theme in
                            VStack(spacing:9) {
                                Image(nsImage:DuoDrawing.image(size:NSSize(width:64,height:52),
                                    window:LimitWindow(usedPercent:32,windowDurationMins:10080,resetsAt:preview.model.now.addingTimeInterval(4*86_400).timeIntervalSince1970),
                                    credits:3,now:preview.model.now,menu:true,dark:colorScheme == .dark,menuTheme:theme))
                                    .frame(width:64,height:52).accessibilityHidden(true)
                                Text(theme == .ring ? "Ring" : "DuoDuoCat").font(.system(size:11))
                            }.frame(maxWidth:.infinity)
                        }
                    }.padding(.vertical,8)
                }
            }
            control(.display) {
                VStack(alignment:.leading,spacing:16) {
                    Text(L("显示内容", "Display")).font(.system(size:14,weight:.semibold))
                    SettingsSegments(labels:[L("时间", "Time"),L("百分比", "Percentage")],selection:Binding(
                        get:{model.menuShowsPercentage ? 1 : 0},set:{model.menuShowsPercentage = $0 == 1}),
                        accessibilityLabel:L("显示内容", "Display")).frame(height:30)
                }
            }
        }.padding(16).background(Color.primary.opacity(0.02),in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(Color.primary.opacity(0.09),lineWidth:0.7))
            .usagePreviewAnchor(.layout(.menuControls))
    }
    private var panelControls: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("展开面板", "Panel")).font(.system(size:18,weight:.semibold))
            control(.messages) {
                VStack(spacing:14) {
                    overviewToggle(L("消息通知", "Messages"),selection:Binding(
                        get:{model.reminders.messagesEnabled},set:{model.reminders.setMessagesEnabled($0)}))
                    Divider()
                    VStack(spacing:12) {
                        overviewToggle(L("重置提醒", "Reset reminders"),selection:Binding(
                            get:{model.reminders.resetMessagesEnabled},set:{model.reminders.setResetMessagesEnabled($0)}))
                        overviewToggle(L("活动消息", "Activity messages"),selection:Binding(
                            get:{model.reminders.activityMessagesEnabled},set:{model.reminders.setActivityMessagesEnabled($0)}))
                    }.padding(.leading,14).disabled(!model.reminders.messagesEnabled)
                }
            }
            control(.resets) {
                VStack(alignment:.leading,spacing:16) {
                    overviewToggle(L("重置明细", "Reset details"),selection:$model.showResetDetails)
                    Divider()
                    Text(L("显示范围", "Show")).font(.system(size:12)).foregroundStyle(.secondary)
                    SettingsSegments(labels:[L("全部", "All"),L("最近到期", "Upcoming")],selection:Binding(
                        get:{model.resetDetailsOnlySoonest ? 1 : 0},set:{model.resetDetailsOnlySoonest = $0 == 1}),
                        accessibilityLabel:L("重置明细展示范围", "Reset detail range")).frame(height:30).disabled(!model.showResetDetails)
                    if model.resetDetailsOnlySoonest && model.showResetDetails {
                        Picker(L("到期范围", "Expiry window"),selection:$model.resetExpiryWindowDays) {
                            ForEach([1,3,7,14,30],id:\.self) { days in Text(L("未来 \(days) 天", "Next \(days) days")).tag(days) }
                        }.pickerStyle(.menu)
                    }
                }
            }
            control(.chart) { overviewToggle(L("每日 Token 用量", "Daily token usage"),selection:$model.showDailyTokenUsage) }
            control(.sharing) { overviewToggle(L("分享按钮", "Sharing button"),selection:$model.showUsageShareButton).disabled(!model.showDailyTokenUsage) }
        }.padding(16).background(Color.primary.opacity(0.02),in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(Color.primary.opacity(0.09),lineWidth:0.7))
            .usagePreviewAnchor(.layout(.panelControls))
    }
    private func overviewToggle(_ title: String,selection: Binding<Bool>) -> some View {
        HStack(spacing:12) {
            Text(title).font(.system(size:14,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                .frame(maxWidth:.infinity,alignment:.leading)
            Toggle(title,isOn:selection).labelsHidden().toggleStyle(OverviewSwitchStyle(title:title))
        }.frame(minHeight:32)
    }
    private func control<Content: View>(_ part: UsagePreviewPart,@ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth:.infinity,alignment:.leading).padding(14)
            .background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.085),lineWidth:0.6))
            .usagePreviewAnchor(.control(part)).onHover { previewHighlight.setHovered($0 ? part : nil) }
    }
}

private struct UsageOverviewColumns: Layout {
    private let menuWidth: CGFloat = 270
    private let previewWidth: CGFloat = 380
    private let panelWidth: CGFloat = 300
    private let spacing: CGFloat = 30
    private struct Placement {
        let size: CGSize
        let menuY: CGFloat
        let panelY: CGFloat
        let top: CGFloat
    }
    private func measure(_ proposal: ProposedViewSize,subviews: Subviews) -> Placement? {
        guard subviews.count == 3 else { return nil }
        let menu = subviews[0].sizeThatFits(.init(width:menuWidth,height:nil))
        let preview = subviews[1].dimensions(in:.init(width:previewWidth,height:nil))
        let panel = subviews[2].sizeThatFits(.init(width:panelWidth,height:nil))
        let menuY = preview[UsagePreviewAlignment.menuTop]
        let panelY = preview[UsagePreviewAlignment.panelCenter] - panel.height / 2
        let top = min(0,min(menuY,panelY))
        let bottom = max(preview.height,max(menuY + menu.height,panelY + panel.height))
        let width = menuWidth + previewWidth + panelWidth + 2 * spacing
        let offeredWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? width
        return .init(size:.init(width:max(width,offeredWidth),height:bottom - top),
                     menuY:menuY,panelY:panelY,top:top)
    }
    func sizeThatFits(proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) -> CGSize {
        measure(proposal,subviews:subviews)?.size ?? .zero
    }
    func placeSubviews(in bounds: CGRect,proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) {
        guard let value = measure(proposal,subviews:subviews) else { return }
        let width = menuWidth + previewWidth + panelWidth + 2 * spacing
        let x = bounds.minX + (bounds.width - width) / 2
        let y = bounds.minY - value.top
        subviews[0].place(at:.init(x:x,y:y + value.menuY),anchor:.topLeading,
                          proposal:.init(width:menuWidth,height:nil))
        subviews[1].place(at:.init(x:x + menuWidth + spacing,y:y),anchor:.topLeading,
                          proposal:.init(width:previewWidth,height:nil))
        subviews[2].place(at:.init(x:x + menuWidth + previewWidth + 2 * spacing,y:y + value.panelY),anchor:.topLeading,
                          proposal:.init(width:panelWidth,height:nil))
    }
}
