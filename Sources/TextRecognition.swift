// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Vision

// MARK: - Text recognition (OCR) with Vision

enum TextRecognizer {
    /// Recognizes the text in an image, line by line in reading order. Calls back on the main queue.
    static func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
        let request = VNRecognizeTextRequest { req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { obs -> (CGRect, String)? in
                    guard let text = obs.topCandidates(1).first?.string else { return nil }
                    return (obs.boundingBox, text)
                }
            let text = join(lines)
            DispatchQueue.main.async { completion(text) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        // Screenshots often have small UI text.
        request.minimumTextHeight = 0
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                DispatchQueue.main.async { completion("") }
            }
        }
    }

    /// Orders the recognized lines top to bottom, then left to right. Lines that sit on the same row
    /// (like table cells) are joined with a tab; rows are joined with new lines.
    static func join(_ lines: [(CGRect, String)]) -> String {
        // Vision's coordinates are normalized with the origin at the bottom-left.
        let sorted = lines.sorted { $0.0.midY > $1.0.midY }
        var rows: [[(CGRect, String)]] = []
        for line in sorted {
            if let last = rows.last?.last, abs(last.0.midY - line.0.midY) < min(last.0.height, line.0.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows
            .map { $0.sorted { $0.0.minX < $1.0.minX }.map(\.1).joined(separator: "\t") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
