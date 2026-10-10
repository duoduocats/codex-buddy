import SwiftUI

struct PetUninstallConsent:View {
    let name:String
    let cancel:() -> Void
    let confirm:() -> Void
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:14) {
                PetStoreMark(size:40)
                VStack(alignment:.leading,spacing:5) {
                    Text(L("卸载本机主题", "Uninstall local theme")).font(.system(size:21,weight:.bold))
                    Text(name).font(.system(size:14,weight:.medium))
                }
            }
            Text(L("主题包将整包移到废纸篓，可以从废纸篓恢复。收藏会保留。", "The theme package moves to Trash and can be restored from there. Favorites are kept."))
                .font(.system(size:13)).fixedSize(horizontal:false,vertical:true)
            Text(L("如果正在使用此主题，请先在 Codex 设置 → 虚拟宠物中切换到其他主题。", "If you are using this theme, first switch to another pet in Codex Settings → Pets."))
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Spacer()
                Button(L("取消", "Cancel"),action:cancel).keyboardShortcut(.cancelAction)
                Button(L("移到废纸篓", "Move to Trash"),role:.destructive,action:confirm).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width:450)
    }
}

struct PetSettingsGuide:View {
    let openSettings:() -> Void
    let close:() -> Void
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:12) {
                PetStoreMark(size:36)
                Text(L("Codex 虚拟宠物设置", "Codex Pets settings")).font(.system(size:20,weight:.bold))
                Spacer(minLength:8)
                Button(action:close) { Image(systemName:"xmark").font(.system(size:12,weight:.semibold)).frame(width:28,height:28) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("关闭指引", "Close guide")).accessibilityLabel(L("关闭指引", "Close guide"))
            }
            VStack(alignment:.leading,spacing:14) {
                Text(L("1. 打开 Codex 设置", "1. Open Codex settings")).fontWeight(.semibold)
                Text(L("2. 手动点击左侧“虚拟宠物”", "2. Choose Pets in the sidebar")).fontWeight(.semibold)
                Text(L("3. 刷新列表，选择本机主题或内置主题", "3. Refresh, then choose a local or built-in theme")).fontWeight(.semibold)
            }.font(.system(size:13))
            Text(L("恢复默认时选择内置主题。卸载前先切换主题，再到本商店“已安装”页操作。", "Select a built-in theme to restore the default. Switch pets before uninstalling from this store’s Installed page."))
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text(L("当前桌面端链接只打开设置首页，仍需手动点击虚拟宠物页签。", "The current desktop link opens the Settings home; choose the Pets tab manually."))
                .font(.system(size:11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("关闭", "Close"),action:close).keyboardShortcut(.cancelAction)
                Button(L("打开 Codex 设置", "Open Codex settings"),action:openSettings).buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width:450).fixedSize(horizontal:false,vertical:true)
    }
}
