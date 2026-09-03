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
                let title = firstUsefulLine(in: text)
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
            let slideText = xmlText(read(entry, from: archive)).cleanDocumentText
            let notesPath = "ppt/notesSlides/notesSlide\(number).xml"
            let notes = archive[notesPath].map { xmlText(read($0, from: archive)).cleanDocumentText } ?? ""
            let title = firstUsefulLine(in: slideText)
            let thumb = slideThumbnail(title: title, body: slideText, number: number)
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

    private static func xmlText(_ data: Data) -> String {
        let delegate = SlideXMLTextDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.parts.joined(separator: "\n")
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
            let remainder = body.replacingOccurrences(of: title, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            String(remainder.prefix(520)).draw(in: CGRect(x: 48, y: 142, width: 620, height: 210),
                                               withAttributes: bodyAttributes)
        }
        return image.jpegData(compressionQuality: 0.78)
    }

    private static func firstUsefulLine(in text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.count >= 3 }
            .map { String($0.prefix(100)) } ?? ""
    }
}

private final class SlideXMLTextDelegate: NSObject, XMLParserDelegate {
    var parts: [String] = []
    private var collecting = false
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "a:t" || elementName.hasSuffix(":t") {
            collecting = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if collecting, elementName == "a:t" || elementName.hasSuffix(":t") {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { parts.append(value) }
            collecting = false
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
