import SwiftUI

// Confirmation freezes the prepared package and target before any filesystem mutation.
struct PetLocalInstallConsent:View {
    let name:String
    let author:String
    let license:String
    let source:String
    let destination:String
    let replacing:Bool
    let cancel:() -> Void
    let confirm:() -> Void
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:14) {
                PetStoreMark(size:44)
                VStack(alignment:.leading,spacing:5) {
                    Text(replacing ? L("替换本机副本", "Replace local copy") : L("安装到本机", "Install locally"))
                        .font(.system(size:21,weight:.bold))
                    Text(name).font(.system(size:14,weight:.medium))
                }
            }
            Text(L("保存校验过的主题文件，然后在 Codex 的宠物设置中选择使用。", "Save the verified theme files, then choose the pet in Codex settings."))
                .font(.system(size:13)).fixedSize(horizontal:false,vertical:true)
            VStack(alignment:.leading,spacing:9) {
                Text(L("署名：", "Credit: ")+author)
                Text(L("来源：", "Source: ")+source)
                ScrollView { Text(L("授权：", "License: ")+license).frame(maxWidth:.infinity,alignment:.leading) }
                    .frame(maxHeight:65)
                Text(L("保存位置：", "Destination: ")+destination).font(.system(size:11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }.font(.system(size:12)).textSelection(.enabled)
            if replacing {
                Text(L("替换会保留上一份副本，以便失败时恢复。", "The previous copy is retained for recovery if replacement fails."))
                    .font(.system(size:12)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("取消", "Cancel"),action:cancel).keyboardShortcut(.cancelAction)
                Button(replacing ? L("替换", "Replace") : L("安装", "Install"),action:confirm)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width:480)
    }
}
