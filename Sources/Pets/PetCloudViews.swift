import SwiftUI

struct CloudInstalledPetList:View {
    @ObservedObject var library:PetCloudLibrary
    let search:String
    let manage:()->Void
    var body:some View {
        let filtered=library.pets.filter {search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)}
        return LazyVStack(alignment:.leading,spacing:0) {
            HStack {
                Text(L("云端", "Cloud")).font(.system(size:13,weight:.semibold)).foregroundStyle(.secondary)
                Text("\(filtered.count)").font(.system(size:12)).foregroundStyle(.secondary);Spacer()
                if library.loading {ProgressView().controlSize(.small).accessibilityLabel(L("读取云端宠物", "Loading cloud pets"))}
            }.padding(.bottom,8)
            if library.unavailable {
                HStack {Text(L("暂时无法更新云端宠物", "Could not update cloud pets")).font(.system(size:13)).foregroundStyle(.secondary);Spacer()
                    Button(L("重试", "Retry")) {library.refresh(force:true)}.buttonStyle(.link)
                }.padding(.vertical,12)
            }
            ForEach(filtered) {pet in
                HStack(spacing:18) {
                    Button {library.preview(pet)} label: {
                        ZStack {
                            if let image=library.image(for:pet) {Image(nsImage:image).resizable().scaledToFit()}
                            else if library.previewing.contains(pet.id) {ProgressView().controlSize(.small)}
                            else {Image(systemName:library.previewErrors.contains(pet.id) ? "arrow.clockwise" : "pawprint").font(.system(size:25)).foregroundStyle(.secondary)}
                        }.frame(width:60,height:64).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(pet.imageURL == nil || pet.imageExpiresAt == nil)
                        .help(library.previewErrors.contains(pet.id) ? L("预览未能加载，点击重试", "Preview unavailable; click to retry") : L("点击加载预览", "Click to load preview"))
                        .accessibilityLabel(L("预览", "Preview ")+pet.name)
                    VStack(alignment:.leading,spacing:5) {Text(pet.name).font(.system(size:15,weight:.semibold));Label(L("Codex 云端", "Codex cloud"),systemImage:"cloud").font(.system(size:12)).foregroundStyle(.secondary)}
                    Spacer()
                    Button(action:manage) {Label(L("管理", "Manage"),systemImage:"arrow.up.right").font(.system(size:13))}.buttonStyle(.link)
                        .accessibilityLabel(L("在 Codex 中管理", "Manage in Codex: ")+pet.name)
                }.padding(.vertical,10);Divider()
            }
            if library.pets.isEmpty && !library.loading && !library.unavailable {Text(L("暂无云端宠物", "No cloud pets")).font(.system(size:13)).foregroundStyle(.secondary).padding(.vertical,12)}
        }
    }
}
