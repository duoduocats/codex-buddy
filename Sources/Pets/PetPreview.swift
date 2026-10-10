import AppKit
import SwiftUI
import QuartzCore

enum PetPreviewAction:Int,CaseIterable,Identifiable {
    case all = -1, idle,walkRight,walkLeft,wave,jump,failed,waiting,working,review,look
    var id:Int { rawValue }
    var title:String {
        switch self {
        case .all:return L("全部动作轮播", "All animations")
        case .idle:return L("待机", "Idle")
        case .walkRight:return L("向右走", "Move right")
        case .walkLeft:return L("向左走", "Move left")
        case .wave:return L("挥手", "Wave")
        case .jump:return L("跳跃", "Jump")
        case .failed:return L("失败", "Error")
        case .waiting:return L("等待", "Waiting")
        case .working:return L("工作", "Working")
        case .review:return L("审阅", "Review")
        case .look:return L("环视", "Look around")
        }
    }
    var buttonTitle:String {
        switch self {
        case .all:return L("全部", "All")
        case .walkRight:return L("右走", "Right")
        case .walkLeft:return L("左走", "Left")
        case .waiting:return L("等待", "Wait")
        case .working:return L("工作", "Work")
        case .look:return L("环视", "Look")
        default:return title
        }
    }
    static func available(in image:CGImage) -> [Self] { allCases.filter { $0 != .look || image.height == 2288 } }
}

enum PetPreviewFrames {
    static let width=192
    static let height=208
    struct Frame { let image:CGImage;let action:PetPreviewAction }

    static func idleFrames(in image:CGImage) -> [CGImage] {
        frames(in:image,action:.idle).map(\.image)
    }
    static func frames(in image:CGImage,action:PetPreviewAction) -> [Frame] {
        let colorSpace=image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name:CGColorSpace.sRGB)!
        guard image.width == width*8,[1872,2288].contains(image.height),
              let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:colorSpace,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .none
        var frames=[Frame]()
        let rect=CGRect(x:0,y:0,width:width,height:height)
        let rows:[Int]
        switch action {
        case .all:rows=Array(0..<(image.height/height))
        case .look:rows=image.height == 2288 ? [9,10] : []
        default:rows=[action.rawValue]
        }
        for row in rows {
        for column in 0..<8 {
            guard let crop=image.cropping(to:CGRect(x:column*width,y:row*height,width:width,height:height)) else { continue }
            context.clear(rect);context.draw(crop,in:rect)
            guard let pixels=context.data?.assumingMemoryBound(to:UInt8.self) else { continue }
            // Short action loops leave unused transparent cells in the eight-column atlas.
            // They are padding, so playing them would make the pet disappear on every loop.
            let hasArtwork=stride(from:3,to:width*height*4,by:4).contains { pixels[$0] != 0 }
            if hasArtwork,let frame=context.makeImage() { frames.append(.init(image:frame,action:row >= 9 ? .look : PetPreviewAction(rawValue:row)!)) }
        }
        }
        // Copies keep playback textures small rather than retaining/uploading the atlas.
        return frames
    }
}

struct PetAnimatedPreview:View {
    var image:CGImage?
    var loading:Bool
    var error:String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playing=true
    @State private var action=PetPreviewAction.all
    @State private var displayedAction:PetPreviewAction?
    var body:some View {
        VStack(spacing:0) {
            Group {
                if let image {
                    PetSpriteView(image:image,playing:playing && !reduceMotion,action:action,onActionChange:{displayedAction=$0})
                        .padding(42).accessibilityLabel(L("Pet 动作预览", "Pet animation preview"))
                        .overlay { if displayedAction == nil { Text(L("该动作暂无画面", "No frames for this animation")).font(.system(size:12)).foregroundStyle(.secondary) } }
                } else if loading {
                    VStack(spacing:14) { ProgressView();Text(L("载入宠物预览…", "Loading pet preview…")).foregroundStyle(.secondary) }
                } else {
                    VStack(spacing:16) {
                        PetStoreMark(size:64)
                        Text(error ?? L("选择宠物查看预览", "Select a pet to preview")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(24)
                }
            }.frame(maxWidth:.infinity).frame(height:410)
            if let image {
                Divider()
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:8),count:6),spacing:8) {
                    ForEach(PetPreviewAction.available(in:image)) { item in
                        Button { action=item;playing=true } label:{
                            Text(item.buttonTitle).font(.system(size:12,weight:action == item ? .semibold : .regular))
                                .lineLimit(1).frame(maxWidth:.infinity).frame(height:34)
                                .foregroundStyle(action == item ? Color.white : Color.primary)
                                .background(action == item ? Color.accentColor : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9))
                                .overlay(RoundedRectangle(cornerRadius:9).stroke(Color.primary.opacity(0.10),lineWidth:0.6))
                                .contentShape(RoundedRectangle(cornerRadius:9))
                        }.buttonStyle(.plain).help(item.title)
                            .accessibilityLabel(L("预览", "Preview ")+item.title)
                            .accessibilityAddTraits(action == item ? .isSelected : [])
                    }
                }.padding(20)
                Divider()
                HStack {
                    Text(L("当前动作：", "Animation: ")+(displayedAction?.title ?? "—")).lineLimit(1)
                    Spacer(minLength:6)
                    Button { playing.toggle() } label:{
                        Label(playing ? L("暂停", "Pause") : L("播放", "Play"),systemImage:playing ? "pause.circle" : "play.circle")
                            .padding(.vertical,6).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(reduceMotion)
                }.font(.system(size:13)).foregroundStyle(.secondary).padding(.horizontal,20).padding(.vertical,10)
            }
            Spacer(minLength:0)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.10),lineWidth:0.7))
            .onChange(of:image.map{ObjectIdentifier($0)}) { _ in action = .all;displayedAction=nil;playing=true }
    }
}

