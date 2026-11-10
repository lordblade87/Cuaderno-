import SwiftUI
import UniformTypeIdentifiers

let coverColors: [Color] = [.blue, .teal, .green, .orange, .red, .purple, .pink, .indigo]

struct LibraryView: View {
    @ObservedObject var store: Store
    var folder: String? = nil

    @State private var showNew = false
    @State private var showImport = false
    @State private var showFolder = false
    @State private var folderName = ""
    @State private var renaming: Notebook?
    @State private var newName = ""
    @State private var query = ""

    private var items: [Notebook] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var list: [Notebook]
        if q.isEmpty {
            list = store.lib.notebooks.filter { $0.folder == folder }
        } else {
            list = store.lib.notebooks.filter { $0.title.localizedCaseInsensitiveContains(q) }
        }
        return list.filter { $0.favorite } + list.filter { !$0.favorite }
    }

    private var subfolders: [String] {
        guard query.isEmpty else { return [] }
        return store.lib.folders.filter { folderParent($0) == folder }
    }

    private var isEmpty: Bool {
        items.isEmpty && subfolders.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 24)], spacing: 28) {
                ForEach(subfolders, id: \.self) { name in
                    NavigationLink(value: Route.folder(name)) {
                        FolderCell(name: folderTitle(name), count: store.lib.notebooks.filter { $0.folder == name }.count)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Eliminar carpeta", systemImage: "trash", role: .destructive) {
                            store.deleteFolder(name)
                        }
                    }
                }
                ForEach(items) { nb in
                    NavigationLink(value: Route.notebook(nb.id)) {
                        Cover(nb: nb)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(nb.favorite ? "Quitar de favoritos" : "Favorito", systemImage: nb.favorite ? "star.slash" : "star") {
                            store.mutate(nb.id) { $0.favorite.toggle() }
                        }
                        Button("Renombrar", systemImage: "pencil") {
                            newName = nb.title
                            renaming = nb
                        }
                        Menu("Mover a…") {
                            Button("Biblioteca") { store.mutate(nb.id) { $0.folder = nil } }
                            ForEach(store.lib.folders, id: \.self) { f in
                                Button(f) { store.mutate(nb.id) { $0.folder = f } }
                            }
                        }
                        Button("Eliminar", systemImage: "trash", role: .destructive) {
                            store.delete(nb.id)
                        }
                    }
                }
            }
            .padding(24)
        }
        .overlay {
            if isEmpty {
                ContentUnavailableView("Sin cuadernos", systemImage: "book.closed",
                                       description: Text("Tocá + para crear uno o importar un PDF"))
            }
        }
        .navigationTitle(folder.map { folderTitle($0) } ?? "Mis cuadernos")
        .searchable(text: $query, prompt: "Buscar cuadernos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Nuevo cuaderno", systemImage: "book.closed") { showNew = true }
                    Button("Importar PDF", systemImage: "doc.badge.plus") { showImport = true }
                    Button("Nueva carpeta", systemImage: "folder.badge.plus") { showFolder = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showNew) {
            NewNotebookSheet(store: store, folder: folder)
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [UTType.pdf]) { result in
            if case .success(let url) = result {
                store.importPDF(url, folder: folder)
            }
        }
        .alert("Nueva carpeta", isPresented: $showFolder) {
            TextField("Nombre", text: $folderName)
            Button("Crear") {
                store.addFolder(folderName, parent: folder)
                folderName = ""
            }
            Button("Cancelar", role: .cancel) { folderName = "" }
        }
        .alert("Renombrar", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nombre", text: $newName)
            Button("Guardar") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let nb = renaming, !name.isEmpty {
                    store.mutate(nb.id) { $0.title = name }
                }
                renaming = nil
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
    }
}

struct Cover: View {
    let nb: Notebook

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Rectangle().fill(coverColors[abs(nb.cover) % coverColors.count].gradient)
                Rectangle().fill(Color.black.opacity(0.18)).frame(width: 10)
                Text(nb.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
            }
            .aspectRatio(0.75, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 3, y: 2)

            Text((nb.favorite ? "★ " : "") + "\(nb.pages.count) pág. · \(nb.modified.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct FolderCell: View {
    let name: String
    let count: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.accentColor)
                .padding(16)
                .frame(maxWidth: .infinity)
                .aspectRatio(0.75, contentMode: .fit)
            Text(name).font(.subheadline).lineLimit(1)
            Text("\(count) cuadernos").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct NewNotebookSheet: View {
    @ObservedObject var store: Store
    let folder: String?

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var cover = 0
    @State private var paper = Paper.ruled
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre (ej. Estructuras III)", text: $title)
                    .focused($focused)
                Picker("Papel", selection: $paper) {
                    ForEach(Paper.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                Section("Tapa") {
                    HStack(spacing: 12) {
                        ForEach(coverColors.indices, id: \.self) { i in
                            Circle()
                                .fill(coverColors[i])
                                .frame(width: 30, height: 30)
                                .overlay(Circle().stroke(Color.primary, lineWidth: cover == i ? 3 : 0))
                                .onTapGesture { cover = i }
                        }
                    }
                }
            }
            .navigationTitle("Nuevo cuaderno")
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crear") {
                        store.create(title: title, cover: cover, paper: paper, folder: folder)
                        dismiss()
                    }
                }
            }
        }
    }
}
