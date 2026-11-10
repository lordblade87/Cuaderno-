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
    let audio: AudioModel

    init(store: Store, id: UUID) {
        self.store = store
        self.id = id
        settings = ToolSettings.load()
        audio = AudioModel(dir: store.dir(id))
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
        let th = textHeight(e.text, size: e.fontSize, width: e.w)
        e.h = e.bg == nil ? th : max(th, 120)
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
    @State private var showSearch = false
    @State private var showAudio = false
    @State private var showPhotos = false

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
            TabStrip(store: store, current: state.id)
            mainBar
            Divider()
            OptionsBar(state: state)
            HStack(spacing: 0) {
                if state.showSidebar {
                    PageSidebar(state: state, store: store)
                    Divider()
                }
                CanvasHost(state: state)
                    .overlay(alignment: .bottomLeading) {
                        Text("\(state.current + 1) de \(nb?.pages.count ?? 0)")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        if let p = state.paletteAt {
                            PaletteOverlay(state: state, at: p)
                        }
                    }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .sheet(item: $state.editing) { item in
            TextEditSheet(state: state, el: item)
        }
        .sheet(item: $share) { item in
            ActivityView(url: item.url)
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(state: state)
        }
        .sheet(isPresented: $showAudio) {
            AudioSheet(audio: state.audio)
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
        .onAppear {
            store.openTab(state.id)
        }
        .onDisappear {
            state.controller?.flush()
            state.audio.stop()
            state.audio.stopPlayback()
            let i = state.current
            store.mutate(state.id) { $0.lastIndex = i }
        }
    }

    // Barra principal: navegación, herramientas e insertar
    private var mainBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                bar("sidebar.left", on: state.showSidebar) {
                    state.controller?.flush()
                    withAnimation { state.showSidebar.toggle() }
                }
                bar("magnifyingglass") { showSearch = true }

                Divider().frame(height: 26).padding(.horizontal, 6)

                tool(.pen, "pencil.tip")
                tool(.highlighter, "highlighter")
                tool(.eraser, "eraser")
                tool(.shape, "triangle")
                tool(.lasso, "lasso")
                tool(.text, "textformat")
                tool(.hand, "hand.point.up.left")
                tool(.laser, "rays")

                Divider().frame(height: 26).padding(.horizontal, 6)

                Menu {
                    Button("Imagen de Fotos", systemImage: "photo") { showPhotos = true }
                    Button("Pegar imagen copiada", systemImage: "doc.on.clipboard") {
                        if let data = UIPasteboard.general.image?.pngData() {
                            state.controller?.insertImage(data)
                        }
                    }
                    Button("Nota adhesiva", systemImage: "note.text") { state.controller?.addSticky() }
                    Button("PDF después de esta página", systemImage: "doc.richtext") { showPDF = true }
                } label: {
                    ToolIcon(symbol: "photo.badge.plus", on: false)
                }

                AudioButton(audio: state.audio) { showAudio = true }
                    .frame(width: 40, height: 34)

                bar(isBookmarked ? "bookmark.fill" : "bookmark") { state.toggleBookmark() }

                Menu {
                    ForEach(Paper.allCases) { p in
                        Button("Página \(p.label.lowercased())") { state.controller?.addPage(p) }
                    }
                } label: {
                    ToolIcon(symbol: "doc.badge.plus", on: false)
                }

                Menu {
                    if !isPDFPage {
                        Menu("Papel de esta página") {
                            ForEach(Paper.allCases) { p in
                                Button(p.label) { state.controller?.setPaper(p) }
                            }
                        }
                        Button("Girar página (vertical / apaisada)", systemImage: "rotate.right") {
                            state.controller?.toggleLandscape()
                        }
                    }
                    Toggle("Regla", isOn: $state.ruler)
                    Button("Duplicar página", systemImage: "plus.square.on.square") {
                        state.controller?.duplicatePage(state.current)
                    }
                    Button("Exportar cuaderno en PDF", systemImage: "square.and.arrow.up") { export(all: true) }
                    Button("Exportar solo esta página", systemImage: "doc") { export(all: false) }
                    if (nb?.pages.count ?? 0) > 1 {
                        Button("Eliminar página", systemImage: "trash", role: .destructive) {
                            state.controller?.deletePage(state.current)
                        }
                    }
                } label: {
                    ToolIcon(symbol: "ellipsis.circle", on: false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(.systemBackground))
    }

    private func bar(_ symbol: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ToolIcon(symbol: symbol, on: on)
        }
    }

    private func tool(_ t: ToolKind, _ symbol: String) -> some View {
        bar(symbol, on: state.tool == t) { state.select(t) }
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

// MARK: - Pestañas de cuadernos abiertos

struct TabStrip: View {
    @ObservedObject var store: Store
    let current: UUID?

    var body: some View {
        HStack(spacing: 0) {
            Button {
                store.path.removeAll()
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 34)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.tabs, id: \.self) { id in
                        if let nb = store.notebook(id) {
                            let on = id == current
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(coverColors[abs(nb.cover) % coverColors.count])
                                    .frame(width: 8, height: 8)
                                Text(nb.title)
                                    .lineLimit(1)
                                    .font(.subheadline.weight(on ? .semibold : .regular))
                                Spacer(minLength: 0)
                                Button {
                                    store.closeTab(id, current: current)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.secondary)
                                        .frame(width: 22, height: 22)
                                }
                            }
                            .padding(.leading, 12)
                            .padding(.trailing, 6)
                            .frame(width: 200, height: 32)
                            .background(on ? Color(.systemBackground) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                            .onTapGesture { store.switchTab(id) }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 3)
        .background(Color(.secondarySystemBackground))
    }
}

// MARK: - Barras de herramientas

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

extension PenType {
    var detail: String {
        switch self {
        case .fountain: return "Cambia con la presión y el giro del Pencil"
        case .ballpoint: return "Trazo parejo para escribir rápido"
        case .pencil: return "Grafito; inclinalo para sombrear"
        case .monoline: return "Grosor constante, ideal para croquis"
        case .watercolor: return "Translúcida, se acumula al pasar"
        case .crayon: return "Gruesa y con textura"
        }
    }

    var sampleWidth: CGFloat {
        switch self {
        case .fountain: return 3.5
        case .ballpoint: return 2
        case .pencil: return 2.5
        case .monoline: return 1.2
        case .watercolor: return 9
        case .crayon: return 6
        }
    }

    var sampleOpacity: Double {
        switch self {
        case .pencil: return 0.6
        case .watercolor: return 0.35
        case .crayon: return 0.85
        default: return 1
        }
    }
}

/// Muestra de trazo de cada lapicera.
struct PenSample: View {
    let type: PenType
    let color: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            Path { p in
                p.move(to: CGPoint(x: w * 0.06, y: h * 0.65))
                p.addCurve(to: CGPoint(x: w * 0.94, y: h * 0.35),
                           control1: CGPoint(x: w * 0.35, y: -h * 0.35),
                           control2: CGPoint(x: w * 0.6, y: h * 1.35))
            }
            .stroke(color.opacity(type.sampleOpacity),
                    style: StrokeStyle(lineWidth: type.sampleWidth,
                                       lineCap: type == .fountain ? .butt : .round,
                                       dash: type == .crayon ? [1.5, 1] : []))
        }
    }
}

