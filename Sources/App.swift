import SwiftUI
import UniformTypeIdentifiers

@main
struct AbletonCollectorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class CollectorViewModel: ObservableObject {
    @Published var projectFolder: URL? = nil
    @Published var searchFolder: URL? = nil
    @Published var logLines: [String] = []
    @Published var running = false
    @Published var progressDone = 0
    @Published var progressTotal = 0
    @Published var currentSet = ""
    @Published var summary: String? = nil
    private var cancelled = false

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 5000 { logLines.removeFirst(1000) }
    }

    func cancel() { cancelled = true }

    func start(dryRun: Bool) {
        guard let folder = projectFolder, !running else { return }
        running = true
        cancelled = false
        logLines = []
        summary = nil
        progressDone = 0
        progressTotal = 0
        currentSet = ""
        appendLog(dryRun ? "🔍 Testlauf – es wird nichts kopiert.\n" : "🚀 Los geht's …\n")

        let options = CollectOptions(dryRun: dryRun, searchFolder: searchFolder)
        let isCancelled: @Sendable () -> Bool = { [weak self] in
            DispatchQueue.main.sync { self?.cancelled ?? true }
        }

        Task.detached(priority: .userInitiated) {
            let engine = CollectEngine(
                log: { line in
                    DispatchQueue.main.async { self.appendLog(line) }
                },
                progress: { done, total, name in
                    DispatchQueue.main.async {
                        self.progressDone = done
                        self.progressTotal = total
                        self.currentSet = name
                    }
                }
            )
            engine.isCancelled = isCancelled
            let stats = engine.run(folder: folder, options: options)

            DispatchQueue.main.async {
                self.finish(stats: stats, dryRun: dryRun)
            }
        }
    }

    private func finish(stats: CollectStats, dryRun: Bool) {
        running = false
        currentSet = ""
        let verb = dryRun ? "würden kopiert" : "kopiert"
        var lines = ["Fertig! \(stats.projects) Projekt(e) geprüft, \(stats.copied) Datei(en) \(verb)."]
        if stats.foundViaSearch > 0 {
            lines.append("\(stats.foundViaSearch) davon über den Suchordner wiedergefunden.")
        }
        if !stats.missing.isEmpty {
            lines.append("⚠️ \(stats.missing.count) Datei(en) wurden nirgends gefunden – Liste siehe Protokoll.")
            appendLog("\n––– Fehlende Dateien –––")
            for m in stats.missing { appendLog("   ⚠️ \(m)") }
        }
        if !stats.errors.isEmpty {
            lines.append("⛔️ \(stats.errors.count) Fehler – siehe Protokoll.")
        }
        summary = lines.joined(separator: " ")
        appendLog("\n" + lines.joined(separator: "\n"))
    }
}

struct ContentView: View {
    @StateObject private var model = CollectorViewModel()
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ableton Collector").font(.title2.bold())
                    Text("Sammelt alle Samples deiner Live-Projekte in die Projektordner – ohne die Projekte zu verändern.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    folderRow(
                        icon: "folder.fill",
                        title: "Projekte",
                        subtitle: "Ordner mit allen Projekten – oder ein einzelnes Live-Set (.als) zum Ausprobieren",
                        url: model.projectFolder,
                        allowAlsFile: true
                    ) { model.projectFolder = $0 }

                    Divider()

                    folderRow(
                        icon: "magnifyingglass",
                        title: "Suchordner (optional)",
                        subtitle: "z. B. deine Sample-Library – hier wird nach verschollenen Samples gesucht",
                        url: model.searchFolder,
                        allowAlsFile: false
                    ) { model.searchFolder = $0 }
                }
                .padding(6)
            }

            HStack(spacing: 10) {
                Button {
                    model.start(dryRun: true)
                } label: {
                    Label("Testlauf", systemImage: "eye")
                }
                .disabled(model.projectFolder == nil || model.running)
                .help("Zeigt nur an, was passieren würde – kopiert nichts.")

                Button {
                    model.start(dryRun: false)
                } label: {
                    Label("Samples einsammeln", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.projectFolder == nil || model.running)

                Spacer()
            }

            if model.running {
                VStack(alignment: .leading, spacing: 6) {
                    if model.progressTotal > 0 {
                        ProgressView(value: Double(model.progressDone), total: Double(model.progressTotal))
                    } else {
                        ProgressView().progressViewStyle(.linear) // Sets werden noch gezählt
                    }
                    HStack {
                        Text(model.progressTotal > 0
                             ? "Projekt \(model.progressDone) von \(model.progressTotal)\(model.currentSet.isEmpty ? "" : ":  \(model.currentSet)")"
                             : "Suche Live-Sets …")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Abbrechen") { model.cancel() }
                            .controlSize(.small)
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .onChange(of: model.logLines.count) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            if let summary = model.summary {
                Text(summary)
                    .font(.callout.bold())
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            }
        }
        .padding(16)
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.12))
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    Label("Ordner oder Live-Set hier fallen lassen", systemImage: "arrow.down.doc.fill")
                        .font(.title3.bold())
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            // Ordner oder einzelnes Live-Set (.als)
            guard isDir.boolValue || url.pathExtension.lowercased() == "als" else { return }
            DispatchQueue.main.async { model.projectFolder = url }
        }
        return true
    }

    @ViewBuilder
    private func folderRow(icon: String, title: String, subtitle: String, url: URL?,
                           allowAlsFile: Bool, onPick: @escaping (URL) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let url {
                    Text(url.path).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(url == nil ? "Auswählen …" : "Ändern …") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = allowAlsFile
                if allowAlsFile, let alsType = UTType(filenameExtension: "als") {
                    panel.allowedContentTypes = [alsType]
                }
                panel.allowsMultipleSelection = false
                panel.prompt = "Auswählen"
                if panel.runModal() == .OK, let picked = panel.url {
                    onPick(picked)
                }
            }
        }
    }
}
