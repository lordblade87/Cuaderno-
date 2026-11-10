import SwiftUI
import PencilKit
import PDFKit

// MARK: - App

@main
struct CuadernoApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $store.path) {
                LibraryView(store: store)
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .folder(let name):
                            LibraryView(store: store, folder: name)
                        case .notebook(let id):
                            EditorView(store: store, id: id).id(id)
                        }
                    }
            }
        }
    }
}

enum Route: Hashable {
    case folder(String)
    case notebook(UUID)
}

// MARK: - Modelo

enum Paper: String, Codable, CaseIterable, Identifiable {
    case blank, ruled, grid, dots, cornell, iso

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blank: return "Lisa"
        case .ruled: return "Rayada"
        case .grid: return "Cuadriculada"
        case .dots: return "Punteada"
        case .cornell: return "Cornell"
        case .iso: return "Isométrica"
        }
    }
}

struct Page: Codable, Identifiable, Equatable {
    var id = UUID()
    var paper: Paper = .ruled
    var pdfIndex: Int? = nil
    var pdfFile: String? = nil
    var bookmark: Bool? = nil
    var landscape: Bool? = nil
}

/// Cuadro de texto o imagen puesto sobre una página (coordenadas de la página).
struct NoteItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image }

    var id = UUID()
    var pageID: UUID
    var kind: Kind
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var text = ""
    var fontSize: Double = 18
    var color = "1A1A1A"
    var file = ""
    var bg: String? = nil

    init(pageID: UUID, kind: Kind, rect: CGRect, file: String = "") {
        self.pageID = pageID
        self.kind = kind
        self.x = Double(rect.minX)
        self.y = Double(rect.minY)
        self.w = Double(rect.width)
        self.h = Double(rect.height)
        self.file = file
    }

    var rect: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set {
            x = Double(newValue.minX)
            y = Double(newValue.minY)
            w = Double(newValue.width)
            h = Double(newValue.height)
        }
    }
}

struct Notebook: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var cover: Int = 0
    var folder: String? = nil
    var pages: [Page]
    var modified = Date()
    var lastIndex = 0
    var elements: [NoteItem] = []
    var favorite = false
}

// Lee también los cuadernos guardados por la versión 1 (que no tenían "elements").
extension Notebook {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        cover = try c.decodeIfPresent(Int.self, forKey: .cover) ?? 0
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        pages = try c.decode([Page].self, forKey: .pages)
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        lastIndex = try c.decodeIfPresent(Int.self, forKey: .lastIndex) ?? 0
        elements = try c.decodeIfPresent([NoteItem].self, forKey: .elements) ?? []
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
    }
}

struct Library: Codable {
    var folders: [String] = []
    var notebooks: [Notebook] = []
}

// MARK: - Almacenamiento (todo local, en Documentos de la app)

final class Store: ObservableObject {
    @Published var lib = Library() {
        didSet { saveLib() }
    }

    // Pestañas de cuadernos abiertos y navegación
    @Published var path: [Route] = []
    @Published var tabs: [UUID] = [] {
        didSet { UserDefaults.standard.set(tabs.map { $0.uuidString }, forKey: "tabs") }
    }

