import Foundation
import PDFKit
import UIKit
import Vision
import ZIPFoundation

struct ExtractedMaterialPage: @unchecked Sendable {
    let number: Int
    let title: String
    let text: String
    let speakerNotes: String
    let thumbnail: Data?
}

enum DocumentProcessingError: LocalizedError {
    case unsupported
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This file type isn't supported yet."
        case .unreadable: return "The document couldn't be opened."
        case .empty: return "No readable content was found in this document."
        }
    }
}

enum DocumentProcessor {
    static func extract(url: URL, kind: MaterialKind) throws -> [ExtractedMaterialPage] {
        switch kind {
        case .pdf: return try extractPDF(url)
        case .slides: return try extractPPTX(url)
        }
    }

    private static func extractPDF(_ url: URL) throws -> [ExtractedMaterialPage] {
        guard let document = PDFDocument(url: url) else { throw DocumentProcessingError.unreadable }
        var result: [ExtractedMaterialPage] = []
        for index in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                var text = (page.string ?? "").cleanDocumentText
                let image = page.thumbnail(of: CGSize(width: 760, height: 980), for: .mediaBox)
                if text.count < 24, let cgImage = image.cgImage {
                    text = recognizeText(in: cgImage)
                }
                // A heading that wrapped onto a second line is still one
                // heading. The type size says where it ends; the line break
                // doesn't.
                let heading = headingByTypeSize(page)
                let title = heading.isEmpty ? firstUsefulLine(in: text) : heading
                result.append(ExtractedMaterialPage(
                    number: index + 1,
                    title: title,
                    text: text,
                    speakerNotes: "",
                    thumbnail: image.jpegData(compressionQuality: 0.72)
                ))
            }
        }
        guard result.contains(where: { !$0.text.isEmpty }) else { throw DocumentProcessingError.empty }
        return result
    }

    private static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .cleanDocumentText
    }

    private static func extractPPTX(_ url: URL) throws -> [ExtractedMaterialPage] {
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            throw DocumentProcessingError.unreadable
        }
        let slideEntries = archive.filter {
            $0.path.range(of: #"^ppt/slides/slide\d+\.xml$"#, options: .regularExpression) != nil
        }.sorted { slideNumber($0.path) < slideNumber($1.path) }

        var result: [ExtractedMaterialPage] = []
        for entry in slideEntries {
            let number = slideNumber(entry.path)
            let slide = slideXML(read(entry, from: archive))
            let slideText = slide.text.cleanDocumentText
            let notesPath = "ppt/notesSlides/notesSlide\(number).xml"
            let notes = archive[notesPath].map { slideXML(read($0, from: archive)).text.cleanDocumentText } ?? ""
            // Fall back to the first line only for decks whose shapes never
            // declare a title placeholder.
            let title = slide.title.isEmpty ? firstUsefulLine(in: slideText) : slide.title
            let body = slide.titleParts.isEmpty
                ? slideText.replacingOccurrences(of: title, with: "")
                : slide.bodyParts.joined(separator: "\n")
            let thumb = slideThumbnail(title: title, body: body.cleanDocumentText, number: number)
            result.append(ExtractedMaterialPage(number: number, title: title, text: slideText,
                                                speakerNotes: notes, thumbnail: thumb))
        }
        guard result.contains(where: { !$0.text.isEmpty || !$0.speakerNotes.isEmpty }) else {
            throw DocumentProcessingError.empty
        }
        return result
    }

    private static func read(_ entry: Entry, from archive: Archive) -> Data {
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data
    }

    private static func slideNumber(_ path: String) -> Int {
        guard let range = path.range(of: #"\d+"#, options: .regularExpression),
              let value = Int(path[range]) else { return 0 }
        return value
    }

    private static func slideXML(_ data: Data) -> SlideXMLTextDelegate {
        let delegate = SlideXMLTextDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate
    }

    private static func slideThumbnail(title: String, body: String, number: Int) -> Data? {
        let size = CGSize(width: 720, height: 405)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.secondarySystemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let accent = UIColor(red: 0.10, green: 0.69, blue: 0.74, alpha: 1)
            accent.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: size.height))

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph,
            ]
            let bodyAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraph,
            ]
            let titleText = title.isEmpty ? "Slide \(number)" : title
            titleText.draw(in: CGRect(x: 48, y: 42, width: 620, height: 92), withAttributes: titleAttributes)
            // `body` arrives with the title already removed — stripping it again
            // here would miss it anyway once a two-line title is joined up.
            let remainder = body.trimmingCharacters(in: .whitespacesAndNewlines)
            String(remainder.prefix(520)).draw(in: CGRect(x: 48, y: 142, width: 620, height: 210),
                                               withAttributes: bodyAttributes)
        }
        return image.jpegData(compressionQuality: 0.78)
    }

    /// The page's heading, read from its type sizes rather than its newlines.
    ///
    /// Returns "" for a page that has no heading to speak of — one set in a
    /// single size throughout, or a scan with no text layer at all — leaving
    /// the caller to fall back to the first line.
    private static func headingByTypeSize(_ page: PDFPage) -> String {
        guard let attributed = page.attributedString, attributed.length > 0 else { return "" }
        let whole = NSRange(location: 0, length: attributed.length)

        // How much of the page is set at each size. The size carrying the most
        // characters is the body; anything notably bigger is display type.
        var weight: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? UIFont else { return }
            weight[font.pointSize, default: 0] += range.length
        }
        guard let largest = weight.keys.max(),
              let body = weight.max(by: { $0.value < $1.value })?.key,
              largest >= body * 1.15
        else { return "" }

        // The first unbroken stretch in that size — a heading's second line,
        // and the newline between them, are part of it; the body that follows
        // is not.
        var heading: NSRange?
        attributed.enumerateAttribute(.font, in: whole) { value, range, stop in
            if let font = value as? UIFont, font.pointSize >= largest - 0.5 {
                heading = heading.map { NSUnionRange($0, range) } ?? range
            } else if heading != nil {
                stop.pointee = true
            }
        }
        guard let range = heading else { return "" }
        let text = (attributed.string as NSString).substring(with: range)
            .replacingOccurrences(of: "\n", with: " ")
            .cleanDocumentText
        return String(text.prefix(100))
    }

    private static func firstUsefulLine(in text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.count >= 3 }
            .map { String($0.prefix(100)) } ?? ""
    }
}

