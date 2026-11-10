import SwiftUI
import Vision
import PencilKit
import PDFKit

// Búsqueda dentro del cuaderno: letra manuscrita (reconocida con Vision),
// texto de los PDF y cuadros de texto.

func modDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

func recognizeText(_ image: CGImage) -> String {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["es-ES", "en-US"]
    req.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
    let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    return lines.joined(separator: "\n")
}

/// Texto manuscrito de una página. Se guarda en disco y solo se recalcula si la página cambió.
func inkText(dir: URL, page: Page) -> String {
    let d = dir.appendingPathComponent(page.id.uuidString + ".drawing")
    let t = dir.appendingPathComponent(page.id.uuidString + ".ocr")
    guard let dDate = modDate(d) else { return "" }
    if let tDate = modDate(t), tDate >= dDate, let s = try? String(contentsOf: t, encoding: .utf8) {
        return s
    }
    guard let data = try? Data(contentsOf: d), let drawing = try? PKDrawing(data: data),
          !drawing.strokes.isEmpty else { return "" }
    let b = drawing.bounds.insetBy(dx: -20, dy: -20)
    let scale: CGFloat = 2
    let size = CGSize(width: b.width * scale, height: b.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: size, format: format).image { r in
        UIColor.white.setFill()
        r.fill(CGRect(origin: .zero, size: size))
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: b, scale: scale)
        }
        ink.draw(in: CGRect(origin: .zero, size: size))
    }
    var text = ""
    if let cg = image.cgImage { text = recognizeText(cg) }
    try? text.write(to: t, atomically: true, encoding: .utf8)
    return text
}

func indexNotebook(dir: URL, nb: Notebook) -> [UUID: String] {
    var out: [UUID: String] = [:]
    var pdfs: [String: PDFDocument] = [:]
    for page in nb.pages {
        var parts: [String] = []
        for el in nb.elements where el.pageID == page.id && el.kind == .text {
            parts.append(el.text)
        }
        if let i = page.pdfIndex {
            let file = page.pdfFile ?? "source.pdf"
            if pdfs[file] == nil { pdfs[file] = PDFDocument(url: dir.appendingPathComponent(file)) }
            if let s = pdfs[file]?.page(at: i)?.string { parts.append(s) }
        }
        parts.append(inkText(dir: dir, page: page))
        out[page.id] = parts.joined(separator: "\n")
    }
    return out
}

struct SearchHit: Identifiable {
    let id: UUID
    let index: Int
    let snippet: String
}

struct SearchSheet: View {
    @ObservedObject var state: EditorState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var texts: [UUID: String] = [:]
    @State private var busy = true

    private var hits: [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let nb = state.nb else { return [] }
        var out: [SearchHit] = []
        for (i, p) in nb.pages.enumerated() {
            guard let t = texts[p.id],
                  let r = t.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let line = String(t[t.lineRange(for: r)]).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(SearchHit(id: p.id, index: i, snippet: line))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                if busy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Leyendo tus apuntes…").foregroundStyle(.secondary)
                    }
                }
                ForEach(hits) { hit in
                    Button {
                        state.controller?.scrollTo(hit.index, animated: false)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text("Pág. \(hit.index + 1)").bold()
                            Text(hit.snippet).lineLimit(2).foregroundStyle(.secondary)
                        }
                    }
                }
                if !busy && query.count >= 2 && hits.isEmpty {
                    Text("Sin resultados").foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Buscar en este cuaderno")
            .navigationTitle("Buscar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .task {
                state.controller?.flush()
                guard let nb = state.nb else {
                    busy = false
                    return
                }
                let dir = state.store.dir(nb.id)
                let result = await Task.detached(priority: .userInitiated) {
                    indexNotebook(dir: dir, nb: nb)
                }.value
                texts = result
                busy = false
            }
        }
    }
}
