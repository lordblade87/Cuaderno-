import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Estado del editor

final class EditorState: ObservableObject {
    let store: Store
    let id: UUID

    @Published var tool: ToolKind = .pen
    @Published var settings: ToolSettings {
        didSet { settings.save() }
    }
    @Published var current = 0
    @Published var selected: UUID?
    @Published var showSidebar = false
    @Published var paletteAt: CGPoint?
    @Published var editing: NoteItem?
    @Published var editingIsNew = false
    @Published var ruler = false
    @Published var thumbs = 0

    private var previousTool: ToolKind = .eraser
    weak var controller: CanvasController?

    init(store: Store, id: UUID) {
        self.store = store
        self.id = id
        settings = ToolSettings.load()
    }

    var nb: Notebook? { store.notebook(id) }

    func select(_ t: ToolKind) {
        if t != tool {
            previousTool = tool
            tool = t
        }
        if t != .hand && t != .text { selected = nil }
    }

    func toggleEraser() {
        if tool == .eraser {
            select(previousTool == .eraser ? .pen : previousTool)
        } else {
            select(.eraser)
        }
    }

    func switchPrevious() {
        select(previousTool)
    }

    // Colores y grosores de la herramienta actual
    var colorSlots: [String]? {
        switch tool {
        case .pen, .shape: return settings.penColors
        case .highlighter: return settings.hlColors
        default: return nil
        }
    }

    var colorIndex: Int { tool == .highlighter ? settings.hlColor : settings.penColor }

    var currentColorHex: String {
        pick(colorSlots ?? settings.penColors, colorIndex, "1A1A1A")
    }

    func pickColor(_ i: Int) {
        if tool == .highlighter { settings.hlColor = i } else { settings.penColor = i }
    }

    func setColor(_ hex: String) {
        if tool == .highlighter {
            if settings.hlColors.indices.contains(settings.hlColor) { settings.hlColors[settings.hlColor] = hex }
        } else {
            if settings.penColors.indices.contains(settings.penColor) { settings.penColors[settings.penColor] = hex }
        }
    }

    var widthSlots: [Double]? {
        switch tool {
        case .pen, .shape: return settings.penWidths
        case .highlighter: return settings.hlWidths
        case .eraser: return settings.eraserWidths
        default: return nil
        }
    }

    var widthIndex: Int {
        switch tool {
        case .highlighter: return settings.hlWidth
        case .eraser: return settings.eraserWidth
        default: return settings.penWidth
        }
    }

    func pickWidth(_ i: Int) {
        switch tool {
        case .highlighter: settings.hlWidth = i
        case .eraser: settings.eraserWidth = i
        default: settings.penWidth = i
        }
    }

    // Textos e imágenes
    func commitText(_ item: NoteItem) {
        var e = item
        let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            changeElements { list in list.removeAll { $0.id == item.id } }
            return
        }
        e.h = textHeight(e.text, size: e.fontSize, width: e.w)
        settings.textSize = e.fontSize
        let final = e
        changeElements { list in
            if let i = list.firstIndex(where: { $0.id == final.id }) {
                list[i] = final
            } else {
                list.append(final)
            }
        }
    }

    func deleteElement(_ eid: UUID) {
        changeElements { list in list.removeAll { $0.id == eid } }
        selected = nil
    }

    /// Cambia textos/imágenes y lo registra para deshacer/rehacer.
    func changeElements(_ change: (inout [NoteItem]) -> Void) {
        guard let old = nb?.elements else { return }
        var new = old
        change(&new)
        applyElements(new, undo: old)
    }

    private func applyElements(_ new: [NoteItem], undo old: [NoteItem]) {
        store.mutate(id) { nb in nb.elements = new }
        controller?.canvas.undoManager?.registerUndo(withTarget: self) { s in
            s.applyElements(old, undo: new)
        }
    }

    func toggleBookmark() {
        let i = current
        store.mutate(id) { nb in
            if nb.pages.indices.contains(i) {
                nb.pages[i].bookmark = !(nb.pages[i].bookmark ?? false)
            }
        }
    }

    func movePages(_ from: IndexSet, _ to: Int) {
        controller?.flush()
        store.mutate(id) { $0.pages.move(fromOffsets: from, toOffset: to) }
        controller?.reload()
        thumbs += 1
    }
}

