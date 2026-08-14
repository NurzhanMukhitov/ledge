import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Turns a file on the shelf into another file on the shelf.
///
/// Everything here is a pure function over a URL: nothing is displayed, nothing
/// is remembered. The pane decides what to offer, the vault decides where the
/// result lands, and this only knows how to make it.
///
/// Native frameworks only — ImageIO for pixels, PDFKit for pages. The app
/// promises to work with nothing installed, and a converter that shelled out to
/// `ffmpeg` would be the first thing to break that promise. It also means the
/// panel never waits on a process it did not start.
enum Converter {

    /// Output shares the screenshot vault.
    ///
    /// A second folder would only make the user learn two, and this one already
    /// solves the same problem: it is outside TCC's reach, it is findable, and
    /// Settings already offers to reveal and clear it. Writing next to the
    /// original was the other candidate and is worse — originals live in
    /// Downloads and Desktop, which is exactly where a write raises a prompt.
    static var folder: URL { ScreenshotVault.folder }

    // MARK: - What a file can become

    /// Whether the shelf card is something this can work on at all.
    ///
    /// Asked of the name, not the bytes: the shelf deliberately avoids touching
    /// files until someone looks at them, and a context menu is built before
    /// anyone has decided to convert anything.
    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Already a JPEG, so offering "to JPEG" would be a no-op with a filename
    /// suffix on it.
    static func isJPEG(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .jpeg)
    }

    // MARK: - To JPEG

    /// The HEIC-off-an-iPhone case, and PNG when someone wants a smaller file.
    ///
    /// Quality is fixed high: this is a format change, not a compression run.
    /// Someone who wants the file smaller has the three variants for that, and
    /// mixing the two would make "to JPEG" quietly lossy in a way its name does
    /// not admit.
    static func toJPEG(_ url: URL) -> URL? {
        guard let (image, properties) = decode(url) else { return nil }
        guard let data = encodeJPEG(flattened(image), quality: 0.9, properties: properties) else { return nil }
        return write(data, named: base(url), prefix: "JPEG", ext: "jpg")
    }

    // MARK: - Compress

    /// One rung of the compression ladder, already encoded.
    ///
    /// The bytes travel with the label on purpose. The size shown to the user
    /// has to be the size of the file they will get — computing it from a
    /// sample, or predicting it from the quality number, is how a picker ends
    /// up honest-looking and wrong.
    struct Variant: Identifiable, Sendable {
        let id = UUID()
        /// What the picker shows: one word, because the number beside it is
        /// what the choice is actually made on.
        let label: String
        /// What the filename leads with, which has to carry more — a file named
        /// for "Strong" alone, met a week later in a folder, does not say
        /// strong *what*.
        let prefix: String
        let data: Data
        var bytes: Int { data.count }
    }

    /// Three rungs, encoded for real.
    ///
    /// Deliberately not a slider. The panel is 620×208 and opens on hover — it
    /// is a place to decide in, not to explore in, and there is no room for the
    /// preview a slider would need to be worth its cost. Three finished answers
    /// need no preview: the number under each one is the answer.
    ///
    /// Runs off the main actor — a 40-megapixel photo encoded three times would
    /// otherwise freeze the panel mid-hover.
    static func variants(for url: URL) async -> [Variant] {
        await Task.detached(priority: .userInitiated) { () -> [Variant] in
            guard let (image, properties) = decode(url) else { return [] }
            let flat = flattened(image)
            let rungs: [(String, String, Double)] = [
                (localized("Light"), localized("Compressed light"), 0.80),
                (localized("Medium"), localized("Compressed medium"), 0.50),
                (localized("Strong"), localized("Compressed strong"), 0.25),
            ]
            return rungs.compactMap { label, prefix, quality in
                guard let data = encodeJPEG(flat, quality: quality, properties: properties) else { return nil }
                return Variant(label: label, prefix: prefix, data: data)
            }
        }.value
    }

    static func save(_ variant: Variant, from url: URL) -> URL? {
        write(variant.data, named: base(url), prefix: variant.prefix, ext: "jpg")
    }

    // MARK: - Strip metadata

    /// Drops what the camera wrote and keeps what the picture needs.
    ///
    /// Orientation is the exception, and it is not a small one: it is metadata
    /// by every definition, but dropping it lays a portrait photo on its side.
    /// So it is read off the source and put back by hand, while the dictionaries
    /// that carry location, timestamps and camera serials are nulled out.
    ///
    /// Format is preserved rather than normalised to JPEG — someone stripping a
    /// PNG before sending it wants a PNG back.
    static func stripMetadata(_ url: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { return nil }

        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        guard let out = destination(named: base(url), prefix: localized("No metadata"), ext: ext),
              let sink = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil)
        else { return nil }

        // `kCFNull` is how ImageIO is told to drop a dictionary rather than
        // copy it through. Omitting the key would keep it.
        let drop = kCFNull as Any
        var options: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: drop,
            kCGImagePropertyExifDictionary: drop,
            kCGImagePropertyExifAuxDictionary: drop,
            kCGImagePropertyIPTCDictionary: drop,
            kCGImagePropertyTIFFDictionary: drop,
            kCGImageDestinationMetadata: drop,
        ]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let orientation = properties?[kCGImagePropertyOrientation] {
            options[kCGImagePropertyOrientation] = orientation
        }

        CGImageDestinationAddImageFromSource(sink, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { return nil }
        return out
    }

    // MARK: - Images to PDF

    /// Several pictures, one document, in the order the shelf holds them.
    ///
    /// Page size follows each image rather than being normalised to A4: these
    /// are screenshots and photos, not pages, and fitting a 16:10 capture onto
    /// portrait paper adds margins nobody asked for.
    static func imagesToPDF(_ urls: [URL]) -> URL? {
        let document = PDFDocument()
        var index = 0
        for url in urls where isImage(url) {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { continue }
            document.insert(page, at: index)
            index += 1
        }
        guard index > 0 else { return nil }

        // Named after the first picture when there is only one, and after the
        // folder's own word when there are several — "Screenshot 3 (PDF).pdf"
        // for a five-page document would name the wrong thing.
        let name = index == 1 ? base(urls[0]) : localized("Images")
        guard let out = destination(named: name, prefix: "PDF", ext: "pdf") else { return nil }
        guard document.write(to: out) else { return nil }
        return out
    }

    // MARK: - Pixels

    private static func decode(_ url: URL) -> (CGImage, [CFString: Any])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (image, properties)
    }

    /// White behind whatever was transparent.
    ///
    /// JPEG has no alpha channel, and an unflattened PNG logo encoded as one
    /// comes back with a black rectangle where the transparency was. White is
    /// the assumption that surprises fewest people: these files are going into
    /// documents and chat windows, which are white.
    private static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }

        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// Metadata rides along: compressing a photo should not silently strip the
    /// date it was taken. Removing it is a separate action the user asks for by
    /// name.
    private static func encodeJPEG(_ image: CGImage, quality: Double, properties: [CFString: Any]) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        var options = properties
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    // MARK: - Naming

    private static func base(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// A path nothing occupies yet, led by what was done to the file.
    ///
    /// The label goes in front rather than in a bracket at the end, and that is
    /// the whole of the naming rule. A folder sorts by name, so a prefix piles
    /// every compression together and every stripped file together, where a
    /// suffix would scatter them among the originals they came from. It also
    /// survives truncation: a column too narrow shows the beginning of a name,
    /// which is where the answer to "what is this one" now lives.
    ///
    /// Converting the same file twice is normal — trying two rungs of the
    /// ladder does it — so a collision is an expected event, not an error, and
    /// it must not overwrite the earlier answer the user may still be weighing.
    static func destination(named name: String, prefix: String, ext: String) -> URL? {
        let stem = "\(prefix) — \(name)"
        var url = folder.appendingPathComponent("\(stem).\(ext)")
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(attempt).\(ext)")
            attempt += 1
        }
        return url
    }

    private static func write(_ data: Data, named name: String, prefix: String, ext: String) -> URL? {
        guard let url = destination(named: name, prefix: prefix, ext: ext) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("Cyclop: failed to write converted file: \(error.localizedDescription)")
            return nil
        }
    }

    /// "880 KB" — formatted where the bytes are counted rather than in the
    /// three places that would otherwise each round it their own way.
    ///
    /// The formatter is kept because the shelf asks per card per redraw, and
    /// building one of these is not free.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    static func size(_ bytes: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }
}