/// Segunda barra: opciones de la herramienta activa (como la barra flotante de GoodNotes).
struct OptionsBar: View {
    @ObservedObject var state: EditorState
    @State private var showPens = false

    private var selectedItem: NoteItem? {
        guard let sel = state.selected else { return nil }
        return state.nb?.elements.first { $0.id == sel }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
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
                Divider().frame(height: 26)

                content

                if let item = selectedItem {
                    Divider().frame(height: 26)
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
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.25)))
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder private var content: some View {
        switch state.tool {
        case .pen, .shape:
            ForEach(PenType.allCases) { t in
                let on = state.settings.penType == t
                Button {
                    if on { showPens = true } else { state.settings.penType = t }
                } label: {
                    VStack(spacing: 0) {
                        PenSample(type: t, color: on ? Color(uiColor: UIColor(hex: state.currentColorHex)) : Color.primary)
                            .frame(width: 40, height: 22)
                        Text(t.label)
                            .font(.system(size: 9, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: 48, height: 40)
                    .background(on ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Button {
                showPens = true
            } label: {
                ToolIcon(symbol: "slider.horizontal.3", on: false)
            }
            .popover(isPresented: $showPens) {
                PenPicker(state: state)
            }
            Divider().frame(height: 26)
            WidthRow(state: state)
            ColorRow(state: state)
        case .highlighter:
            WidthRow(state: state)
            ColorRow(state: state)
        case .eraser:
            Picker("Goma", selection: $state.settings.eraserMode) {
                ForEach(EraserMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.menu)
            WidthRow(state: state)
        case .lasso:
            hint("Rodeá trazos con el lápiz para moverlos, copiarlos o borrarlos")
        case .text:
            hint("Tocá la página donde quieras escribir")
        case .hand:
            hint("Tocá un texto, nota o imagen para moverlo o cambiar su tamaño")
        case .laser:
            hint("Puntero láser: el trazo se borra solo")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 6)
    }
}

/// Menú completo de lapiceras: tipo, grosor y color.
struct PenPicker: View {
    @ObservedObject var state: EditorState

    private let presets = ["1A1A1A", "5C5C5C", "1E4FD8", "0A84FF", "1B8A3A", "34C759",
                           "D62828", "FF6B6B", "F28C28", "FFD60A", "7B2CBF", "FF4FA3"]

    private var width: Binding<Double> {
        Binding(
            get: { pick(state.settings.penWidths, state.settings.penWidth, 2.8) },
            set: { v in
                let i = state.settings.penWidth
                if state.settings.penWidths.indices.contains(i) { state.settings.penWidths[i] = v }
            }
        )
    }

    var body: some View {
        let current = Color(uiColor: UIColor(hex: pick(state.settings.penColors, state.settings.penColor, "1A1A1A")))
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Lapiceras").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(PenType.allCases) { t in
                        let on = state.settings.penType == t
                        Button {
                            state.settings.penType = t
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                PenSample(type: t, color: current).frame(height: 36)
                                Text(t.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                                Text(t.detail)
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: on ? 2 : 0))
                        }
                    }
                }

                Text("Grosor").font(.subheadline.weight(.semibold))
                HStack {
                    Slider(value: width, in: 0.5...12)
                    Text(String(format: "%.1f", width.wrappedValue))
                        .monospacedDigit()
                        .frame(width: 36)
                }

                Text("Color").font(.subheadline.weight(.semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(presets, id: \.self) { c in
                        Circle()
                            .fill(Color(uiColor: UIColor(hex: c)))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle()
                                    .stroke(Color.accentColor,
                                            lineWidth: pick(state.settings.penColors, state.settings.penColor, "") == c ? 3 : 0)
                                    .padding(-4)
                            )
                            .onTapGesture {
                                let i = state.settings.penColor
                                if state.settings.penColors.indices.contains(i) { state.settings.penColors[i] = c }
                            }
                    }
                }

                Toggle("Corregir formas al mantener el lápiz quieto", isOn: $state.settings.autoShape)
                    .font(.subheadline)
            }
            .padding(16)
        }
        .frame(width: 370, height: 560)
    }
}

struct ColorRow: View {
    @ObservedObject var state: EditorState

    var body: some View {
        if let colors = state.colorSlots {
            HStack(spacing: 9) {
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
                        .frame(width: 28, height: 32)
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
