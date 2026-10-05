import AppKit

// The panel uses the refined transparent mascot; cache both system appearances.
enum BuddyBrand {
    static let applicationIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource:"AppIcon",withExtension:"icns") else { return nil }
        return NSImage(contentsOf:url)
    }()
    static let settingsIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource:"BuddyMark",withExtension:"png"),
              let image = NSImage(contentsOf:url) else { return nil }
        return canonicalMark(from:image)
    }()
    static func canonicalMark(from image:NSImage) -> NSImage? {
        guard let source=image.cgImage(forProposedRect:nil,context:nil,hints:nil),
              let provider=source.dataProvider,
              let result=CGImage(width:source.width,height:source.height,bitsPerComponent:source.bitsPerComponent,
                bitsPerPixel:source.bitsPerPixel,bytesPerRow:source.bytesPerRow,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:source.bitmapInfo,provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return nil }
        // PNG decoding tags these stored channels as sRGB; the original canonical
        // drawing uses device RGB. Preserve its appearance rather than converting.
        return NSImage(cgImage:result,size:NSSize(width:source.width,height:source.height))
    }
    static func transparentMascot(from artwork:NSImage) -> NSImage? {
        guard let source = artwork.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
        let width = 256, height = 256
        var pixels = [UInt8](repeating:0,count:width*height*4)
        guard let output = pixels.withUnsafeMutableBytes({ buffer -> CGImage? in
            guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,
                bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
            let data = buffer.bindMemory(to:UInt8.self)
            for y in 0..<height {
                // The original blue gradient is sampled outside the mascot.
                // Removing it preserves the cat, terminal cutout and four feet.
                let left = Double(data[y*width*4]),right = Double(data[(y*width+width-1)*4])
                for x in 0..<width {
                    let i = (y*width+x)*4
                    let fraction = Double(x)/Double(width-1)
                    let background = left+(right-left)*fraction
                    let coverage = min(1,max(0,(Double(data[i])-background)/max(1,255-background)))
                    let alpha = coverage < 0.03 ? 0 : coverage
                    for (channel,color) in [42.0,96,255].enumerated() { data[i+channel] = UInt8((color*alpha).rounded()) }
                    data[i+3] = UInt8((255*alpha).rounded())
                }
            }
            return context.makeImage()
        }) else { return nil }
        return NSImage(cgImage:output,size:NSSize(width:width,height:height))
    }
    private static let lightShareLogo = settingsIcon.flatMap { logo(fromMascot:$0,dark:false) }
    private static let darkShareLogo = settingsIcon.flatMap { logo(fromMascot:$0,dark:true) }
    static func shareLogo(dark:Bool) -> NSImage? { dark ? darkShareLogo : lightShareLogo }

    // Keep the largest connected silhouette from the app icon: the head, without its four feet.
    static func logo(fromMascot mascot:NSImage,dark:Bool) -> NSImage? {
        guard let source = mascot.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
        let width = source.width,height = source.height
        guard width > 0,height > 0,width <= 2048,height <= 2048 else { return nil }
        var pixels = [UInt8](repeating:0,count:width*height*4)
        guard let output = pixels.withUnsafeMutableBytes({ buffer -> CGImage? in
            guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
            let bytes = buffer.bindMemory(to:UInt8.self)
            var visited = [Bool](repeating:false,count:width*height),largest = [Int]()
            for start in visited.indices where !visited[start] && bytes[start*4+3] > 0 {
                var component = [start],cursor = 0;visited[start] = true
                while cursor < component.count {
                    let index = component[cursor];cursor += 1
                    let x = index % width,y = index / width
                    let neighbors = [x > 0 ? index-1 : -1,x+1 < width ? index+1 : -1,
                                     y > 0 ? index-width : -1,y+1 < height ? index+width : -1]
                    for neighbor in neighbors where neighbor >= 0 && !visited[neighbor] && bytes[neighbor*4+3] > 0 {
                        visited[neighbor] = true;component.append(neighbor)
                    }
                }
                if component.count > largest.count { largest = component }
            }
            guard !largest.isEmpty else { return nil }
            var keep = [Bool](repeating:false,count:width*height)
            var minX = width,minY = height,maxX = 0,maxY = 0
            for index in largest {
                keep[index] = true
                minX = min(minX,index % width);maxX = max(maxX,index % width)
                minY = min(minY,index / width);maxY = max(maxY,index / width)
            }
            let color: [Double] = dark ? [255,255,255] : [42,96,255]
            for index in keep.indices {
                let alpha = keep[index] ? Double(bytes[index*4+3])/255 : 0
                for channel in 0..<3 { bytes[index*4+channel] = UInt8((color[channel]*alpha).rounded()) }
                bytes[index*4+3] = UInt8((255*alpha).rounded())
            }
            return context.makeImage()?.cropping(to:CGRect(x:minX,y:minY,width:maxX-minX+1,height:maxY-minY+1))
        }) else { return nil }
        return NSImage(cgImage:output,size:NSSize(width:output.width,height:output.height))
    }
    private static let darkHead = makeHead(dark:true)
    private static let lightHead = makeHead(dark:false)
    static func head(dark: Bool) -> NSImage? { dark ? darkHead : lightHead }

    private static func makeHead(dark: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource:"BuddyHead",withExtension:"png"),
              let artwork = NSImage(contentsOf:url),
              let source = artwork.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating:0,count:width*height*4)
        guard let output = pixels.withUnsafeMutableBytes({ buffer -> CGImage? in
            guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,
                bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
            let data = buffer.bindMemory(to:UInt8.self)
            for i in 0..<(width*height) {
                let alpha = Double(data[i*4+3])
                guard alpha > 0 else { continue }
                // Preserve the generated antialiased alpha and smooth glyph edges.
                // Flatten neutral texture to white rather than thresholding the outline.
                let glyph = min(1,max(0,(Double(data[i*4+2])-Double(data[i*4]))/alpha/0.65))
                let blue = dark ? glyph : 1-glyph
                let palette: [Double] = [42,96,255]
                for channel in 0..<3 {
                    data[i*4+channel] = UInt8(((255*(1-blue)+palette[channel]*blue)*alpha/255).rounded())
                }
            }
            return context.makeImage()
        }) else { return nil }
        return NSImage(cgImage:output,size:NSSize(width:width,height:height))
    }
}
