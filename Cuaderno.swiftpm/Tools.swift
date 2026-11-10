import Foundation
import PencilKit

enum ToolKind: String, Codable {
    case pen, highlighter, eraser, shape, lasso, text, hand, laser
}

enum PenType: String, Codable, CaseIterable, Identifiable {
    case fountain, ballpoint, pencil, monoline, watercolor, crayon

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fountain: return "Pluma"
        case .ballpoint: return "Bolígrafo"
        case .pencil: return "Lápiz"
        case .monoline: return "Fino"
        case .watercolor: return "Acuarela"
        case .crayon: return "Crayón"
        }
    }

    var symbol: String {
        switch self {
        case .fountain: return "pencil.tip"
        case .ballpoint: return "pencil"
        case .pencil: return "pencil.and.outline"
        case .monoline: return "pencil.line"
        case .watercolor: return "paintbrush.pointed"
        case .crayon: return "scribble.variable"
        }
    }

    var ink: PKInk.InkType {
        switch self {
        case .fountain: return .fountainPen
        case .ballpoint: return .pen
        case .pencil: return .pencil
        case .monoline: return .monoline
        case .watercolor: return .watercolor
        case .crayon: return .crayon
        }
    }

    /// Cada tipo necesita otro grosor para verse parecido con el mismo ajuste.
    var scale: Double {
        switch self {
        case .pencil: return 2
        case .watercolor: return 6
        case .crayon: return 5
        default: return 1
        }
    }
}

enum EraserMode: String, Codable, CaseIterable, Identifiable {
    case stroke, partial, highlighter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stroke: return "Borrar trazo completo"
        case .partial: return "Borrar por partes"
        case .highlighter: return "Borrar solo resaltador"
        }
    }
}

/// Colores y grosores favoritos (se guardan entre sesiones, como en GoodNotes).
struct ToolSettings: Codable, Equatable {
    var penColors = ["1A1A1A", "1E4FD8", "D62828"]
    var penColor = 0
    var penWidths: [Double] = [1.5, 2.8, 5]
    var penWidth = 1
    var penType = PenType.fountain

    var hlColors = ["FFE14D", "7CE38B", "FF8FC7"]
    var hlColor = 0
    var hlWidths: [Double] = [10, 18, 28]
    var hlWidth = 1

    var eraserMode = EraserMode.stroke
    var eraserWidths: [Double] = [8, 20, 40]
    var eraserWidth = 1

    var autoShape = true
    var textSize: Double = 18

    private static let key = "toolSettings.v2"

    static func load() -> ToolSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(ToolSettings.self, from: data) else { return ToolSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: ToolSettings.key)
        }
    }
}

func pick<T>(_ list: [T], _ i: Int, _ fallback: T) -> T {
    list.indices.contains(i) ? list[i] : (list.first ?? fallback)
}
