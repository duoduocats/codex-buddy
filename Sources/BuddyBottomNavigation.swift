import AppKit
import SwiftUI

struct BuddyNavigationItem: Equatable, Identifiable {
    let id:String
    let title:String
    let symbol:String
}

@MainActor struct BuddyBottomNavigation:View {
    let items:[BuddyNavigationItem]
    @Binding var selection:String
    let accessibilityPrefix:String
    let accessibilityLabel:String
    var onSelect:(String)->Void = {_ in}
    @Namespace private var railSpace
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focusedID:String?
    @GestureState private var gestureActive=false
    @State private var visualSelection=""
    @State private var motion:BuddyNavigationMotion?
    @State private var dragVisual:BuddyNavigationMotion.VisualState?
    @State private var moved=false
    @State private var cancelledGesture=false
    private var visibleID:String {visualSelection.isEmpty ? selection : visualSelection}
    private var highlightedID:String {
        if let index=dragVisual?.previewIndex,items.indices.contains(index) {return items[index].id}
        return visibleID
    }
    private func labelColor(_ item:BuddyNavigationItem)->Color {item.id == highlightedID ? .accentColor : .secondary}
    private var settling:Animation? {reduceMotion ? nil : .spring(response:0.32,dampingFraction:0.78)}
    private var pointerActivation:Bool {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp:return true
        default:return false
        }
    }

    var body:some View {
        GeometryReader { proxy in
            let geometry=BuddyNavigationMotion.Geometry(width:Double(proxy.size.width),count:items.count)
            rail(geometry)
        }.frame(height:60)
            .accessibilityElement(children:.contain).accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityPrefix+"navigation")
            .onChange(of:selection) {value in
                let animated=pointerActivation
                if motion != nil {cancelGesture(latch:true,animated:animated)}
                guard visualSelection != value else {return}
                updateVisualSelection(value,animated:animated)
            }
            .onChange(of:isEnabled) {if !$0 {cancelGesture(latch:true)}}
            .onChange(of:gestureActive) {active in
                if !active {
                    cancelledGesture=false
                    // GestureState also resets after system cancellation. Give
                    // a successful onEnded its turn before restoring the lens.
                    DispatchQueue.main.async {
                        if !gestureActive,motion != nil {cancelGesture()}
                    }
                }
            }
            .onDisappear {motion=nil;dragVisual=nil;moved=false;cancelledGesture=false;visualSelection=selection}
    }
    private func rail(_ geometry:BuddyNavigationMotion.Geometry)->some View {
        ZStack(alignment:.leading) {
            HStack(spacing:CGFloat(geometry.gap)) {
                ForEach(items) {item in
                    Button {choose(item.id)} label:{labelContent(item,color:labelColor(item)).frame(width:CGFloat(geometry.itemWidth),height:48).contentShape(Capsule())}
                        .buttonStyle(.plain).focused($focusedID,equals:item.id)
                        .accessibilityAddTraits(selection == item.id ? .isSelected : [])
                        .accessibilityIdentifier(accessibilityPrefix+item.id)
                        .onMoveCommand {direction in
                            guard let index=items.firstIndex(where:{$0.id == item.id}) else {return}
                            let delta=direction == .left ? -1 : direction == .right ? 1 : 0
                            guard delta != 0 else {return}
                            let next=items[min(max(0,index+delta),items.count-1)].id
                            guard next != item.id else {return}
                            choose(next,animated:false)
                        }
                }
            }.padding(CGFloat(geometry.padding))
            if !items.isEmpty,geometry.itemWidth > 0 {
                let rest=items.firstIndex(where:{$0.id == visibleID}) ?? 0
                let visual=dragVisual ?? .init(center:geometry.center(rest),width:geometry.itemWidth,stretch:1,previewIndex:rest)
                let origin=visual.center-visual.width/2
                lens(geometry,width:visual.width,origin:origin)
                    .offset(x:CGFloat(origin)).accessibilityHidden(true)
            }
        }.frame(width:CGFloat(geometry.width),height:60)
            .background {
                if reduceTransparency {Capsule().fill(Color(nsColor:.controlBackgroundColor))}
                else {Capsule().fill(Color.primary.opacity(0.035))}
            }
            .contentShape(Capsule()).coordinateSpace(name:railSpace)
            .highPriorityGesture(DragGesture(minimumDistance:0,coordinateSpace:.named(railSpace))
                .updating($gestureActive) {_,state,transaction in state=true;transaction.animation=nil}
                .onChanged {value in updateGesture(value,geometry:geometry)}
                .onEnded {value in finishGesture(value)})
    }
    private func labelContent(_ item:BuddyNavigationItem,color:Color)->some View {
        VStack(spacing:4) {
            Image(systemName:item.symbol).font(.system(size:17,weight:.medium)).frame(height:18).accessibilityHidden(true)
            Text(item.title).font(.system(size:12,weight:.medium)).lineLimit(1)
        }.foregroundStyle(color)
    }
    private func foreground(_ geometry:BuddyNavigationMotion.Geometry,width:Double,origin:Double)->some View {
        // Both rows use identical geometry. The inside and outside offsets
        // cancel, so labels stay still while the glass travels over them.
        HStack(spacing:CGFloat(geometry.gap)) {
            ForEach(items) {item in labelContent(item,color:labelColor(item)).frame(width:CGFloat(geometry.itemWidth),height:48)}
        }.frame(width:CGFloat(max(0,geometry.width-2*geometry.padding)),height:48,alignment:.leading)
            .offset(x:CGFloat(geometry.padding-origin))
            .frame(width:CGFloat(width),height:48,alignment:.leading).clipShape(Capsule())
    }
    @ViewBuilder private func lens(_ geometry:BuddyNavigationMotion.Geometry,width:Double,origin:Double)->some View {
        if #available(macOS 26.0,*) {
            foreground(geometry,width:width,origin:origin)
                .glassEffect(.regular.interactive(),in:Capsule())
        } else {
            foreground(geometry,width:width,origin:origin)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        }
    }
    private func updateGesture(_ value:DragGesture.Value,geometry:BuddyNavigationMotion.Geometry) {
        guard isEnabled,!cancelledGesture,!items.isEmpty,geometry.itemWidth > 0 else {return}
        if motion == nil {
            motion=BuddyNavigationMotion(originalIndex:items.firstIndex(where:{$0.id == selection}) ?? 0,
                startLocationX:Double(value.startLocation.x),width:geometry.width,count:items.count,reduceMotion:reduceMotion)
            moved=false
        }
        let next=motion?.visual(translationX:Double(value.translation.width),predictedEndTranslationX:Double(value.predictedEndTranslation.width))
        var transaction=Transaction();transaction.disablesAnimations=true
        withTransaction(transaction) {
            dragVisual=next;moved = moved || abs(value.translation.width) > 4
        }
    }
    private func finishGesture(_ value:DragGesture.Value) {
        guard isEnabled,!cancelledGesture,abs(value.translation.height) <= 60,var current=motion else {cancelGesture();return}
        guard let index=current.release(translationX:Double(value.translation.width)),items.indices.contains(index) else {cancelGesture();return}
        let id=items[index].id,notify = !moved || id != selection
        // Pages change once on release. Live pointer motion only redraws the
        // small glass lens; it never loads another page or another pet list.
        if selection != id {selection=id}
        focusedID=id;motion=nil;moved=false
        withAnimation(settling) {visualSelection=id;dragVisual=nil}
        if notify {onSelect(id)}
    }
    private func choose(_ id:String,animated:Bool? = nil) {
        guard isEnabled,items.contains(where:{$0.id == id}) else {return}
        // Arrow commands are explicit; Space/Return and accessibility actions
        // also stay immediate unless this app is handling a pointer event.
        let animate=animated ?? pointerActivation
        var transaction=Transaction(animation:nil);transaction.disablesAnimations = !animate
        withTransaction(transaction) {
            if gestureActive {cancelledGesture=true}
            motion=nil;moved=false
            if selection != id {selection=id}
            focusedID=id
        }
        updateVisualSelection(id,animated:animate)
        onSelect(id)
    }
    private func updateVisualSelection(_ id:String,animated:Bool) {
        if animated && !reduceMotion {
            withAnimation(settling) {visualSelection=id;dragVisual=nil}
        } else {
            var transaction=Transaction(animation:nil);transaction.disablesAnimations=true
            withTransaction(transaction) {visualSelection=id;dragVisual=nil}
        }
    }
    private func cancelGesture(latch:Bool = false,animated:Bool = true) {
        if latch && gestureActive {cancelledGesture=true}
        motion=nil;moved=false
        updateVisualSelection(selection,animated:animated)
    }
}
