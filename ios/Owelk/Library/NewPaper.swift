import CryptoKit
import Foundation
import PDFKit

/// A PDF added on the iPad, with what can be told about it here. The computers read the rest of its details (authors,
/// year, DOI, arXiv) from the file themselves: its row leaves `metadata_origin` empty, which asks them to.
struct NewPaper {
    let data: Data
    /// The file's name, which the computers give their copy.
    let name: String
    let sha256: String
    /// The title the PDF declares, when it looks like one.
    let title: String

    /// nil when the data is not a PDF that opens.
    init?(data: Data, name: String) {
        guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil, let document = PDFDocument(data: data),
              document.pageCount > 0 else { return nil }
        self.data = data
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self.name = Self.fileName(name, sha256: sha256)
        let declared = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        title = Self.usableTitle(declared, fileName: self.name) ? Self.simplified(declared) : ""
    }

    /// A name the computers accept for the file: no folders, ending in .pdf.
    static func fileName(_ name: String, sha256: String) -> String {
        var base = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasPrefix(".") { base = "" }
        if base.isEmpty { return String(sha256.prefix(16)) + ".pdf" }
        return base.lowercased().hasSuffix(".pdf") ? base : base + ".pdf"
    }

    /// As the desktop's `PaperMetadataText::usableTitle`: a declared title that is not a file name, a producer's
    /// default or a placeholder.
    static func usableTitle(_ input: String, fileName: String) -> Bool {
        let title = simplified(input)
        let lower = title.lowercased()
        guard (4...300).contains(title.count) else { return false }
        if lower.range(of: #"\.(pdf|docx?|tex|dvi|ps|indd|qxd)$"#, options: .regularExpression) != nil
            || lower.range(of: #"^(/|[a-z]:\\)"#, options: .regularExpression) != nil { return false }
        for prefix in ["microsoft word -", "microsoft powerpoint -", "untitled", "arxiv:", "doi:", "pii:"]
        where lower.hasPrefix(prefix) { return false }
        if lower.range(of: #"^(title|paper|manuscript|document|slides|presentation|main|draft)[\s_\-\d]*$"#,
                       options: .regularExpression) != nil { return false }
        if lower == ((fileName as NSString).deletingPathExtension).lowercased() { return false }
        return title.filter(\.isLetter).count >= 4
    }

    private static func simplified(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