    let root: URL
    private var pdfCache: [String: PDFDocument] = [:]

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? Data(contentsOf: root.appendingPathComponent("library.json")),
           let saved = try? JSONDecoder().decode(Library.self, from: data) {
            lib = saved
        }
        let saved = UserDefaults.standard.stringArray(forKey: "tabs") ?? []
        let ids = Set(lib.notebooks.map { $0.id })
        tabs = saved.compactMap { UUID(uuidString: $0) }.filter { ids.contains($0) }
    }

    func openTab(_ id: UUID) {
        if !tabs.contains(id) { tabs.append(id) }
    }

    func switchTab(_ id: UUID) {
        if let last = path.last, case .notebook(let cur) = last {
            if cur != id { path[path.count - 1] = .notebook(id) }
        } else {
            path.append(.notebook(id))
        }
    }

    func closeTab(_ id: UUID, current: UUID?) {
        guard let i = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: i)
        guard id == current else { return }
        if tabs.isEmpty {
            if !path.isEmpty { path.removeLast() }
        } else {
            switchTab(tabs[min(i, tabs.count - 1)])
        }
    }

    private func saveLib() {
        if let data = try? JSONEncoder().encode(lib) {
            try? data.write(to: root.appendingPathComponent("library.json"), options: .atomic)
        }
    }

    func dir(_ id: UUID) -> URL {
        let url = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func notebook(_ id: UUID) -> Notebook? {
        lib.notebooks.first { $0.id == id }
    }

    func mutate(_ id: UUID, _ change: (inout Notebook) -> Void) {
        guard let i = lib.notebooks.firstIndex(where: { $0.id == id }) else { return }
        var nb = lib.notebooks[i]
        change(&nb)
        nb.modified = Date()
        lib.notebooks[i] = nb
    }

    func create(title: String, cover: Int, paper: Paper, folder: String?) {
        let t = title.trimmingCharacters(in: .whitespaces)
        let nb = Notebook(title: t.isEmpty ? "Sin título" : t, cover: cover, folder: folder, pages: [Page(paper: paper)])
        lib.notebooks.insert(nb, at: 0)
    }

    func importPDF(_ url: URL, folder: String?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var nb = Notebook(title: url.deletingPathExtension().lastPathComponent, cover: 5, folder: folder, pages: [])
        let dest = dir(nb.id).appendingPathComponent("source.pdf")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            return
        }
        guard let doc = PDFDocument(url: dest), doc.pageCount > 0 else { return }
        nb.pages = (0..<doc.pageCount).map { Page(paper: .blank, pdfIndex: $0) }
        pdfCache[nb.id.uuidString + "/source.pdf"] = doc
        lib.notebooks.insert(nb, at: 0)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: dir(id))
        pdfCache = pdfCache.filter { !$0.key.hasPrefix(id.uuidString) }
        lib.notebooks.removeAll { $0.id == id }
        tabs.removeAll { $0 == id }
    }

    /// Inserta las páginas de un PDF dentro de un cuaderno existente.
    func insertPDF(_ url: URL, into id: UUID, at index: Int) -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = UUID().uuidString + ".pdf"
        let dest = dir(id).appendingPathComponent(file)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            return 0
        }
        guard let doc = PDFDocument(url: dest), doc.pageCount > 0 else { return 0 }
        let pages = (0..<doc.pageCount).map { Page(paper: .blank, pdfIndex: $0, pdfFile: file) }
        mutate(id) { nb in
            nb.pages.insert(contentsOf: pages, at: min(max(index, 0), nb.pages.count))
        }
        return pages.count
    }

    // Carpetas: se guardan como ruta ("Facultad/Estructuras III")
    func addFolder(_ name: String, parent: String? = nil) {
        let t = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !t.isEmpty else { return }
        var path = t
        if let parent = parent { path = parent + "/" + t }
        guard !lib.folders.contains(path) else { return }
        lib.folders.append(path)
    }

    func deleteFolder(_ path: String) {
        var copy = lib
        let parent = folderParent(path)
        func inside(_ f: String) -> Bool { f == path || f.hasPrefix(path + "/") }
        copy.folders.removeAll { inside($0) }
        for i in copy.notebooks.indices {
            if let f = copy.notebooks[i].folder, inside(f) {
                copy.notebooks[i].folder = parent
            }
        }
        lib = copy
    }

    // Tinta de cada página
    func drawingURL(_ nb: UUID, _ page: UUID) -> URL {
        dir(nb).appendingPathComponent(page.uuidString + ".drawing")
    }

    func loadDrawing(_ nb: UUID, _ page: UUID) -> PKDrawing {
        guard let data = try? Data(contentsOf: drawingURL(nb, page)),
              let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        return drawing
    }

    // PDF de fondo
    func pdf(_ nb: UUID, _ file: String = "source.pdf") -> PDFDocument? {
        let key = nb.uuidString + "/" + file
        if let cached = pdfCache[key] { return cached }
        let doc = PDFDocument(url: dir(nb).appendingPathComponent(file))
        pdfCache[key] = doc
        return doc
    }

    func pdfPage(_ nb: UUID, _ page: Page) -> PDFPage? {
        guard let i = page.pdfIndex else { return nil }
        return pdf(nb, page.pdfFile ?? "source.pdf")?.page(at: i)
    }

    func pageSize(_ nb: UUID, _ page: Page) -> CGSize {
        if let p = pdfPage(nb, page) {
            let b = p.bounds(for: .cropBox)
            if b.width > 10, b.height > 10 {
                return p.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
            }
        }
        return page.landscape == true ? CGSize(width: 842, height: 595) : CGSize(width: 595, height: 842) // A4
    }
}

// MARK: - Utilidades

func folderParent(_ path: String) -> String? {
    guard let r = path.range(of: "/", options: .backwards) else { return nil }
    return String(path[..<r.lowerBound])
}

func folderTitle(_ path: String) -> String {
    path.components(separatedBy: "/").last ?? path
}

extension UIColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }
}

func textHeight(_ text: String, size: Double, width: Double) -> Double {
    let r = (text as NSString).boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: UIFont.systemFont(ofSize: CGFloat(size))],
        context: nil)
    return Double(ceil(r.height)) + 6
}

// MARK: - Dibujo de páginas (pantalla, miniaturas y exportación)

