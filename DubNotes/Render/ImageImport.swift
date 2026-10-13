import UIKit

/// Turns a picked photo into the `data:` URL an image element stores inline (media.ts). Small files are kept
/// byte for byte; anything over 1600 px on its longest side or 1.5 MB is downscaled and re-encoded.
enum ImageImport {
    struct Loaded: Equatable {
        var src: String
        var width: Double
        var height: Double
    }

    enum Kind { case png, jpeg, gif, other }

    static func sniff(_ data: Data) -> Kind {
        let b = [UInt8](data.prefix(4))
        if b.count >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return .png }
        if b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return .jpeg }
        if b.count >= 4 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 { return .gif }
        return .other
    }

    static func dataURL(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// Nil when the data isn't an image iOS can decode.
    static func load(_ data: Data) -> Loaded? {
        guard let image = UIImage(data: data) else { return nil }
        let w = Double(image.size.width * image.scale), h = Double(image.size.height * image.scale) // oriented, in pixels
        guard w > 0, h > 0 else { return nil }
        let kind = sniff(data)
        let tooBig = max(w, h) > PageSizing.imageMaxEdge || data.count > PageSizing.keepOriginalBytes
        if !tooBig {
            switch kind {
            case .png: return Loaded(src: dataURL(data, mime: "image/png"), width: w, height: h)
            case .jpeg: return Loaded(src: dataURL(data, mime: "image/jpeg"), width: w, height: h)
            case .gif: return Loaded(src: dataURL(data, mime: "image/gif"), width: w, height: h)
            case .other:
                // HEIC and friends: re-encode so every device and the web can show it
                guard let png = image.pngData() else { return nil }
                return Loaded(src: dataURL(png, mime: "image/png"), width: w, height: h)
            }
        }
        let s = min(1, PageSizing.imageMaxEdge / max(w, h))
        let size = CGSize(width: (w * s).rounded(), height: (h * s).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = kind != .png
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        if kind == .png, let png = scaled.pngData() {
            return Loaded(src: dataURL(png, mime: "image/png"), width: Double(size.width), height: Double(size.height))
        }
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        return Loaded(src: dataURL(jpeg, mime: "image/jpeg"), width: Double(size.width), height: Double(size.height))
    }
}
