import SwiftUI

struct CloudInstalledPetList:View {
    @ObservedObject var library:PetCloudLibrary
    let search:String
    var body:some View {
        let filtered=library.pets.filter {search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)}
        return LazyVStack(alignment:.leading,spacing:0) {
            HStack {
                Text(L("云端", "Cloud")).font(.system(size:13,weight:.semibold)).foregroundStyle(.secondary)
                Text("\(filtered.count)").font(.system(size:12)).foregroundStyle(.secondary);Spacer()
                if library.loading || library.deletingPetID != nil {ProgressView().controlSize(.small).accessibilityLabel(L("读取云端宠物", "Loading cloud pets"))}
            }.padding(.bottom,8)
            if library.unavailable {
                HStack {Text(L("暂时无法更新云端宠物", "Could not update cloud pets")).font(.system(size:13)).foregroundStyle(.secondary);Spacer()
                    Button(L("重试", "Retry")) {library.refresh(force:true)}.buttonStyle(.link)
                }.padding(.vertical,12)
            }
            if let message=library.deletionMessage {
                Text(message).font(.system(size:13)).foregroundStyle(library.deletionFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal:false,vertical:true).padding(.vertical,10)
            }
            ForEach(filtered) {pet in
                HStack(spacing:18) {
                    CloudPetPreviewIcon(library:library,pet:pet)
                    VStack(alignment:.leading,spacing:5) {Text(pet.name).font(.system(size:15,weight:.semibold));Label(L("Codex 云端", "Codex cloud"),systemImage:"cloud").font(.system(size:12)).foregroundStyle(.secondary)}
                    Spacer()
                    Button(role:.destructive) {library.requestDeletion(pet)} label: {
                        Label(L("删除", "Delete"),systemImage:"trash").font(.system(size:13)).padding(.horizontal,4)
                    }.buttonStyle(.bordered).disabled(library.loading || library.deletingPetID != nil)
                        .accessibilityLabel(L("删除云端宠物 ", "Delete cloud pet ")+pet.name)
                        .accessibilityIdentifier("cloud-pet-delete-"+pet.id)
                }.padding(.vertical,10);Divider()
            }
            if library.pets.isEmpty && !library.loading && !library.unavailable {Text(L("暂无云端宠物", "No cloud pets")).font(.system(size:13)).foregroundStyle(.secondary).padding(.vertical,12)}
        }.sheet(item:$library.deletionRequest) { request in
            VStack(alignment:.leading,spacing:20) {
                Label(L("删除“\(request.pet.name)”？", "Delete “\(request.pet.name)”?"),systemImage:"trash")
                    .font(.system(size:20,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                Text(L("此操作会永久删除云端宠物及其上传素材，无法撤销。本机安装的宠物文件不受影响。", "This permanently deletes the cloud pet and its uploaded sprite sheet. It cannot be undone. Locally installed pet files are kept."))
                    .font(.system(size:14)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                HStack {
                    Spacer()
                    Button(L("取消", "Cancel")) {library.cancelDeletion()}.keyboardShortcut(.cancelAction)
                    Button(L("从云端永久删除", "Delete permanently"),role:.destructive) {library.confirmDeletion()}
                        .buttonStyle(.borderedProminent).tint(.red).accessibilityIdentifier("cloud-pet-delete-confirm")
                }
            }.padding(26).frame(width:440).interactiveDismissDisabled(library.deletingPetID != nil)
        }
    }
}

private struct CloudPetPreviewIcon:View {
    @ObservedObject var library:PetCloudLibrary
    let pet:CloudInstalledPet
    @State private var visibilityToken=UUID()
    var body:some View {
        Button {library.preview(pet)} label: {
            ZStack {
                if let image=library.image(for:pet) {Image(nsImage:image).resizable().scaledToFit()}
                else if library.previewing.contains(pet.id) {ProgressView().controlSize(.small)}
                else {Image(systemName:library.previewErrors.contains(pet.id) ? "arrow.clockwise" : "pawprint").font(.system(size:25)).foregroundStyle(.secondary)}
            }.frame(width:60,height:64).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(pet.imageURL == nil || pet.imageExpiresAt == nil)
            .help(library.previewErrors.contains(pet.id) ? L("预览未能加载，点击重试", "Preview unavailable; click to retry") : L("宠物预览", "Pet preview"))
            .accessibilityLabel(L("预览", "Preview ")+pet.name)
            .onAppear {library.setPreviewVisible(pet,token:visibilityToken,true)}
            .onDisappear {library.setPreviewVisible(pet,token:visibilityToken,false)}
    }
}
