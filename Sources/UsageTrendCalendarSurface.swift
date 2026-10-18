import AppKit
import SwiftUI

struct UsageTrendGridGeometry:Equatable {
    let columns:Int
    let cell:CGFloat
    let gap:CGFloat
    var size:CGSize {CGSize(width:CGFloat(columns)*cell+CGFloat(max(0,columns-1))*gap,height:7*cell+6*gap)}
    func rect(column:Int,row:Int)->CGRect {CGRect(x:CGFloat(column)*(cell+gap),y:CGFloat(row)*(cell+gap),width:cell,height:cell)}
    func location(at point:CGPoint)->(column:Int,row:Int)? {
        guard cell > 0,point.x.isFinite,point.y.isFinite,point.x >= 0,point.y >= 0,point.x < size.width,point.y < size.height else {return nil}
        let column=Int(point.x/(cell+gap)),row=Int(point.y/(cell+gap))
        guard column < columns,row < 7,rect(column:column,row:row).contains(point) else {return nil}
        return (column,row)
    }
    func frames(in map:UsageTrendHeatmap,origin:CGPoint = .zero)->[String:CGRect] {
        var result=[String:CGRect]()
        for (column,week) in map.columns.enumerated() {
            for (row,day) in week.cells.enumerated() where day.insideRange {
                result[day.day]=rect(column:column,row:row).offsetBy(dx:origin.x,dy:origin.y)
            }
        }
        return result
    }
}

@MainActor struct UsageTrendCalendarSurface:NSViewRepresentable {
    let map:UsageTrendHeatmap
    let geometry:UsageTrendGridGeometry
    let selectedDay:String?
    let interaction:UsageTrendInteraction
    let dark:Bool
    let select:(Date)->Void
    func makeNSView(context:Context)->UsageTrendCalendarNativeView {UsageTrendCalendarNativeView(frame:.zero)}
    func updateNSView(_ view:UsageTrendCalendarNativeView,context:Context) {
        view.configure(map:map,geometry:geometry,selectedDay:selectedDay,interaction:interaction,dark:dark,select:select)
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:UsageTrendCalendarNativeView,context:Context)->CGSize? {geometry.size}
}