/// Reads a slide part as paragraphs rather than as a flat list of text runs.
///
/// A paragraph (`a:p`) is one line on the slide; the runs (`a:t`) inside it are
/// only the pieces PowerPoint split it into to change formatting mid-sentence.
/// Treating each run as its own line breaks a sentence apart wherever a single
/// word is bold, and splits a title across two lines whenever it carries a line
/// break — which is most of them.
///
/// The title is read from the shape that declares itself the title placeholder
/// instead of being guessed from the first line, so a title on two lines comes
/// back whole.
private final class SlideXMLTextDelegate: NSObject, XMLParserDelegate {
    /// Every paragraph on the slide, in reading order.
    private(set) var parts: [String] = []
    /// The paragraphs belonging to the title placeholder, a subset of `parts`.
    private(set) var titleParts: [String] = []

    private var collecting = false
    private var buffer = ""
    private var paragraph = ""
    private var inParagraph = false
    private var shapeIsTitle = false
    private var shapeStart = 0

    var title: String { titleParts.joined(separator: " ").cleanDocumentText }
    var text: String { parts.joined(separator: "\n") }

    /// Paragraphs the title doesn't already cover — what a thumbnail draws
    /// under the title without repeating it.
    var bodyParts: [String] {
        guard !titleParts.isEmpty else { return parts }
        var remaining = titleParts
        return parts.filter { part in
            guard let i = remaining.firstIndex(of: part) else { return true }
            remaining.remove(at: i)
            return false
        }
    }

    private func isTag(_ name: String, _ local: String) -> Bool {
        name == local || name.hasSuffix(":" + local)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if isTag(elementName, "sp") {
            shapeIsTitle = false
            shapeStart = parts.count
        } else if isTag(elementName, "ph") {
            let type = attributeDict["type"] ?? ""
            if type == "title" || type == "ctrTitle" { shapeIsTitle = true }
        } else if isTag(elementName, "p") {
            inParagraph = true
            paragraph = ""
        } else if isTag(elementName, "br") {
            // A break inside a paragraph is one line of a wrapped heading, not
            // the end of the thought — keep it on the same line.
            if inParagraph, !paragraph.isEmpty { paragraph += " " }
        } else if isTag(elementName, "t") {
            collecting = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if collecting, isTag(elementName, "t") {
            paragraph += buffer
            collecting = false
        } else if isTag(elementName, "p") {
            let value = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { parts.append(value) }
            inParagraph = false
            paragraph = ""
        } else if isTag(elementName, "sp") {
            // Take the first title placeholder only; a stray second one on a
            // layout-heavy slide shouldn't append itself to the heading.
            if shapeIsTitle, titleParts.isEmpty, parts.count > shapeStart {
                titleParts = Array(parts[shapeStart...])
            }
            shapeIsTitle = false
        }
    }
}

private extension String {
    var cleanDocumentText: String {
        replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
