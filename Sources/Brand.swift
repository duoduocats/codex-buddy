import AppKit

// The panel uses the refined transparent mascot; cache both system appearances.
enum BuddyBrand {
    static let applicationIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource:"AppIcon",withExtension:"icns") else { return nil }
        return NSImage(contentsOf:url)
    }()
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
