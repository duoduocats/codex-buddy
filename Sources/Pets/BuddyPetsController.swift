import AppKit
import SwiftUI

enum PetStorePage: String, CaseIterable, Identifiable {
    case discover, favorites, installed, sources
    var id: Self { self }
    var title: String {
        switch self {
        case .discover: return L("发现", "Discover")
        case .favorites: return L("收藏", "Favorites")
        case .installed: return L("已安装", "Installed")
        case .sources: return L("来源", "Sources")
        }
    }
    var symbol: String {
        switch self {
        case .discover: return "safari"
        case .favorites: return "bookmark"
        case .installed: return "shippingbox"
        case .sources: return "square.3.layers.3d"
        }
    }
}

// Creating the main window must not start pet networking or scan a library.
@MainActor final class BuddyPetsController: ObservableObject {
    static let shared = BuddyPetsController()
    @Published private(set) var store: ThemeStoreModel?
    private let factory: @MainActor () -> ThemeStoreModel
    init(factory: @escaping @MainActor () -> ThemeStoreModel = { ThemeStoreModel() }) { self.factory = factory }
    func setVisible(_ visible: Bool) {
        if visible {
            if store == nil { store = factory() }
            if store?.visible == false { store?.open() }
        } else { store?.close() }
    }
    var modifyingLocalLibrary: Bool { store?.modifyingLocalLibrary == true }
    func finishCurrentInstallation() async { await store?.finishCurrentInstallation() }
}

struct PetStoreMark: View {
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Group {
            if let image = BuddyBrand.settingsGlyph {
                Image(nsImage:image).renderingMode(.template).resizable().scaledToFit()
            } else { Image(systemName:"pawprint").resizable().scaledToFit() }
        }.frame(width:size,height:size)
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black).accessibilityHidden(true)
    }
}

struct BuddyPetsPage: View {
    @ObservedObject var controller: BuddyPetsController
    @ObservedObject var updates: UpdateManager
    var body: some View {
        Group {
            if let store = controller.store { BuddyPetStoreView(store:store,updates:updates) }
            else { ProgressView().controlSize(.small) }
        }.onAppear { controller.setVisible(true) }.onDisappear { controller.setVisible(false) }
    }
}
