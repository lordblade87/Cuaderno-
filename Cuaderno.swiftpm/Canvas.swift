import UIKit
import PencilKit
import PDFKit
import Combine

// MARK: - Fondo de una página

final class PageView: UIView {
    private(set) var renderedZoom: CGFloat = 0
    private var size = CGSize(width: 595, height: 842)
    private var paper = Paper.blank
    private var pdfPage: PDFPage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .white
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }

    func configure(size: CGSize, paper: Paper, pdfPage: PDFPage?) {
        self.size = size
        self.paper = paper
        self.pdfPage = pdfPage
    }

    func render(zoom: CGFloat, screenScale: CGFloat) {
        let w = min(max(size.width * zoom * screenScale, 400), 2400)
        let k = w / size.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: size.height * k), format: format)
        let image = renderer.image { r in
            r.cgContext.scaleBy(x: k, y: k)
            drawPaper(in: r.cgContext, size: size, paper: paper, pdfPage: pdfPage)
        }
        layer.contents = image.cgImage
        renderedZoom = zoom
    }
}

// MARK: - Texto o imagen sobre la página

final class ElementView: UIView {
    private let label = UILabel()
    private let imageView = UIImageView()
    private let handle = UIView()
    private(set) var zoom: CGFloat = 0
    private var loadedFile = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        addSubview(label)
        handle.backgroundColor = .systemBlue
        handle.layer.cornerRadius = 8
        handle.layer.borderColor = UIColor.white.cgColor
        handle.layer.borderWidth = 2
        handle.isHidden = true
        addSubview(handle)
        layer.borderColor = UIColor.systemBlue.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("no se usa")
    }

    func configure(_ el: NoteItem, dir: URL, zoom z: CGFloat, selected: Bool) {
        switch el.kind {
        case .image:
            label.isHidden = true
            imageView.isHidden = false
            if loadedFile != el.file {
                imageView.image = UIImage(contentsOfFile: dir.appendingPathComponent(el.file).path)
                loadedFile = el.file
            }
        case .text:
            imageView.isHidden = true
            label.isHidden = false
            label.text = el.text
            label.textColor = UIColor(hex: el.color)
            label.font = .systemFont(ofSize: max(CGFloat(el.fontSize) * z, 1))
        }
        zoom = z
        layer.borderWidth = selected ? 1.5 : 0
        handle.isHidden = !selected
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        label.frame = bounds
        handle.frame = CGRect(x: bounds.maxX - 8, y: bounds.maxY - 8, width: 16, height: 16)
    }
}

// MARK: - Editor: páginas en scroll continuo + PencilKit + Apple Pencil Pro

