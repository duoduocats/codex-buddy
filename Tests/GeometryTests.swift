import AppKit

@main struct GeometryTests {
    static func main() {
        let nodes = DuoDuoCatGeometry.nodes
        precondition(nodes.count == 6 && DuoDuoCatGeometry.resetDots.count == 4)
        precondition(DuoDuoCatGeometry.strokeWidth == DuoDuoCatGeometry.dotDiameter,
                     "Cat outline and reset dots must have the same diameter")
        let gaps = zip(nodes,nodes.dropFirst()).map { a,b in
            hypot(a.x-b.x,a.y-b.y)-DuoDuoCatGeometry.dotDiameter
        }
        precondition(gaps.allSatisfy { $0 > 0 && abs($0-gaps[0]) < 0.000001 },
                     "Both end-cap gaps and all three inter-dot gaps must be equal")
        for (left,right) in zip(nodes,nodes.reversed()) {
            precondition(abs(left.x+right.x) < 0.000001 && abs(left.y-right.y) < 0.000001,
                         "The cat and four dots must be horizontally symmetric")
        }
        precondition(nodes[1].y > nodes[0].y && nodes[2].y > nodes[1].y,
                     "The lower dots must follow a curve rather than a flat row")
        precondition(nodes[2].y < 80 && nodes[2].y-nodes[1].y < 10,
                     "The approved lower curve must remain flatter than the ring")
        precondition(hypot(DuoDuoCatGeometry.outline.currentPoint.x-nodes[5].x,
                           DuoDuoCatGeometry.outline.currentPoint.y-nodes[5].y) < 0.000001,
                     "The visible outline must end at the spacing reference point")
        for size in [CGSize(width:30,height:24),CGSize(width:300,height:240)] {
            let rect = CGRect(origin:.zero,size:size)
            let ring = MenuIconLayout.inRect(rect,theme:.ring)
            let cat = MenuIconLayout.inRect(rect,theme:.duoDuoCat)
            let ringTop = ring.origin.y+MenuIconLayout.ringBounds.minY*ring.scale
            let catTop = cat.origin.y+MenuIconLayout.catBounds.minY*cat.scale
            let ringBottom = ring.origin.y+MenuIconLayout.ringBounds.maxY*ring.scale
            let catBottom = cat.origin.y+MenuIconLayout.catBounds.maxY*cat.scale
            precondition(abs(catTop-ringTop)<0.000001 && abs(catBottom-ringBottom)<0.000001,
                         "Cat and ring must have identical visible height and vertical alignment")
            precondition(abs(catTop-(size.height-catBottom))<0.000001,
                         "Both themes must have equal top and bottom margins")
            precondition(abs((catBottom-catTop)-size.height*0.875)<0.000001,
                         "The native 24-point canvas must use a restrained 21-point visible height")
            precondition(catTop > 0 && catBottom < size.height,
                         "Both menu themes must leave space above and below the artwork")
            precondition(MenuIconLayout.catBounds.width*cat.scale <= size.width)
        }
        print("DuoDuoCat geometry passed: equal line/dot width, five equal edge gaps, flattened lower curve, common 21-point menu height and centered margins")
    }
}
