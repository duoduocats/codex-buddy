import Foundation

// Selection belongs to the page host. This value only describes the lens while
// dragging and emits one final index when a gesture ends successfully.
struct BuddyNavigationMotion: Equatable {
    struct Geometry: Equatable {
        let width:Double
        let count:Int
        let padding:Double
        let gap:Double
        let itemWidth:Double
        var stride:Double { itemWidth + gap }

        init(width:Double,count:Int,padding:Double = 6,gap:Double = 4) {
            self.width=width.isFinite ? max(0,width) : 0
            self.count=max(0,count)
            self.padding=min(padding.isFinite ? max(0,padding) : 0,self.width/2)
            let inner=max(0,self.width-2*self.padding)
            // Very narrow bars still get nonnegative item/gap geometry.
            self.gap=self.count > 1 ? min(gap.isFinite ? max(0,gap) : 0,inner/(2*Double(self.count)-1)) : 0
            self.itemWidth=self.count > 0 ? max(0,(inner-self.gap*Double(self.count-1))/Double(self.count)) : 0
        }
        func center(_ index:Int) -> Double {
            guard count > 0 else { return width/2 }
            let first=padding+itemWidth/2,last=max(first,width-padding-itemWidth/2)
            let value=first+Double(min(max(0,index),count-1))*stride
            return value.isFinite ? min(last,max(first,value)) : last
        }
        func clampedCenter(_ locationX:Double) -> Double {
            guard count > 0 else { return width/2 }
            return locationX.isFinite ? min(center(count-1),max(center(0),locationX)) : center(0)
        }
        func index(at locationX:Double) -> Int? {
            guard count > 0,locationX.isFinite else { return nil }
            guard count > 1,stride > 0 else { return 0 }
            if locationX <= center(0) { return 0 }
            if locationX >= center(count-1) { return count-1 }
            let nearest=((locationX-center(0))/stride).rounded(.toNearestOrAwayFromZero)
            return min(count-1,max(0,Int(exactly:nearest) ?? count-1))
        }
    }
    struct VisualState: Equatable {
        let center:Double
        let width:Double
        // Horizontal scale relative to one item, with the full lens kept in
        // the bar's content bounds. Rendering may use width directly instead.
        let stretch:Double
        let previewIndex:Int?
    }
    enum Phase:Equatable { case dragging,released,cancelled }

    let geometry:Geometry
    let originalIndex:Int?
    let startLocationX:Double
    let reduceMotion:Bool
    private let anchorCenter:Double
    private var endIndex:Int?
    private(set) var phase:Phase = .dragging

    init(originalIndex:Int,startLocationX:Double,width:Double,count:Int,reduceMotion:Bool = false,padding:Double = 6,gap:Double = 4) {
        let geometry=Geometry(width:width,count:count,padding:padding,gap:gap)
        self.geometry=geometry
        self.originalIndex=geometry.count > 0 ? min(max(0,originalIndex),geometry.count-1) : nil
        self.reduceMotion=reduceMotion
        let originalCenter=geometry.center(self.originalIndex ?? 0)
        self.startLocationX=startLocationX.isFinite ? startLocationX : originalCenter
        // Keep the grab offset when a drag starts inside the selected lens.
        // A drag starting elsewhere in the bar follows its own touch position.
        if abs(self.startLocationX-originalCenter) <= geometry.itemWidth/2 {
            anchorCenter=originalCenter
        } else {
            anchorCenter=geometry.clampedCenter(self.startLocationX)
        }
    }
    private func trackingCenter(translationX:Double) -> Double {
        let translation=translationX.isFinite ? translationX : 0
        let candidate=anchorCenter+translation
        if candidate.isFinite { return geometry.clampedCenter(candidate) }
        return translation > 0 ? geometry.center(geometry.count-1) : geometry.center(0)
    }
    func visual(translationX:Double,predictedEndTranslationX:Double? = nil) -> VisualState {
        if phase != .dragging {
            let target=phase == .cancelled ? originalIndex : endIndex
            return .init(center:geometry.center(target ?? 0),width:geometry.itemWidth,stretch:1,previewIndex:target)
        }
        let center=trackingCenter(translationX:translationX)
        var requestedScale=1.0
        if !reduceMotion,geometry.count > 1,geometry.stride > 0,
           translationX.isFinite,let predicted=predictedEndTranslationX,predicted.isFinite {
            let difference=predicted-translationX
            if difference.isFinite {
                // This is a bounded predicted displacement cue, not velocity.
                requestedScale += min(1,abs(difference)/geometry.stride)*0.10
            }
        }
        let availableWidth=max(0,2*min(center-geometry.padding,geometry.width-geometry.padding-center))
        let width=min(geometry.itemWidth*requestedScale,availableWidth)
        let stretch=geometry.itemWidth > 0 ? max(1,width/geometry.itemWidth) : 1
        return .init(center:center,width:width,stretch:stretch,previewIndex:geometry.index(at:center))
    }
    func releasedIndex(translationX:Double,predictedEndTranslationX:Double? = nil) -> Int? {
        // Flick prediction never selects a different page: snap to the actual
        // displayed center. Prediction is only allowed to deform the lens.
        geometry.index(at:trackingCenter(translationX:translationX))
    }
    mutating func release(translationX:Double,predictedEndTranslationX:Double? = nil) -> Int? {
        guard phase == .dragging else { return nil }
        endIndex=releasedIndex(translationX:translationX,predictedEndTranslationX:predictedEndTranslationX)
        phase = .released
        return endIndex
    }
    mutating func cancel() -> Int? {
        guard phase == .dragging else { return nil }
        phase = .cancelled
        return originalIndex
    }
    static func clickIndex(at locationX:Double,width:Double,count:Int,padding:Double = 6,gap:Double = 4) -> Int? {
        Geometry(width:width,count:count,padding:padding,gap:gap).index(at:locationX)
    }
}