func drawPaper(in ctx: CGContext, size: CGSize, paper: Paper, pdfPage: PDFPage?) {
    ctx.setFillColor(UIColor.white.cgColor)
    ctx.fill(CGRect(origin: .zero, size: size))

    if let p = pdfPage {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        p.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        return
    }

    let line = UIColor(red: 0.55, green: 0.67, blue: 0.82, alpha: 0.75).cgColor
    ctx.setStrokeColor(line)
    ctx.setFillColor(line)
    ctx.setLineWidth(0.5)
    let step: CGFloat = 14.17 // 5 mm

    func hLine(_ y: CGFloat, from x0: CGFloat = 0, to x1: CGFloat? = nil) {
        ctx.move(to: CGPoint(x: x0, y: y))
        ctx.addLine(to: CGPoint(x: x1 ?? size.width, y: y))
    }

    switch paper {
    case .blank:
        break
    case .ruled:
        var y: CGFloat = 56
        while y < size.height - 16 {
            hLine(y)
            y += 24
        }
        ctx.strokePath()
    case .grid:
        var x = step
        while x < size.width {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y = step
        while y < size.height {
            hLine(y)
            y += step
        }
        ctx.strokePath()
    case .dots:
        var y = step
        while y < size.height {
            var x = step
            while x < size.width {
                ctx.fillEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                x += step
            }
            y += step
        }
    case .cornell:
        let top: CGFloat = 70
        let bottom = size.height * 0.8
        let margin = size.width * 0.28
        var y = top + 24
        while y < bottom - 4 {
            hLine(y, from: margin)
            y += 24
        }
        ctx.strokePath()
        ctx.setLineWidth(1)
        hLine(top)
        hLine(bottom)
        ctx.move(to: CGPoint(x: margin, y: top))
        ctx.addLine(to: CGPoint(x: margin, y: bottom))
        ctx.strokePath()
    case .iso:
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))
        let dx = step * 0.866
        var x = dx
        while x < size.width {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: size.height))
            x += dx
        }
        let rise = size.width * 0.5774
        var c = -rise
        while c < size.height + rise {
            ctx.move(to: CGPoint(x: 0, y: c))
            ctx.addLine(to: CGPoint(x: size.width, y: c + rise))
            ctx.move(to: CGPoint(x: 0, y: c))
            ctx.addLine(to: CGPoint(x: size.width, y: c - rise))
            c += step
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// La tinta siempre se dibuja como en papel blanco (sin invertir colores en modo oscuro).
func inkImage(_ drawing: PKDrawing, size: CGSize, scale: CGFloat) -> UIImage {
    var image = UIImage()
    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
        image = drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
    }
    return image
}

/// Textos e imágenes de una página (en el contexto gráfico actual).
func drawElements(_ store: Store, _ nb: Notebook, _ page: Page) {
    let folder = store.dir(nb.id)
    for el in nb.elements where el.pageID == page.id {
        switch el.kind {
        case .image:
            if let img = UIImage(contentsOfFile: folder.appendingPathComponent(el.file).path) {
                img.draw(in: el.rect)
            }
        case .text:
            if let bg = el.bg {
                UIColor(hex: bg).setFill()
                UIRectFill(el.rect)
            }
            (el.text as NSString).draw(
                with: el.rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.systemFont(ofSize: CGFloat(el.fontSize)),
                             .foregroundColor: UIColor(hex: el.color)],
                context: nil)
        }
    }
}

func renderPage(_ store: Store, _ nb: Notebook, _ page: Page, width: CGFloat) -> UIImage {
    let size = store.pageSize(nb.id, page)
    let k = width / size.width
    let drawing = store.loadDrawing(nb.id, page.id)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: size.height * k))
    return renderer.image { r in
        r.cgContext.scaleBy(x: k, y: k)
        drawPaper(in: r.cgContext, size: size, paper: page.paper, pdfPage: store.pdfPage(nb.id, page))
        drawElements(store, nb, page)
        if !drawing.strokes.isEmpty {
            inkImage(drawing, size: size, scale: k * 2).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

func exportPDF(_ store: Store, _ nb: Notebook, only: [Page]? = nil) -> URL? {
    var name = nb.title.replacingOccurrences(of: "/", with: "-")
    if name.isEmpty { name = "Cuaderno" }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".pdf")
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
    do {
        try renderer.writePDF(to: url) { ctx in
            for page in only ?? nb.pages {
                autoreleasepool {
                    let size = store.pageSize(nb.id, page)
                    let rect = CGRect(origin: .zero, size: size)
                    ctx.beginPage(withBounds: rect, pageInfo: [:])
                    drawPaper(in: ctx.cgContext, size: size, paper: page.paper, pdfPage: store.pdfPage(nb.id, page))
                    drawElements(store, nb, page)
                    let drawing = store.loadDrawing(nb.id, page.id)
                    if !drawing.strokes.isEmpty {
                        inkImage(drawing, size: size, scale: 3).draw(in: rect)
                    }
                }
            }
        }
        return url
    } catch {
        return nil
    }
}
