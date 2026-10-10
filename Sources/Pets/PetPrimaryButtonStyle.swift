import SwiftUI

struct PetPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.frame(minHeight:38).foregroundStyle(Color.white)
            .background(Color.blue.opacity(configuration.isPressed ? 0.78 : 1),in:RoundedRectangle(cornerRadius:9))
            .opacity(enabled ? 1 : 0.45).contentShape(RoundedRectangle(cornerRadius:9))
    }
}
