import SwiftUI
import AppKit

// A native popup owns the full control rectangle, including its empty padding.
struct PetSourcePicker: NSViewRepresentable {
    let sources: [PetSource]
    @Binding var selection: String
    func makeCoordinator() -> Coordinator { Coordinator(selection:$selection) }
    func makeNSView(context:Context) -> NSPopUpButton {
        let button=NSPopUpButton(frame:.zero,pullsDown:false)
        button.isBordered=false;button.font = .systemFont(ofSize:14)
        button.setContentHuggingPriority(.defaultLow,for:.horizontal)
        button.setAccessibilityLabel(L("来源筛选", "Filter by source"))
        button.target=context.coordinator;button.action=#selector(Coordinator.choose(_:))
        return button
    }
    func updateNSView(_ button:NSPopUpButton,context:Context) {
        context.coordinator.selection=$selection
        let menu=NSMenu()
        for (id,title) in [("",L("全部来源", "All sources"))]+sources.filter(\.enabled).map({($0.id,$0.name)}) {
            let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");item.representedObject=id;menu.addItem(item)
        }
        button.menu=menu
        button.select(menu.items.first(where:{($0.representedObject as? String) == selection}) ?? menu.items[0])
    }
    final class Coordinator: NSObject {
        var selection:Binding<String>
        init(selection:Binding<String>) { self.selection=selection }
        @objc func choose(_ sender:NSPopUpButton) { selection.wrappedValue=sender.selectedItem?.representedObject as? String ?? "" }
    }
}