// MARK: - Vista del editor

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct EditorView: View {
    @ObservedObject var store: Store
    @StateObject private var state: EditorState
    @State private var photo: PhotosPickerItem?
    @State private var share: ShareItem?
    @State private var showPDF = false

    init(store: Store, id: UUID) {
        self.store = store
        _state = StateObject(wrappedValue: EditorState(store: store, id: id))
    }

    private var nb: Notebook? { store.notebook(state.id) }

    private var isBookmarked: Bool {
        guard let nb = nb, nb.pages.indices.contains(state.current) else { return false }
        return nb.pages[state.current].bookmark == true
    }

    private var isPDFPage: Bool {
        guard let nb = nb, nb.pages.indices.contains(state.current) else { return false }
        return nb.pages[state.current].pdfIndex != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolBar(state: state, photo: $photo)
            Divider()
            HStack(spacing: 0) {
                if state.showSidebar {
                    PageSidebar(state: state, store: store)
                    Divider()
                }
                CanvasHost(state: state)
                    .overlay {
                        if let p = state.paletteAt {
                            PaletteOverlay(state: state, at: p)
                        }
                    }
            }
        }
        .navigationTitle(nb?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    state.controller?.flush()
                    withAnimation { state.showSidebar.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Text("\(state.current + 1)/\(nb?.pages.count ?? 0)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    state.toggleBookmark()
                } label: {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                }

                Menu {
                    ForEach(Paper.allCases) { p in
                        Button("Página \(p.label.lowercased())") { state.controller?.addPage(p) }
                    }
                } label: {
                    Image(systemName: "doc.badge.plus")
                }

                Menu {
                    if !isPDFPage {
                        Menu("Papel de esta página") {
                            ForEach(Paper.allCases) { p in
                                Button(p.label) { state.controller?.setPaper(p) }
                            }
                        }
                    }
                    Toggle("Regla", isOn: $state.ruler)
                    Toggle("Formas al mantener el lápiz", isOn: $state.settings.autoShape)
                    Button("Duplicar página", systemImage: "plus.square.on.square") {
                        state.controller?.duplicatePage(state.current)
                    }
                    Button("Insertar PDF después de esta página", systemImage: "doc.badge.plus") { showPDF = true }
                    Button("Exportar cuaderno en PDF", systemImage: "square.and.arrow.up") { export(all: true) }
                    Button("Exportar solo esta página", systemImage: "doc") { export(all: false) }
                    if (nb?.pages.count ?? 0) > 1 {
                        Button("Eliminar página", systemImage: "trash", role: .destructive) {
                            state.controller?.deletePage(state.current)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $state.editing) { item in
            TextEditSheet(state: state, el: item)
        }
        .sheet(item: $share) { item in
            ActivityView(url: item.url)
        }
        .fileImporter(isPresented: $showPDF, allowedContentTypes: [UTType.pdf]) { result in
            if case .success(let url) = result {
                state.controller?.insertPDF(url)
            }
        }
        .onChange(of: photo) { _, item in
            guard let item = item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let data = data { state.controller?.insertImage(data) }
                    photo = nil
                }
            }
        }
        .onDisappear {
            state.controller?.flush()
            let i = state.current
            store.mutate(state.id) { $0.lastIndex = i }
        }
    }

    private func export(all: Bool) {
        state.controller?.flush()
        guard let nb = nb else { return }
        var only: [Page]? = nil
        if !all, nb.pages.indices.contains(state.current) {
            only = [nb.pages[state.current]]
        }
        if let url = exportPDF(store, nb, only: only) {
            share = ShareItem(url: url)
        }
    }
}

// MARK: - Barra de herramientas (estilo GoodNotes)

struct ToolIcon: View {
    let symbol: String
    let on: Bool
    var tint: Color = .primary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .frame(width: 40, height: 34)
            .foregroundStyle(on ? Color.accentColor : tint)
            .background(on ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ToolBar: View {
    @ObservedObject var state: EditorState
    @Binding var photo: PhotosPickerItem?

    private var selectedItem: NoteItem? {
        guard let sel = state.selected else { return nil }
        return state.nb?.elements.first { $0.id == sel }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Menu {
                    Picker("Tipo de lapicera", selection: $state.settings.penType) {
                        ForEach(PenType.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    Toggle("Formas al mantener el lápiz", isOn: $state.settings.autoShape)
                } label: {
                    ToolIcon(symbol: "pencil.tip", on: state.tool == .pen)
                } primaryAction: {
                    state.select(.pen)
                }

                toolButton(.highlighter, "highlighter")

                Menu {
                    Picker("Goma", selection: $state.settings.eraserMode) {
                        ForEach(EraserMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                } label: {
                    ToolIcon(symbol: "eraser", on: state.tool == .eraser)
                } primaryAction: {
                    state.select(.eraser)
                }

                toolButton(.shape, "triangle")
                toolButton(.lasso, "lasso")
                toolButton(.text, "textformat")

                PhotosPicker(selection: $photo, matching: .images) {
                    ToolIcon(symbol: "photo", on: false)
                }

                toolButton(.hand, "hand.point.up.left")
                toolButton(.laser, "rays")

                Divider().frame(height: 26).padding(.horizontal, 6)

                ColorRow(state: state)
                WidthRow(state: state)

                if let item = selectedItem {
                    if item.kind == .text {
                        Button {
                            state.editingIsNew = false
                            state.editing = item
                        } label: {
                            ToolIcon(symbol: "pencil.line", on: false)
                        }
                    }
                    Button {
                        state.deleteElement(item.id)
                    } label: {
                        ToolIcon(symbol: "trash", on: false, tint: .red)
                    }
                }

                Divider().frame(height: 26).padding(.horizontal, 6)

                Button {
                    state.controller?.undo()
                } label: {
                    ToolIcon(symbol: "arrow.uturn.backward", on: false)
                }
                Button {
                    state.controller?.redo()
                } label: {
                    ToolIcon(symbol: "arrow.uturn.forward", on: false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(.systemBackground))
    }

    private func toolButton(_ t: ToolKind, _ symbol: String) -> some View {
        Button {
            state.select(t)
        } label: {
            ToolIcon(symbol: symbol, on: state.tool == t)
        }
    }
}

struct ColorRow: View {
    @ObservedObject var state: EditorState

    var body: some View {
        if let colors = state.colorSlots {
            HStack(spacing: 10) {
                ForEach(colors.indices, id: \.self) { i in
                    Circle()
                        .fill(Color(uiColor: UIColor(hex: colors[i])))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor, lineWidth: state.colorIndex == i ? 2.5 : 0)
                                .padding(-4)
                        )
                        .contentShape(Circle())
                        .onTapGesture { state.pickColor(i) }
                }
                ColorPicker("", selection: Binding(
                    get: { Color(uiColor: UIColor(hex: state.currentColorHex)) },
                    set: { state.setColor(UIColor($0).hex) }
                ), supportsOpacity: false)
                .labelsHidden()
            }
            .padding(.horizontal, 6)
        }
    }
}

struct WidthRow: View {
    @ObservedObject var state: EditorState

    var body: some View {
        if let widths = state.widthSlots {
            HStack(spacing: 2) {
                ForEach(widths.indices, id: \.self) { i in
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 5 + CGFloat(i) * 5, height: 5 + CGFloat(i) * 5)
                        .frame(width: 32, height: 32)
                        .background(state.widthIndex == i ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture { state.pickWidth(i) }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Paleta flotante (apretar el Apple Pencil Pro)

struct PaletteOverlay: View {
    @ObservedObject var state: EditorState
    let at: CGPoint

    private let tools: [(ToolKind, String)] = [
        (.pen, "pencil.tip"), (.highlighter, "highlighter"), (.eraser, "eraser"),
        (.shape, "triangle"), (.lasso, "lasso"), (.text, "textformat")
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.001)
                    .onTapGesture { state.paletteAt = nil }

                VStack(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(tools, id: \.0) { item in
                            Button {
                                state.select(item.0)
                                state.paletteAt = nil
                            } label: {
                                ToolIcon(symbol: item.1, on: state.tool == item.0)
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        ColorRow(state: state)
                        WidthRow(state: state)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                .position(x: min(max(at.x, 170), max(geo.size.width - 170, 170)),
                          y: min(max(at.y - 90, 60), max(geo.size.height - 60, 60)))
            }
        }
    }
}

// MARK: - Panel lateral de páginas

struct PageSidebar: View {
    @ObservedObject var state: EditorState
    @ObservedObject var store: Store
    @State private var onlyMarked = false

    var body: some View {
        let pages = store.notebook(state.id)?.pages ?? []
        let rows = Array(pages.enumerated()).filter { !onlyMarked || $0.element.bookmark == true }
        VStack(spacing: 0) {
        Toggle("Solo marcadas", isOn: $onlyMarked)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        List {
            ForEach(rows, id: \.element.id) { item in
                VStack(spacing: 4) {
                    Thumb(store: store, nbID: state.id, page: item.element, version: state.thumbs)
                    Text(item.element.bookmark == true ? "🔖 \(item.offset + 1)" : "\(item.offset + 1)").font(.caption)
                }
                .padding(6)
                .background(item.offset == state.current ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { state.controller?.scrollTo(item.offset, animated: true) }
                .contextMenu {
                    Button("Duplicar", systemImage: "plus.square.on.square") {
                        state.controller?.duplicatePage(item.offset)
                    }
                    if pages.count > 1 {
                        Button("Eliminar", systemImage: "trash", role: .destructive) {
                            state.controller?.deletePage(item.offset)
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }
            .onMove { from, to in
                if !onlyMarked { state.movePages(from, to) }
            }
        }
        .listStyle(.plain)
        }
        .frame(width: 170)
    }
}

struct Thumb: View {
    let store: Store
    let nbID: UUID
    let page: Page
    let version: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.white.aspectRatio(0.707, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4), lineWidth: 1))
        .task(id: "\(page.id)-\(page.paper.rawValue)-\(version)") {
            if let nb = store.notebook(nbID) {
                image = renderPage(store, nb, page, width: 300)
            }
        }
    }
}

// MARK: - Edición de texto

struct TextEditSheet: View {
    @ObservedObject var state: EditorState
    @State var el: NoteItem
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private let colors = ["1A1A1A", "1E4FD8", "D62828", "1B8A3A", "7B2CBF"]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $el.text)
                    .focused($focused)
                    .font(.system(size: CGFloat(el.fontSize)))
                    .foregroundStyle(Color(uiColor: UIColor(hex: el.color)))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.3)))
                    .frame(minHeight: 180)

                HStack {
                    Text("Tamaño")
                    Slider(value: $el.fontSize, in: 10...48, step: 1)
                    Text("\(Int(el.fontSize))").monospacedDigit().frame(width: 32)
                }

                HStack(spacing: 14) {
                    ForEach(colors, id: \.self) { c in
                        Circle()
                            .fill(Color(uiColor: UIColor(hex: c)))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: el.color == c ? 3 : 0).padding(-4))
                            .onTapGesture { el.color = c }
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Texto")
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") {
                        state.commitText(el)
                        dismiss()
                    }
                }
                if !state.editingIsNew {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Eliminar texto", role: .destructive) {
                            state.deleteElement(el.id)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Compartir y puente con UIKit

struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct CanvasHost: UIViewControllerRepresentable {
    let state: EditorState

    func makeUIViewController(context: Context) -> CanvasController {
        let controller = CanvasController(state: state)
        state.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: CanvasController, context: Context) {}
}
