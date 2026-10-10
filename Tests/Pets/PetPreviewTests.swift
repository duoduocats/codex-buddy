import AppKit
import QuartzCore

enum PetPreviewTests {
    private static let colorSpace=CGColorSpace(name:CGColorSpace.sRGB)!
    private static func color(_ red:CGFloat,_ green:CGFloat,_ blue:CGFloat,_ alpha:CGFloat = 1) -> CGColor {
        CGColor(colorSpace:colorSpace,components:[red,green,blue,alpha])!
    }
    private final class ContentsAction:NSObject,CAAction {
        var count=0
        func run(forKey event:String,object anObject:Any,arguments dict:[AnyHashable:Any]?) { count += 1 }
    }

    private static func atlas(height:Int = 1872,filled:[Int:CGColor]) -> CGImage {
        let context=CGContext(data:nil,width:1536,height:height,bitsPerComponent:8,bytesPerRow:1536*4,
            space:colorSpace,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (column,color) in filled {
            context.setFillColor(color)
            context.fill(CGRect(x:column*192,y:height-208,width:192,height:208))
        }
        // A contrasting second row catches upside-down / incorrect-row crops.
        context.setFillColor(color(0,1,0))
        context.fill(CGRect(x:0,y:height-416,width:1536,height:208))
        // An off-center transparent notch also detects mirroring or vertical flips.
        context.clear(CGRect(x:11,y:height-31,width:7,height:9))
        return context.makeImage()!
    }

    private static func pixels(_ image:CGImage) -> Data {
        let context=CGContext(data:nil,width:192,height:208,bitsPerComponent:8,bytesPerRow:192*4,
            space:colorSpace,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image,in:CGRect(x:0,y:0,width:192,height:208))
        return Data(bytes:context.data!,count:192*208*4)
    }
    private static func pixel(_ image:CGImage) -> [UInt8] { Array(pixels(image).prefix(4)) }

    @MainActor static func run() {
        let red=color(1,0,0)
        let blue=color(0,0,1)
        for height in [1872,2288] {
            // Real short idle rows have six frames followed by two transparent padding cells.
            let image=atlas(height:height,filled:Dictionary(uniqueKeysWithValues:(0..<6).map { ($0,$0.isMultiple(of:2) ? red : blue) }))
            let frames=PetPreviewFrames.idleFrames(in:image)
            precondition(frames.count == 6,"Transparent atlas padding must not appear in playback")
            precondition(frames.allSatisfy { $0.width == 192 && $0.height == 208 },"Keep the original cell bounds")
            precondition(pixel(frames[0]) == [255,0,0,255] && pixel(frames[1]) == [0,0,255,255],"Keep top-row artwork, order, colors and orientation: \(pixel(frames[0])), \(pixel(frames[1]))")
            for column in 0..<6 {
                let original=image.cropping(to:CGRect(x:column*192,y:0,width:192,height:208))!
                precondition(pixels(frames[column]) == pixels(original),"Frame preparation must preserve every original pixel and alpha edge")
            }
        }
        let sparse=PetPreviewFrames.idleFrames(in:atlas(filled:[0:red,3:blue]))
        precondition(sparse.count == 2 && pixel(sparse[1]) == [0,0,255,255],"An empty cell must never blank the preview")
        let faint=PetPreviewFrames.idleFrames(in:atlas(filled:[7:color(1,1,1,1.0/255.0)]))
        precondition(faint.count == 1 && pixel(faint[0])[3] == 1,"Do not remove faint original artwork")
        precondition(PetPreviewFrames.idleFrames(in:atlas(filled:[:])).isEmpty,"An empty idle row must stay static")
        for rowCount in [9,11] {
            let height=rowCount*208
            let context=CGContext(data:nil,width:1536,height:height,bitsPerComponent:8,bytesPerRow:1536*4,
                space:colorSpace,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            for row in 0..<rowCount {
                context.setFillColor(color(CGFloat(row+1)/16,0.25,0.5))
                context.fill(CGRect(x:0,y:height-(row+1)*208,width:192,height:208))
            }
            let image=context.makeImage()!
            let all=PetPreviewFrames.frames(in:image,action:.all)
            precondition(all.count == rowCount,"All preview must include every drawn row and exclude padding")
            for row in 0..<rowCount {
                precondition(all[row].action == (row>=9 ? .look : PetPreviewAction(rawValue:row)!))
                precondition(pixels(all[row].image) == pixels(image.cropping(to:CGRect(x:0,y:row*208,width:192,height:208))!),"Action mapping must preserve row positions and pixels")
            }
            let wave=PetPreviewFrames.frames(in:image,action:.wave)
            precondition(wave.count == 1 && pixels(wave[0].image) == pixels(all[3].image))
            let looking=PetPreviewFrames.frames(in:image,action:.look)
            precondition(looking.count == (rowCount == 11 ? 2 : 0))
            precondition(PetPreviewAction.available(in:image).contains(.look) == (rowCount == 11))
        }

        _=NSApplication.shared
        let view=PetSpriteNSView(frame:NSRect(x:0,y:0,width:192,height:208))
        let action=ContentsAction()
        view.layer?.actions=["contents":action]
        let image=atlas(filled:[0:red,1:blue])
        CATransaction.begin();CATransaction.setAnimationDuration(1)
        view.configure(image:image,playing:true)
        view.advanceFrame()
        CATransaction.commit()
        precondition(action.count == 0 && view.layer?.animationKeys()?.isEmpty != false,"Frame swaps must disable implicit Core Animation actions")
        precondition(pixel(view.layer!.contents as! CGImage) == [0,0,255,255])
        view.configure(image:image,playing:true)
        precondition(pixel(view.layer!.contents as! CGImage) == [0,0,255,255],"Unrelated SwiftUI updates must not reset playback")
        view.advanceFrame()
        precondition(pixel(view.layer!.contents as! CGImage) == [255,0,0,255],"Playback must wrap directly to the first drawn frame")
        precondition(!view.hasPlaybackTimer,"A detached preview must not schedule playback")
        view.configure(image:image,playing:false);view.stop()
        precondition(!view.hasPlaybackTimer)
        view.configure(image:atlas(filled:[0:blue]),playing:true)
        precondition(pixel(view.layer!.contents as! CGImage) == [0,0,255,255],"Changing theme must replace the previous frame")
        view.configure(image:atlas(filled:[:]),playing:true)
        precondition(view.layer?.contents == nil && !view.hasPlaybackTimer,"An empty theme must not retain a previous pet")
        let actionsAtlas=atlas(filled:[0:red])
        view.configure(image:actionsAtlas,playing:true,action:.all)
        view.advanceFrame()
        precondition(pixel(view.layer!.contents as! CGImage) == [0,255,0,255],"All playback must reach the second action row")
        view.configure(image:actionsAtlas,playing:true,action:.walkRight)
        precondition(pixel(view.layer!.contents as! CGImage) == [0,255,0,255],"Manual action choice must show the selected row")
        view.configure(image:actionsAtlas,playing:false,action:.idle)
        precondition(pixel(view.layer!.contents as! CGImage) == [255,0,0,255] && !view.hasPlaybackTimer)
        print("Pet preview passed: every v1/v2 action row, manual selection, 16-direction look rows, sparse padding, original pixels, atomic frame swaps, stable reconfiguration and detached playback")
    }
}
