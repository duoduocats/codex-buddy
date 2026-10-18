import Foundation

@main struct BuddyNavigationMotionTests {
    static func check(_ condition:Bool,_ message:String,line:Int = #line) { if !condition { fatalError("\(message) at line \(line)") } }
    static func near(_ a:Double,_ b:Double,_ message:String,line:Int = #line) { check(a.isFinite && b.isFinite && abs(a-b)<0.000_001,message,line:line) }
    static func bounded(_ visual:BuddyNavigationMotion.VisualState,_ geometry:BuddyNavigationMotion.Geometry,line:Int = #line) {
        check(visual.center.isFinite && visual.width.isFinite && visual.stretch.isFinite,"Finite lens geometry",line:line)
        check(visual.width >= 0 && visual.center-visual.width/2 >= -0.000_001 && visual.center+visual.width/2 <= geometry.width+0.000_001,"The lens stays inside the bar",line:line)
    }
    static func main() {
        let g=BuddyNavigationMotion.Geometry(width:400,count:4)
        near(g.itemWidth,94,"Four equal items with six-point inset and four-point gaps")
        near(g.center(0),53,"First item center")
        near(g.center(3),347,"Last item center")
        check(g.index(at:101.9)==0 && g.index(at:102)==1,"Nearest-center hit testing includes the gap")
        check(BuddyNavigationMotion.clickIndex(at:260,width:400,count:4)==2,"Click picks nearest item")
        let motion=BuddyNavigationMotion(originalIndex:0,startLocationX:g.center(0),width:400,count:4)
        var previous=g.center(0)
        for step in 1...25 {
            let translation=Double(step)*g.stride/10
            let v=motion.visual(translationX:translation)
            near(v.center,g.center(0)+translation,"Drag remains fractional across several items")
            near(v.center-previous,g.stride/10,"No whole-segment snapping during the drag")
            previous=v.center;bounded(v,g)
        }
        let before=motion.visual(translationX:g.stride*1.49)
        let after=motion.visual(translationX:g.stride*1.51)
        near(after.center-before.center,g.stride*0.02,"Crossing a selection midpoint does not jump the lens")
        check(before.previewIndex==1 && after.previewIndex==2,"Visual item hint follows midpoint without changing geometry")
        let stretched=motion.visual(translationX:g.stride*1.25,predictedEndTranslationX:g.stride*2)
        check(stretched.stretch>1 && stretched.stretch<=1.100_001,"Predicted displacement produces bounded deformation")
        near(motion.visual(translationX:g.stride*1.25,predictedEndTranslationX:g.stride*1.25).stretch,1,"Equal predicted/actual translations do not imply velocity")
        near(motion.visual(translationX:g.stride*1.25,predictedEndTranslationX:.nan).stretch,1,"Invalid prediction does not deform")
        near(motion.visual(translationX:g.stride*1.25,predictedEndTranslationX:.infinity).stretch,1,"Infinite prediction does not deform")
        check(motion.releasedIndex(translationX:g.stride*1.49,predictedEndTranslationX:1_000_000)==1,"Forward flick never changes the nearest actual page")
        check(motion.releasedIndex(translationX:g.stride*1.51,predictedEndTranslationX:-1_000_000)==2,"Backward flick never changes the nearest actual page")
        for x in [-1_000_000.0,0,g.stride*1.5,1_000_000] { bounded(motion.visual(translationX:x,predictedEndTranslationX:x+500),g) }
        let offsetGrab=BuddyNavigationMotion(originalIndex:1,startLocationX:g.center(1)-25,width:400,count:4)
        near(offsetGrab.visual(translationX:0).center,g.center(1),"Grabbing the selected lens edge preserves the initial center")
        near(offsetGrab.visual(translationX:17).center,g.center(1)+17,"Grab offset stays stable")
        let trackGrab=BuddyNavigationMotion(originalIndex:0,startLocationX:g.center(2),width:400,count:4)
        near(trackGrab.visual(translationX:11).center,g.center(2)+11,"Dragging from another part of the bar follows that touch")
        let reduced=BuddyNavigationMotion(originalIndex:0,startLocationX:g.center(0),width:400,count:4,reduceMotion:true)
        let simple=reduced.visual(translationX:g.stride*1.3,predictedEndTranslationX:g.stride*3)
        near(simple.stretch,1,"Reduce Motion removes stretch")
        near(simple.width,g.itemWidth,"Reduce Motion preserves item size")
        near(reduced.visual(translationX:-100).center,g.center(0),"Reduce Motion has no leading overshoot")
        near(reduced.visual(translationX:10000).center,g.center(3),"Reduce Motion has no trailing overshoot")
        near(simple.center,motion.visual(translationX:g.stride*1.3).center,"Reduced motion keeps direct pointer tracking")
        // A parent driver updates its page only from a successful first release.
        var page=0,commits=0,drag=motion
        for x in [20.0,160,280,40,210] { _=drag.visual(translationX:x);check(page==0 && commits==0,"Dragging never commits selection") }
        if let target=drag.release(translationX:210,predictedEndTranslationX:10000),target != page {page=target;commits += 1}
        check(page==2 && commits==1,"Exactly one page commit on release")
        check(drag.release(translationX:0)==nil && drag.cancel()==nil,"Repeated completion cannot emit another commit")
        near(drag.visual(translationX:999).center,g.center(2),"Finished lens stays at its released target")
        var cancelled=BuddyNavigationMotion(originalIndex:1,startLocationX:g.center(1),width:400,count:4)
        page=1;commits=0
        for x in [120.0,-70,180,0] {_=cancelled.visual(translationX:x);check(page==1,"Back-and-forth drag does not change the parent page")}
        check(cancelled.cancel()==1,"Cancel gives the original visual target")
        check(page==1 && commits==0 && cancelled.release(translationX:180)==nil && cancelled.cancel()==nil,"Cancellation never commits a page and finishes once")
        near(cancelled.visual(translationX:180).center,g.center(1),"Cancelled lens returns to the original center")
        for count in [0,1,4] {
            for width in [0.0,1,10,13,400,Double.nan,Double.infinity,-10] {
                let geometry=BuddyNavigationMotion.Geometry(width:width,count:count)
                var value=BuddyNavigationMotion(originalIndex:-99,startLocationX:.nan,width:width,count:count)
                for x in [Double.nan,Double.infinity,-Double.infinity,-500,0,500] {bounded(value.visual(translationX:x,predictedEndTranslationX:.nan),geometry)}
                let target=value.release(translationX:100,predictedEndTranslationX:.infinity)
                check(count==0 ? target==nil : (target != nil && target! >= 0 && target! < count),"Empty/single/narrow/invalid inputs stay safe")
            }
        }
        let single=BuddyNavigationMotion(originalIndex:0,startLocationX:200,width:400,count:1)
        near(single.visual(translationX:200,predictedEndTranslationX:1000).center,200,"Single item stays centered")
        near(single.visual(translationX:200,predictedEndTranslationX:1000).stretch,1,"Single item never stretches")
        check(g.index(at:.nan)==nil && g.index(at:.infinity)==nil,"Invalid hit coordinates do not pick a page")
        let extreme=BuddyNavigationMotion(originalIndex:Int.max,startLocationX:Double.greatestFiniteMagnitude,width:Double.greatestFiniteMagnitude,count:Int.max,padding:.infinity,gap:.infinity)
        bounded(extreme.visual(translationX:Double.greatestFiniteMagnitude),extreme.geometry)
        print("Navigation motion tests passed: continuous multi-item dragging, nearest actual release, bounded stretch, reduced motion, grab offsets, cancellation, once-only commit and invalid geometry")
    }
}
