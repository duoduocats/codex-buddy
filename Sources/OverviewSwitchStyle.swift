import SwiftUI

/// Match the approved blue switches while preserving native Toggle accessibility.
struct OverviewSwitchStyle: ToggleStyle {
    let title: String
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration:0.16)) { configuration.isOn.toggle() }
        } label: {
            Capsule().fill(configuration.isOn ? Color.blue : Color.primary.opacity(0.16))
                .overlay(alignment:configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2).shadow(color:.black.opacity(0.12),radius:1,y:1)
                }.frame(width:48,height:27).opacity(enabled ? 1 : 0.4)
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityRepresentation {
                Toggle(title,isOn:configuration.$isOn).toggleStyle(.switch)
            }
    }
}