// One native surface draws the grid. Virtual accessibility buttons retain all
// dates and their exact frames without 365 SwiftUI focus/hover/layout trees.
@MainActor final class UsageTrendCalendarNativeView:NSView {
    private var map:UsageTrendHeatmap?
    private(set) var geometry=UsageTrendGridGeometry(columns:0,cell:1,gap:4.5)
    private var records=[String:UsageTrendHeatmapCell]()
    private var frames=[String:CGRect]()
    private var ordered=[String]()
    private var elements=[String:UsageTrendCalendarAccessibilityCell]()
    private var labels=[String:String]()
    private var selectedDay:String?
    private var hoveredDay:String?
    private var focusedDay:String?
    private var dark=false
    private var localeContext=""
    private var tracking:NSTrackingArea?
    private var interaction:UsageTrendInteraction?
    private var select:((Date)->Void)?
    override var isFlipped:Bool {true}
    override var wantsDefaultClipping:Bool {false}
    override var acceptsFirstResponder:Bool {true}
    func configure(map:UsageTrendHeatmap,geometry:UsageTrendGridGeometry,selectedDay:String?,interaction:UsageTrendInteraction,dark:Bool,select:@escaping(Date)->Void) {
        self.interaction=interaction;self.select=select
        let context=Locale.autoupdatingCurrent.identifier+"|"+TimeZone.autoupdatingCurrent.identifier+"|"+(AppLanguage.chinese ? "zh" : "en")
        let changed=self.map != map || self.geometry != geometry || self.dark != dark || localeContext != context
        self.geometry=geometry;self.dark=dark;localeContext=context
        if changed {
            self.map=map;records=Dictionary(uniqueKeysWithValues:map.columns.flatMap(\.cells).filter(\.insideRange).map {($0.day,$0)})
            frames=geometry.frames(in:map);ordered=records.values.sorted {$0.date < $1.date}.map(\.day)
            labels=records.mapValues {UsageTrendFormat.date($0.date,year:true)+", "+UsageTrendFormat.exactTokens($0.tokens ?? 0)+" Token"}
            let old=elements;elements=[:]
            for day in ordered {
                let element=old[day] ?? UsageTrendCalendarAccessibilityCell(owner:self,day:day)
                element.setAccessibilityLabel(labels[day]);elements[day]=element
            }
            setAccessibilityElement(true);setAccessibilityRole(.group)
            setAccessibilityLabel(L("年度 Token 活动", "Yearly token activity"))
            setAccessibilityIdentifier("usage-calendar-grid")
            setAccessibilityChildren(ordered.compactMap {elements[$0]})
            appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
            invalidateIntrinsicContentSize();needsDisplay=true
            if let day=hoveredDay,records[day] == nil {clearHover()}
            if let day=focusedDay,records[day] == nil {setFocus(nil)}
        }
        if self.selectedDay != selectedDay {
            redraw(self.selectedDay);elements[self.selectedDay ?? ""]?.setAccessibilitySelected(false)
            self.selectedDay=selectedDay;redraw(selectedDay)
        }
        elements[selectedDay ?? ""]?.setAccessibilitySelected(true)
    }
    override var intrinsicContentSize:NSSize {geometry.size}
    override func draw(_ dirtyRect:NSRect) {
        for day in ordered {
            guard let rect=frames[day],rect.insetBy(dx:-1,dy:-1).intersects(dirtyRect),let cell=records[day] else {continue}
            let color:NSColor
            if let intensity=cell.intensity {
                color=intensity == 0 ? NSColor.labelColor.withAlphaComponent(dark ? 0.22 : 0.13)
                    : NSColor.systemBlue.withAlphaComponent([0,0.38,0.58,0.78,1][min(4,intensity)])
            } else {color=NSColor.labelColor.withAlphaComponent(dark ? 0.11 : 0.045)}
            let path=NSBezierPath(roundedRect:rect,xRadius:3,yRadius:3);color.setFill();path.fill()
            if day == selectedDay || day == hoveredDay || day == focusedDay {
                NSColor.systemBlue.setStroke();path.lineWidth=1.2;path.stroke()
            }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {removeTrackingArea(tracking)}
        let next=NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.mouseEnteredAndExited,.mouseMoved,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(next);tracking=next
    }
    func day(at point:CGPoint)->String? {
        guard let location=geometry.location(at:point),let map,location.column < map.columns.count,location.row < map.columns[location.column].cells.count else {return nil}
        let cell=map.columns[location.column].cells[location.row];return cell.insideRange ? cell.day : nil
    }
    override func mouseEntered(with event:NSEvent) {mouseMoved(with:event)}
    override func mouseMoved(with event:NSEvent) {updateHover(at:convert(event.locationInWindow,from:nil))}
    func updateHover(at point:CGPoint) {hover(day(at:point))}
    override func mouseExited(with event:NSEvent) {clearHover()}
    private func hover(_ day:String?) {
        guard hoveredDay != day else {return}
        let old=hoveredDay;hoveredDay=day;redraw(old);redraw(day)
        if let day {interaction?.hover(day,active:true)} else if let old {interaction?.hover(old,active:false)}
    }
    private func clearHover() {hover(nil)}
    private func redraw(_ day:String?) {if let day,let rect=frames[day] {setNeedsDisplay(rect.insetBy(dx:-1,dy:-1))}}
    func press(_ day:String)->Bool {
        guard let cell=records[day] else {return false}
        _=window?.makeFirstResponder(self);setFocus(day);select?(cell.date);return true
    }
    override func mouseDown(with event:NSEvent) {if let day=day(at:convert(event.locationInWindow,from:nil)) {_=press(day)}}
    override func becomeFirstResponder()->Bool {
        let accepted=super.becomeFirstResponder()
        if accepted {setFocus(selectedDay.flatMap {records[$0] == nil ? nil : $0} ?? ordered.last)}
        return accepted
    }
    override func resignFirstResponder()->Bool {setFocus(nil);return super.resignFirstResponder()}
    func moveFocus(days:Int) {
        guard !ordered.isEmpty else {return}
        let current=focusedDay ?? selectedDay ?? ordered.last!
        let i=ordered.firstIndex(of:current) ?? ordered.count-1
        setFocus(ordered[min(max(0,i+days),ordered.count-1)])
    }
    private func setFocus(_ day:String?) {
        guard focusedDay != day else {return}
        let old=focusedDay;focusedDay=day;redraw(old);redraw(day)
        elements[old ?? ""]?.setAccessibilityFocused(false)
        if let day {
            interaction?.focus(day,active:true);elements[day]?.setAccessibilityFocused(true)
            if let rect=frames[day],window?.firstResponder === self {scrollToVisible(rect.insetBy(dx:-2,dy:-2))}
            if let element=elements[day] {NSAccessibility.post(element:element,notification:.focusedUIElementChanged)}
        } else if let old {interaction?.focus(old,active:false)}
    }
    override func keyDown(with event:NSEvent) {
        switch event.keyCode {
        case 123:moveFocus(days:-7)
        case 124:moveFocus(days:7)
        case 125:moveFocus(days:1)
        case 126:moveFocus(days:-1)
        case 115:if let first=ordered.first {setFocus(first)}
        case 119:if let last=ordered.last {setFocus(last)}
        case 36,49:if let day=focusedDay ?? selectedDay {_=press(day)}
        default:super.keyDown(with:event)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {clearHover();setFocus(nil)}
    }
    func accessibilityFrame(for day:String)->CGRect {
        guard let rect=frames[day],let window else {return .zero}
        return window.convertToScreen(convert(rect,to:nil))
    }
}

@MainActor private final class UsageTrendCalendarAccessibilityCell:NSAccessibilityElement {
    private weak var owner:UsageTrendCalendarNativeView?
    private let day:String
    init(owner:UsageTrendCalendarNativeView,day:String) {
        self.owner=owner;self.day=day;super.init()
        setAccessibilityParent(owner);setAccessibilityRole(.button)
        setAccessibilityIdentifier("usage-calendar-day-"+day);setAccessibilityEnabled(true)
    }
    override nonisolated func accessibilityFrame()->NSRect {MainActor.assumeIsolated {owner?.accessibilityFrame(for:day) ?? .zero}}
    override nonisolated func accessibilityPerformPress()->Bool {MainActor.assumeIsolated {owner?.press(day) ?? false}}
}
