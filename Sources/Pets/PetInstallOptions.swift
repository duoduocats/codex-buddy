import SwiftUI

struct PetInstallOptions:View {
    let installed:Bool
    let canReinstall:Bool
    let canSend:Bool
    let canCopy:Bool
    let showGuide:() -> Void
    let reinstall:() -> Void
    let sendToCodex:() -> Void
    let copyLink:() -> Void
    @State private var otherMethods=CommandLine.arguments.contains("--ui-install-options-expanded")
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text(L("安装与使用", "Install and use")).font(.system(size:14,weight:.semibold))
            PetInstallOptionRow(symbol:"questionmark.circle",title:L("安装后怎么使用？", "How do I use this pet?"),
                detail:L("查看在 Codex 中选择宠物的步骤。", "See how to choose your pet in Codex."),action:showGuide)
            if installed {
                PetInstallOptionRow(symbol:"arrow.clockwise",title:L("重新安装这个宠物…", "Reinstall this pet…"),
                    detail:L("替换已安装的文件，操作前会再次确认。", "Replace its installed files after confirming."),action:reinstall).disabled(!canReinstall)
            }
            Divider()
            DisclosureGroup(L("其他安装方式", "Other ways to install"),isExpanded:$otherMethods) {
                VStack(alignment:.leading,spacing:6) {
                    PetInstallOptionRow(symbol:"arrow.up.forward.app",title:L("在 Codex 中确认安装", "Confirm installation in Codex"),
                        detail:L("打开 Codex，由它显示安装确认窗口。", "Open Codex to request an installation window."),action:sendToCodex).disabled(!canSend)
                    PetInstallOptionRow(symbol:"link",title:L("复制安装链接", "Copy installation link"),
                        detail:L("复制后可粘贴到浏览器地址栏打开。", "Paste the link into your browser’s address bar."),action:copyLink).disabled(!canCopy)
                }.padding(.top,8)
            }.font(.system(size:12))
            if otherMethods {
                Text(installed ? L("这些方式需要 Codex 支持安装确认窗口。没有弹窗时，请用上面的“重新安装这个宠物”。", "These methods need Codex to support an installation window. If none appears, use Reinstall this pet above.") : L("这些方式需要 Codex 支持安装确认窗口。没有弹窗时，请用详情页的“安装到本机”。", "These methods need Codex to support an installation window. If none appears, use Install locally on the theme page."))
                    .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).padding(.horizontal,8)
            }
        }.padding(16).frame(width:310).fixedSize(horizontal:false,vertical:true).background(Color(nsColor:.controlBackgroundColor))
    }
}

private struct PetInstallOptionRow:View {
    let symbol:String
    let title:String
    let detail:String
    let action:() -> Void
    @State private var hovering=false
    var body:some View {
        Button(action:action) {
            HStack(alignment:.top,spacing:10) {
                Image(systemName:symbol).font(.system(size:14)).frame(width:18).padding(.top,2)
                VStack(alignment:.leading,spacing:4) {
                    Text(title).font(.system(size:12,weight:.medium))
                    Text(detail).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.padding(8).contentShape(RoundedRectangle(cornerRadius:6))
        }.buttonStyle(.plain).background(hovering ? Color.primary.opacity(0.05) : .clear,in:RoundedRectangle(cornerRadius:6))
            .onHover { hovering=$0 }.accessibilityLabel(title).accessibilityHint(detail)
    }
}