private struct PetSpriteView:NSViewRepresentable {
    let image:CGImage
    let playing:Bool
    let action:PetPreviewAction
    let onActionChange:(PetPreviewAction?) -> Void
    func makeNSView(context:Context) -> PetSpriteNSView { PetSpriteNSView() }
    func updateNSView(_ view:PetSpriteNSView,context:Context) {
        view.onActionChange=onActionChange
        view.configure(image:image,playing:playing,action:action)
    }
    static func dismantleNSView(_ view:PetSpriteNSView,coordinator:()) { view.stop() }
}

final class PetSpriteNSView:NSView {
    private var image:CGImage?
    private var allFrames=[PetPreviewFrames.Frame]()
    private var frames=[PetPreviewFrames.Frame]()
    private var action=PetPreviewAction.idle
    private var reportedAction:PetPreviewAction?
    var onActionChange:((PetPreviewAction?) -> Void)?
    private var index=0
    private var playing=false
    private var timer:Timer?
    private var observers=[(NotificationCenter,NSObjectProtocol)]()
    var hasPlaybackTimer:Bool { timer != nil }
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer=true;layer?.contentsGravity = .resizeAspect
        layer?.actions=["contents":NSNull(),"bounds":NSNull(),"position":NSNull()]
        for name in [NSApplication.didBecomeActiveNotification,NSApplication.didResignActiveNotification] {
            observe(name,center:.default) { [weak self] _ in self?.updateTimer() }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification] {
            observe(name,center:.default) { [weak self] notification in
                guard let self, let window=notification.object as? NSWindow, self.window === window else { return }
                self.updateTimer()
            }
        }
        observe(NSWindow.willCloseNotification,center:.default) { [weak self] notification in
            guard let self, let window=notification.object as? NSWindow, self.window === window else { return }
            self.stop()
        }
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,center:NSWorkspace.shared.notificationCenter) { [weak self] _ in self?.updateTimer() }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        timer?.invalidate()
        for (center,observer) in observers { center.removeObserver(observer) }
    }
    private func observe(_ name:Notification.Name,center:NotificationCenter,handler:@escaping(Notification) -> Void) {
        observers.append((center,center.addObserver(forName:name,object:nil,queue:.main,using:handler)))
    }
    func configure(image:CGImage,playing:Bool,action:PetPreviewAction = .idle) {
        let changedImage=self.image !== image
        if changedImage || self.action != action {
            stop();self.image=image;index=0
            if changedImage { allFrames=PetPreviewFrames.frames(in:image,action:.all) }
            self.action=action
            frames=action == .all ? allFrames : allFrames.filter{$0.action == action}
            displayFrame()
            reportAction(deferred:true)
        }
        self.playing=playing;updateTimer()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();updateTimer() }
    override func viewDidHide() { super.viewDidHide();updateTimer() }
    override func viewDidUnhide() { super.viewDidUnhide();updateTimer() }
    private func updateTimer() {
        guard playing, frames.count > 1, !isHiddenOrHasHiddenAncestor,
              let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible), NSApp.isActive,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { stop();return }
        guard timer == nil else { return }
        let timer=Timer(timeInterval:0.12,repeats:true) { [weak self] _ in self?.advanceFrame() }
        timer.tolerance=0.02
        self.timer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func advanceFrame() {
        guard frames.count > 1 else { return }
        index=(index+1)%frames.count;displayFrame()
        reportAction(deferred:false)
    }
    private func displayFrame() {
        // Sprite frames switch atomically; a contents crossfade can flash transparent edges.
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer?.contents=frames.isEmpty ? nil : frames[index].image
        CATransaction.commit()
    }
    private func reportAction(deferred:Bool) {
        let action=frames.isEmpty ? nil : frames[index].action
        guard action != reportedAction || deferred else { return }
        reportedAction=action
        guard let callback=onActionChange else { return }
        if deferred { DispatchQueue.main.async { [weak self] in if self?.reportedAction == action { callback(action) } } }
        else { callback(action) }
    }
    func stop() { timer?.invalidate();timer=nil }
}