final class CanvasController: UIViewController, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let state: EditorState
    let canvas = PKCanvasView()

    private let paperLayer = UIView()
    private let elementLayer = UIView()
    private var pageViews: [UUID: PageView] = [:]
    private var elementViews: [UUID: ElementView] = [:]
    private var elements: [UUID: NoteItem] = [:]
    private var layout: [(page: Page, rect: CGRect)] = []
    private var origins: [UUID: CGPoint] = [:]
    private var docSize = CGSize(width: 595, height: 842)
    private var savedData: [UUID: Data] = [:]
    private var dirty = false
    private var ignoreChange = false
    private var strokeCount = 0
    private var saveWork: DispatchWorkItem?
    private var lastSize = CGSize.zero
    private var initialIndex = 0
    private var bag = Set<AnyCancellable>()
    private let tapGR = UITapGestureRecognizer()
    private let moveGR = UIPanGestureRecognizer()
    private var touchStart = CGPoint.zero
    private var drag: (id: UUID, start: CGRect, resize: Bool)?
    private var dragRect: CGRect?
    private lazy var feedback = UICanvasFeedbackGenerator(view: view)
    private lazy var folder = store.dir(nbID)
    private let gap: CGFloat = 20

    // Lápiz: forma al mantener, puntero láser y goma de resaltador
    private let pencilGR = UIPanGestureRecognizer()
    private let overlay = UIView()
    private let previewLayer = CAShapeLayer()
    private let laserLayer = CAShapeLayer()
    private var strokePts: [CGPoint] = []
    private var holdAnchor = CGPoint.zero
    private var holdWork: DispatchWorkItem?
    private var pendingOutline: [CGPoint]?
    private var laserPath = UIBezierPath()
    private var laserWork: DispatchWorkItem?

    // Deslizar al costado y mantener para crear una página
    private let pullLabel = UILabel()
    private let pullBar = UIView()
    private var pullWork: DispatchWorkItem?
    private var pullDone = false

    private var store: Store { state.store }
    private var nbID: UUID { state.id }
    private var screenScale: CGFloat { max(traitCollection.displayScale, 2) }

    init(state: EditorState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("no se usa")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        view.clipsToBounds = true

        for layerView in [paperLayer, elementLayer] {
            layerView.frame = view.bounds
            layerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            layerView.isUserInteractionEnabled = false
            view.addSubview(layerView)
        }

        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light   // papel blanco: no invertir la tinta
        canvas.drawingPolicy = .pencilOnly           // el dedo mueve y hace zoom; el Pencil escribe
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsHorizontalScrollIndicator = false
        canvas.delegate = self
        view.addSubview(canvas)

        tapGR.addTarget(self, action: #selector(tapped(_:)))
        tapGR.delegate = self
        canvas.addGestureRecognizer(tapGR)

        moveGR.addTarget(self, action: #selector(moved(_:)))
        moveGR.delegate = self
        moveGR.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(moveGR)
        canvas.panGestureRecognizer.require(toFail: moveGR)

        pencilGR.addTarget(self, action: #selector(pencilMoved(_:)))
        pencilGR.delegate = self
        pencilGR.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilGR.cancelsTouchesInView = false
        pencilGR.delaysTouchesEnded = false
        canvas.addGestureRecognizer(pencilGR)

        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        view.addSubview(overlay)
        for l in [previewLayer, laserLayer] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            overlay.layer.addSublayer(l)
        }
        laserLayer.strokeColor = UIColor.systemRed.cgColor
        laserLayer.lineWidth = 5
        laserLayer.shadowColor = UIColor.systemRed.cgColor
        laserLayer.shadowOpacity = 0.9
        laserLayer.shadowRadius = 6
        laserLayer.shadowOffset = .zero

        canvas.alwaysBounceHorizontal = true
        canvas.isDirectionalLockEnabled = true
        pullLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pullLabel.textAlignment = .center
        pullLabel.textColor = .label
        pullLabel.backgroundColor = .systemBackground
        pullLabel.layer.cornerRadius = 12
        pullLabel.layer.borderWidth = 1
        pullLabel.layer.borderColor = UIColor.separator.cgColor
        pullLabel.clipsToBounds = true
        pullLabel.alpha = 0
        pullBar.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.25)
        pullLabel.addSubview(pullBar)
        overlay.addSubview(pullLabel)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        NotificationCenter.default.addObserver(self, selector: #selector(appWillResign),
                                               name: UIApplication.willResignActiveNotification, object: nil)

        initialIndex = store.notebook(nbID)?.lastIndex ?? 0
        reload()

        state.$tool.combineLatest(state.$settings, state.$ruler)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.apply(v.0, v.1, v.2) }
            .store(in: &bag)
        store.$lib
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncElements() }
            .store(in: &bag)
        state.$selected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncElements() }
            .store(in: &bag)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvas.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flush()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard canvas.bounds.size != lastSize, canvas.bounds.width > 0 else { return }
        let target = lastSize == .zero ? initialIndex : currentIndex()
        lastSize = canvas.bounds.size
        fit(reset: true)
        scrollTo(target, animated: false)
        layoutOverlays()
        rerender(force: true)
    }

    // MARK: Herramientas

    private func apply(_ tool: ToolKind, _ s: ToolSettings, _ ruler: Bool) {
        var draws = true
        switch tool {
        case .pen, .shape:
            canvas.tool = PKInkingTool(s.penType.ink,
                                       color: UIColor(hex: pick(s.penColors, s.penColor, "1A1A1A")),
                                       width: CGFloat(pick(s.penWidths, s.penWidth, 2.8) * s.penType.scale))
        case .highlighter:
            canvas.tool = PKInkingTool(.marker,
                                       color: UIColor(hex: pick(s.hlColors, s.hlColor, "FFE14D")),
                                       width: CGFloat(pick(s.hlWidths, s.hlWidth, 18)))
        case .eraser:
            if s.eraserMode == .highlighter {
                draws = false   // la maneja pencilMoved
            } else {
                canvas.tool = PKEraserTool(s.eraserMode == .stroke ? .vector : .bitmap,
                                           width: CGFloat(pick(s.eraserWidths, s.eraserWidth, 20)))
            }
        case .lasso:
            canvas.tool = PKLassoTool()
        case .text, .hand, .laser:
            draws = false
        }
        canvas.drawingGestureRecognizer.isEnabled = draws
        canvas.isRulerActive = ruler
    }

    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }

    // MARK: Carga y armado de páginas

    func reload() {
        guard let nb = store.notebook(nbID) else { return }
        layout = []
        origins = [:]
        let sizes = nb.pages.map { store.pageSize(nbID, $0) }
        let maxW = sizes.map { $0.width }.max() ?? 595
        var y = gap
        for (p, s) in zip(nb.pages, sizes) {
            let r = CGRect(x: (maxW - s.width) / 2, y: y, width: s.width, height: s.height)
            layout.append((page: p, rect: r))
            origins[p.id] = r.origin
            y += s.height + gap
        }
        docSize = CGSize(width: maxW, height: y)

        var merged = PKDrawing()
        savedData = [:]
        for item in layout {
            let d = store.loadDrawing(nbID, item.page.id)
            savedData[item.page.id] = d.dataRepresentation()
            if !d.strokes.isEmpty {
                merged.append(d.transformed(using: CGAffineTransform(translationX: item.rect.minX, y: item.rect.minY)))
            }
        }
        ignoreChange = true
        canvas.drawing = merged
        ignoreChange = false
        strokeCount = merged.strokes.count
        dirty = false
        canvas.undoManager?.removeAllActions()

        for v in pageViews.values { v.removeFromSuperview() }
        pageViews.removeAll()
        if canvas.bounds.width > 0 { fit(reset: false) }
        syncElements()
    }

    // MARK: Zoom y posición

    private func fit(reset: Bool) {
        let b = canvas.bounds.size
        guard b.width > 0, docSize.width > 0 else { return }
        let fitW = (b.width - 24) / docSize.width
        canvas.minimumZoomScale = fitW * 0.5
        canvas.maximumZoomScale = fitW * 6
        if reset || canvas.zoomScale < canvas.minimumZoomScale || canvas.zoomScale > canvas.maximumZoomScale {
            canvas.zoomScale = fitW
        }
        updateContentSize()
        center()
        if canvas.contentSize.width <= canvas.bounds.width {
            canvas.contentOffset.x = -canvas.contentInset.left
        }
        layoutOverlays()
    }

    private func updateContentSize() {
        let z = canvas.zoomScale
        let size = CGSize(width: docSize.width * z, height: docSize.height * z)
        if canvas.contentSize != size { canvas.contentSize = size }
    }

    private func center() {
        let b = canvas.bounds.size
        let c = canvas.contentSize
        let x = max(0, (b.width - c.width) / 2)
        let y = max(0, (b.height - c.height) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if canvas.contentInset != inset { canvas.contentInset = inset }
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        let z = canvas.zoomScale, o = canvas.contentOffset
        return CGRect(x: r.minX * z - o.x, y: r.minY * z - o.y, width: r.width * z, height: r.height * z)
    }

    private func docPoint(_ p: CGPoint) -> CGPoint {
        let z = canvas.zoomScale
        return CGPoint(x: p.x / z, y: p.y / z)
    }

    private func pageIndex(forY y: CGFloat) -> Int {
        for (i, item) in layout.enumerated() where y < item.rect.maxY + gap / 2 {
            return i
        }
        return max(layout.count - 1, 0)
    }

    func currentIndex() -> Int {
        let z = canvas.zoomScale
        guard z > 0 else { return 0 }
        return pageIndex(forY: (canvas.contentOffset.y + canvas.bounds.height * 0.4) / z)
    }

    func scrollTo(_ i: Int, animated: Bool) {
        guard layout.indices.contains(i) else { return }
        let z = canvas.zoomScale
        let inset = canvas.contentInset
        let maxY = max(-inset.top, canvas.contentSize.height + inset.bottom - canvas.bounds.height)
        let y = min(max(layout[i].rect.minY * z - 10, -inset.top), maxY)
        let x = canvas.contentSize.width <= canvas.bounds.width ? -inset.left : canvas.contentOffset.x
        canvas.setContentOffset(CGPoint(x: x, y: y), animated: animated)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutOverlays()
        handlePull()
        let i = currentIndex()
        if state.current != i { state.current = i }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateContentSize()
        center()
        layoutOverlays()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        rerender(force: false)
    }

    // MARK: Fondos y elementos en pantalla

    private func layoutOverlays() {
        let z = canvas.zoomScale
        guard z > 0, !layout.isEmpty else { return }
        let o = canvas.contentOffset
        let h = canvas.bounds.height / z
        let visible = CGRect(x: o.x / z, y: o.y / z - h * 0.5, width: canvas.bounds.width / z, height: h * 2)

        var keep = Set<UUID>()
        for item in layout where item.rect.intersects(visible) {
            keep.insert(item.page.id)
            let v: PageView
            if let existing = pageViews[item.page.id] {
                v = existing
            } else {
                v = PageView()
                v.configure(size: item.rect.size, paper: item.page.paper, pdfPage: store.pdfPage(nbID, item.page))
                paperLayer.addSubview(v)
                pageViews[item.page.id] = v
            }
            v.frame = viewRect(item.rect)
            if v.renderedZoom == 0 { v.render(zoom: z, screenScale: screenScale) }
        }
        for (id, v) in pageViews where !keep.contains(id) {
            v.removeFromSuperview()
            pageViews[id] = nil
        }

        for (id, v) in elementViews {
            guard let el = elements[id], let origin = origins[el.pageID] else {
                v.isHidden = true
                continue
            }
            v.isHidden = false
            let local = (drag?.id == id ? dragRect : nil) ?? el.rect
            v.frame = viewRect(local.offsetBy(dx: origin.x, dy: origin.y))
            if v.zoom != z { v.configure(el, dir: folder, zoom: z, selected: state.selected == id) }
        }
    }

    private func rerender(force: Bool) {
        let z = canvas.zoomScale
        for v in pageViews.values where force || abs(v.renderedZoom - z) > z * 0.25 {
            v.render(zoom: z, screenScale: screenScale)
        }
    }

    private func syncElements() {
        let list = store.notebook(nbID)?.elements ?? []
        elements = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, v) in elementViews where elements[id] == nil {
            v.removeFromSuperview()
            elementViews[id] = nil
        }
        let z = canvas.zoomScale
        for el in list {
            let v: ElementView
            if let existing = elementViews[el.id] {
                v = existing
            } else {
                v = ElementView()
                elementLayer.addSubview(v)
                elementViews[el.id] = v
            }
            v.configure(el, dir: folder, zoom: z, selected: state.selected == el.id)
        }
        layoutOverlays()
    }

    // MARK: Toques: texto, seleccionar, mover y redimensionar

    private func docRect(_ el: NoteItem) -> CGRect {
        let o = origins[el.pageID] ?? .zero
        return el.rect.offsetBy(dx: o.x, dy: o.y)
    }

    private func hitElement(_ p: CGPoint) -> NoteItem? {
        let slop = 16 / max(canvas.zoomScale, 0.01)
        let list = store.notebook(nbID)?.elements ?? []
        return list.last { docRect($0).insetBy(dx: -slop, dy: -slop).contains(p) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === moveGR { touchStart = touch.location(in: canvas) }
        if g === pencilGR {
            strokePts = [docPoint(touch.location(in: canvas))]
            pendingOutline = nil
            previewLayer.path = nil
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === pencilGR || other === pencilGR
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === pencilGR {
            switch state.tool {
            case .pen: return state.settings.autoShape
            case .laser: return true
            case .eraser: return state.settings.eraserMode == .highlighter
            default: return false
            }
        }
        let mode = state.tool == .hand || state.tool == .text
        if g === tapGR { return mode }
        if g === moveGR {
            guard mode else { return false }
            let p = docPoint(touchStart)
            guard let el = hitElement(p) else { return false }
            let r = docRect(el)
            let slop = 30 / max(canvas.zoomScale, 0.01)
            let resize = state.selected == el.id && abs(p.x - r.maxX) < slop && abs(p.y - r.maxY) < slop
            drag = (id: el.id, start: el.rect, resize: resize)
            dragRect = el.rect
            if state.selected != el.id { state.selected = el.id }
            return true
        }
        return true
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = docPoint(g.location(in: canvas))
        if let el = hitElement(p) {
            if el.kind == .text && (state.tool == .text || state.selected == el.id) {
                state.editingIsNew = false
                state.editing = el
            } else {
                state.selected = el.id
            }
            return
        }
        state.selected = nil
        guard state.tool == .text, !layout.isEmpty else { return }
        let item = layout[pageIndex(forY: p.y)]
        guard item.rect.contains(p) else { return }
        let lx = p.x - item.rect.minX
        let ly = p.y - item.rect.minY
        let w = max(100, min(280, item.rect.width - lx - 10))
        var el = NoteItem(pageID: item.page.id, kind: .text,
                          rect: CGRect(x: lx, y: max(0, ly - 12), width: w, height: 28))
        el.fontSize = state.settings.textSize
        el.color = pick(state.settings.penColors, state.settings.penColor, "1A1A1A")
        state.editingIsNew = true
        state.editing = el
    }

    @objc private func moved(_ g: UIPanGestureRecognizer) {
        guard let d = drag, var el = elements[d.id] else { return }
        let z = max(canvas.zoomScale, 0.01)
        let t = g.translation(in: canvas)
        var r = d.start
        if d.resize {
            let w = max(40, d.start.width + t.x / z)
            r.size.width = w
            if el.kind == .image {
                r.size.height = w * d.start.height / max(d.start.width, 1)
            } else {
                r.size.height = CGFloat(textHeight(el.text, size: el.fontSize, width: Double(w)))
            }
        } else {
            r.origin.x += t.x / z
            r.origin.y += t.y / z
        }
        dragRect = r

        switch g.state {
        case .began, .changed:
            layoutOverlays()
        case .ended, .cancelled, .failed:
            el.rect = r
            drag = nil
            dragRect = nil
            let updated = el
            state.changeElements { list in
                if let i = list.firstIndex(where: { $0.id == updated.id }) { list[i] = updated }
            }
        default:
            break
        }
    }

    // MARK: Imágenes

    func insertImage(_ data: Data) {
        guard let img = UIImage(data: data), !layout.isEmpty else { return }
        let item = layout[currentIndex()]
        let name = UUID().uuidString + ".jpg"
        let jpg = img.jpegData(compressionQuality: 0.85) ?? data
        try? jpg.write(to: folder.appendingPathComponent(name), options: .atomic)

        let iw = max(img.size.width, 1), ih = max(img.size.height, 1)
        var w = min(item.rect.width * 0.6, iw)
        var h = w * ih / iw
        if h > item.rect.height * 0.6 {
            h = item.rect.height * 0.6
            w = h * iw / ih
        }
        let z = max(canvas.zoomScale, 0.01)
        let c = CGPoint(x: (canvas.contentOffset.x + canvas.bounds.width / 2) / z,
                        y: (canvas.contentOffset.y + canvas.bounds.height / 2) / z)
        let x = min(max(c.x - item.rect.minX - w / 2, 0), max(item.rect.width - w, 0))
        let y = min(max(c.y - item.rect.minY - h / 2, 0), max(item.rect.height - h, 0))
        let el = NoteItem(pageID: item.page.id, kind: .image, rect: CGRect(x: x, y: y, width: w, height: h), file: name)
        state.changeElements { list in list.append(el) }
        state.select(.hand)
        state.selected = el.id
    }

    // MARK: Páginas

    func addPage(_ paper: Paper) {
        flush()
        let at = layout.isEmpty ? 0 : currentIndex() + 1
        store.mutate(nbID) { $0.pages.insert(Page(paper: paper), at: min(at, $0.pages.count)) }
        reload()
        scrollTo(at, animated: true)
    }

    func deletePage(_ i: Int) {
        flush()
        guard let nb = store.notebook(nbID), nb.pages.count > 1, nb.pages.indices.contains(i) else { return }
        let page = nb.pages[i]
        try? FileManager.default.removeItem(at: store.drawingURL(nbID, page.id))
        store.mutate(nbID) {
            $0.pages.remove(at: i)
            $0.elements.removeAll { $0.pageID == page.id }
        }
        reload()
    }

    func duplicatePage(_ i: Int) {
        flush()
        guard let nb = store.notebook(nbID), nb.pages.indices.contains(i) else { return }
        let page = nb.pages[i]
        let copy = Page(paper: page.paper, pdfIndex: page.pdfIndex, pdfFile: page.pdfFile, landscape: page.landscape)
        try? FileManager.default.copyItem(at: store.drawingURL(nbID, page.id), to: store.drawingURL(nbID, copy.id))
        let items: [NoteItem] = nb.elements.filter { $0.pageID == page.id }.map { old in
            var n = old
            n.id = UUID()
            n.pageID = copy.id
            return n
        }
        store.mutate(nbID) {
            $0.pages.insert(copy, at: i + 1)
            $0.elements.append(contentsOf: items)
        }
        reload()
        scrollTo(i + 1, animated: true)
    }

    func setPaper(_ paper: Paper) {
        flush()
        let i = currentIndex()
        store.mutate(nbID) { if $0.pages.indices.contains(i) { $0.pages[i].paper = paper } }
        reload()
    }

    func toggleLandscape() {
        flush()
        let i = currentIndex()
        store.mutate(nbID) { nb in
            if nb.pages.indices.contains(i), nb.pages[i].pdfIndex == nil {
                nb.pages[i].landscape = !(nb.pages[i].landscape ?? false)
            }
        }
        reload()
        fit(reset: true)
        scrollTo(i, animated: false)
        state.thumbs += 1
    }

    func insertPDF(_ url: URL) {
        flush()
        let at = layout.isEmpty ? 0 : currentIndex() + 1
        guard store.insertPDF(url, into: nbID, at: at) > 0 else { return }
        reload()
        scrollTo(at, animated: true)
    }

    // MARK: Deslizar al costado y mantener = página nueva

    private func handlePull() {
        let inset = canvas.contentInset
        let maxX = max(-inset.left, canvas.contentSize.width + inset.right - canvas.bounds.width)
        let over = canvas.contentOffset.x - maxX
        if !canvas.isTracking || over < 50 {
            pullWork?.cancel()
            pullWork = nil
            if over < 5 { pullDone = false }
            if pullLabel.alpha > 0, !canvas.isTracking || !pullDone {
                UIView.animate(withDuration: 0.2) { self.pullLabel.alpha = 0 }
            }
            return
        }
        guard pullWork == nil, !pullDone else { return }
        let w: CGFloat = 210
        pullLabel.frame = CGRect(x: view.bounds.width - w - 12, y: view.bounds.midY - 22, width: w, height: 44)
        pullLabel.text = "Mantené para nueva página"
        pullLabel.alpha = 1
        pullBar.layer.removeAllAnimations()
        pullBar.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        UIView.animate(withDuration: 0.8, delay: 0, options: .curveLinear) {
            self.pullBar.frame = CGRect(x: 0, y: 0, width: w, height: 44)
        }
        let work = DispatchWorkItem { [weak self] in self?.pullFired() }
        pullWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func pullFired() {
        pullWork = nil
        guard canvas.isTracking, !layout.isEmpty else { return }
        pullDone = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        pullLabel.text = "Página agregada"
        let i = currentIndex()
        addPage(layout.indices.contains(i) ? layout[i].page.paper : .ruled)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            UIView.animate(withDuration: 0.2) { self?.pullLabel.alpha = 0 }
        }
    }

    // MARK: Lápiz: forma al mantener, láser y goma de resaltador

    @objc private func pencilMoved(_ g: UIPanGestureRecognizer) {
        let done = g.state == .ended || g.state == .cancelled || g.state == .failed
        switch state.tool {
        case .laser:
            let p = g.location(in: view)
            if g.state == .began {
                laserWork?.cancel()
                laserPath = UIBezierPath()
                laserPath.move(to: p)
            } else {
                laserPath.addLine(to: p)
            }
            laserLayer.path = laserPath.cgPath
            if done {
                let work = DispatchWorkItem { [weak self] in self?.laserLayer.path = nil }
                laserWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            }
        case .eraser:
            eraseHighlighter(at: docPoint(g.location(in: canvas)))
        case .pen:
            if done {
                holdWork?.cancel()
                return
            }
            guard pendingOutline == nil else { return }
            let p = docPoint(g.location(in: canvas))
            strokePts.append(p)
            if g.state == .began || hypot(p.x - holdAnchor.x, p.y - holdAnchor.y) > 4 {
                holdAnchor = p
                holdWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.holdDetected() }
                holdWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        default:
            break
        }
    }

    /// El lápiz quedó quieto: muestra la figura corregida mientras se sigue apoyando.
    private func holdDetected() {
        guard let outline = ShapeRecognizer.outline(strokePts), let first = outline.first else { return }
        pendingOutline = outline
        let z = canvas.zoomScale
        let o = canvas.contentOffset
        let path = UIBezierPath()
        path.move(to: CGPoint(x: first.x * z - o.x, y: first.y * z - o.y))
        for p in outline.dropFirst() {
            path.addLine(to: CGPoint(x: p.x * z - o.x, y: p.y * z - o.y))
        }
        previewLayer.strokeColor = UIColor(hex: state.currentColorHex).cgColor
        previewLayer.lineWidth = max(CGFloat(pick(state.settings.penWidths, state.settings.penWidth, 2.8)) * z, 1)
        previewLayer.path = path.cgPath
        feedback.pathCompleted(at: CGPoint(x: holdAnchor.x * z - o.x, y: holdAnchor.y * z - o.y))
    }

    private func eraseHighlighter(at p: CGPoint) {
        let r = CGFloat(pick(state.settings.eraserWidths, state.settings.eraserWidth, 20)) / 2
        var d = canvas.drawing
        let before = d.strokes.count
        d.strokes.removeAll { s in
            guard s.ink.inkType == .marker, s.renderBounds.insetBy(dx: -r, dy: -r).contains(p) else { return false }
            for pt in s.path.interpolatedPoints(by: .distance(4)) {
                let q = pt.location.applying(s.transform)
                if hypot(q.x - p.x, q.y - p.y) < r + max(pt.size.width, pt.size.height) / 2 { return true }
            }
            return false
        }
        guard d.strokes.count != before else { return }
        ignoreChange = true
        canvas.drawing = d
        ignoreChange = false
        strokeCount = d.strokes.count
        scheduleSave()
    }

    // MARK: Apple Pencil Pro: apretar y doble toque

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        if state.paletteAt != nil {
            state.paletteAt = nil
        } else {
            state.paletteAt = squeeze.hoverPose?.location ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            state.toggleEraser()
        case .switchPrevious:
            state.switchPrevious()
        case .showColorPalette, .showInkAttributes:
            state.paletteAt = tap.hoverPose?.location ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        default:
            break
        }
    }

    // MARK: Trazos: formas automáticas y guardado

    func canvasViewDrawingDidChange(_ c: PKCanvasView) {
        if ignoreChange { return }
        if c.drawing.strokes.count == strokeCount + 1, let stroke = c.drawing.strokes.last {
            var shape: PKStroke?
            if let outline = pendingOutline {
                shape = ShapeRecognizer.make(outline, from: stroke)
            } else if state.tool == .shape {
                shape = ShapeRecognizer.recognize(stroke)
                if let s = shape {
                    let r = viewRect(s.renderBounds)
                    feedback.pathCompleted(at: CGPoint(x: r.midX, y: r.midY))
                }
            }
            if let shape = shape {
                var d = c.drawing
                d.strokes[d.strokes.count - 1] = shape
                ignoreChange = true
                c.drawing = d
                ignoreChange = false
            }
        }
        pendingOutline = nil
        previewLayer.path = nil
        strokeCount = c.drawing.strokes.count
        scheduleSave()
    }

    private func scheduleSave() {
        dirty = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Reparte los trazos entre las páginas y guarda las que cambiaron.
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        guard dirty, !layout.isEmpty else { return }
        dirty = false
        var perPage: [UUID: PKDrawing] = [:]
        for s in canvas.drawing.strokes {
            let item = layout[pageIndex(forY: s.renderBounds.midY)]
            var st = s
            st.transform = s.transform.concatenating(CGAffineTransform(translationX: -item.rect.minX, y: -item.rect.minY))
            perPage[item.page.id, default: PKDrawing()].strokes.append(st)
        }
        var changed = false
        for item in layout {
            let data = (perPage[item.page.id] ?? PKDrawing()).dataRepresentation()
            if savedData[item.page.id] != data {
                try? data.write(to: store.drawingURL(nbID, item.page.id), options: .atomic)
                savedData[item.page.id] = data
                changed = true
            }
        }
        if changed { state.thumbs += 1 }
    }

    @objc private func appWillResign() {
        flush()
    }
}
