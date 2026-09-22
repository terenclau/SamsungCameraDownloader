import SwiftUI
import Photos
import UIKit
import ImageIO
import UniformTypeIdentifiers

@main
struct CameraPocketApp: App {
    var body: some Scene { WindowGroup { CameraView() } }
}

@MainActor
final class CameraModel: ObservableObject {
    @Published var photos: [CameraPhoto] = []
    @Published var selected = Set<String>()
    @Published var saved = Set<String>()
    @Published var busy = false
    @Published var importing = false
    @Published var cameraName = "Your DV300F"
    @Published var status = "Connect to start choosing photos."
    @Published var completed = 0
    @Published var total = 0
    @Published var error: String?
    private var operation: Task<Void, Never>?
    private let client = CameraClient()

    func connect(address: String, direct: Bool) {
        guard !busy else { return }
        busy = true
        photos = []; selected = []; saved = []
        status = "Connecting to your camera…"
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let (name, control) = try await client.connect(address: address, directControl: direct)
                cameraName = name
                status = "Reading photo list…"
                let result = try await client.browse(control: control)
                try Task.checkCancellation()
                photos = result
                status = result.isEmpty ? "No downloadable photos or MP4 videos found. Check the camera’s selected files and MobileLink mode." : "\(photos.count) items · tap to select"
            } catch {
                if Task.isCancelled { status = "Connection cancelled." }
                else { self.error = error.localizedDescription; status = "Couldn’t connect." }
            }
        }
    }
    func cancel() { operation?.cancel() }
    func toggle(_ photo: CameraPhoto) {
        guard !busy, !saved.contains(photo.id) else { return }
        if !selected.insert(photo.id).inserted { selected.remove(photo.id) }
    }
    func download() {
        guard !busy, !selected.isEmpty else { return }
        let pending = photos.filter { selected.contains($0.id) && !saved.contains($0.id) }
        guard !pending.isEmpty else { return }
        busy = true; importing = true; completed = 0; total = pending.count
        operation = Task {
            // Foreground transfer: don't let auto-lock interrupt a long import.
            let previousIdle = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                UIApplication.shared.isIdleTimerDisabled = previousIdle
                busy = false; importing = false; operation = nil
            }
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else {
                error = "Allow this app to add photos in iPhone Settings, then try again."
                status = "Photos access is required to save your selection."
                return
            }
            var failures: [String] = [], success = 0
            for photo in pending {
                if Task.isCancelled { break }
                status = "Saving \(completed + 1) of \(total): \(photo.title)"
                do {
                    let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: photo.original, timeoutInterval: 90))
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw CameraFailure(message: "Download rejected by camera") }
                    let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
                    guard size > 0, photo.size == 0 || size == photo.size else { throw CameraFailure(message: "Incomplete download") }
                    try Task.checkCancellation()
                    let ext = UTType(mimeType: photo.mimeType)?.preferredFilenameExtension ?? (photo.isVideo ? "mp4" : "jpg")
                    let importFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                    try FileManager.default.moveItem(at: temporary, to: importFile)
                    defer { try? FileManager.default.removeItem(at: importFile) }
                    let title = (photo.title as NSString).lastPathComponent
                    let filename = (title as NSString).pathExtension.isEmpty ? title + "." + ext : title
                    // Keep the file until Photos' completion handler confirms import.
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = filename
                        // Import the downloaded file itself, without decoding, recompressing,
                        // or rewriting EXIF / MP4 metadata.
                        request.addResource(with: photo.isVideo ? .video : .photo, fileURL: importFile, options: options)
                    }
                    saved.insert(photo.id); selected.remove(photo.id); success += 1
                } catch {
                    if Task.isCancelled { break }
                    failures.append("\(photo.title): \(error.localizedDescription)")
                }
                completed += 1
            }
            status = "Saved \(success) to Photos."
            if Task.isCancelled { status += " Stopped; remaining items are still selected." }
            if !failures.isEmpty {
                status += " \(failures.count) failed; tap Download to retry."
                error = failures.prefix(8).joined(separator: "\n") + (failures.count > 8 ? "\n…and \(failures.count - 8) more." : "")
            }
        }
    }
}

// Limit camera requests and downsample full-size fallback previews off the UI thread.
actor Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 25
        session = URLSession(configuration: config)
        cache.totalCostLimit = 32 * 1024 * 1024
    }
    func image(_ url: URL) async throws -> UIImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if active >= 2 { await withCheckedContinuation { waiters.append($0) } }
        else { active += 1 }
        defer {
            if waiters.isEmpty { active -= 1 }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw CameraFailure(message: "Preview unavailable")
        }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
        return image
    }
}

struct PhotoTile: View {
    let photo: CameraPhoto
    let selected: Bool
    let saved: Bool
    let action: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Color(.secondarySystemBackground)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image { Image(uiImage: image).resizable().scaledToFill() }
                        else if failed || photo.thumbnail == nil { Image(systemName: photo.isVideo ? "video" : "photo").font(.largeTitle).foregroundStyle(.secondary) }
                        else { ProgressView() }
                    }
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: saved ? "checkmark.seal.fill" : selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2).symbolRenderingMode(.palette)
                            .foregroundStyle(saved ? .green : selected ? .blue : .gray, .white)
                            .padding(8)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if photo.isVideo {
                            Label("MP4", systemImage: "play.fill").font(.caption.bold())
                                .padding(6).background(.ultraThinMaterial, in: Capsule()).padding(8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.blue : .clear, lineWidth: 3))
                Text(photo.title).font(.caption).lineLimit(1)
                Text(saved ? "Saved to Photos" : photo.size > 0 ? ByteCountFormatter.string(fromByteCount: photo.size, countStyle: .file) : "Photo")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(photo.title), \(saved ? "saved" : selected ? "selected" : "not selected")")
        .task(id: photo.thumbnail) {
            guard let thumbnail = photo.thumbnail else { return }
            do { image = try await Thumbnails.shared.image(thumbnail) }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct CameraView: View {
    @StateObject private var model = CameraModel()
    @AppStorage("cameraAddress") private var address = ""
    @AppStorage("useControlURL") private var direct = false
    @State private var showConnection = true
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var dragStart: Int?
    @State private var dragBaseline = Set<String>()
    @State private var dragSelects = true
    private func updateSelection(at point: CGPoint, beginning: Bool) {
        guard !model.busy else { return }
        let hit = model.photos.firstIndex { tileFrames[$0.id]?.contains(point) == true }
        if beginning {
            guard let hit, !model.saved.contains(model.photos[hit].id) else { return }
            dragStart = hit
            dragBaseline = model.selected
            dragSelects = !dragBaseline.contains(model.photos[hit].id)
        }
        guard let first = dragStart, let last = hit else { return }
        let ids = Set(model.photos[min(first, last)...max(first, last)].map(\.id)).subtracting(model.saved)
        let updated = dragSelects ? dragBaseline.union(ids) : dragBaseline.subtracting(ids)
        if model.selected != updated { model.selected = updated }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.photos.isEmpty || showConnection {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Connect your DV300F", systemImage: "wifi").font(.headline)
                            Text("Turn on MobileLink and join the camera’s Wi-Fi in iPhone Settings. Use the same setup that worked on your Mac.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            TextField("Camera IP address or URL", text: $address)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            Toggle("Use service URL", isOn: $direct).font(.subheadline)
                            if direct {
                                Text("Paste the ContentDirectory URL shown by the Mac’s browse command.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button { model.connect(address: address, direct: direct); showConnection = false } label: {
                                Text("Connect to camera").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                        }
                        .padding().background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .disabled(model.busy)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.cameraName).font(.title2.bold())
                        Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                        if model.busy {
                            if model.importing { ProgressView(value: Double(model.completed), total: Double(max(1, model.total))) }
                            else { ProgressView() }
                            Button("Cancel", role: .cancel) { model.cancel() }
                        }
                    }
                    if !model.photos.isEmpty {
                        HStack {
                            Text("\(model.selected.count) selected").font(.subheadline)
                            Spacer()
                            Button("Select all") { model.selected = Set(model.photos.map(\.id)).subtracting(model.saved) }
                            Button("Clear") { model.selected.removeAll() }
                        }.font(.subheadline).disabled(model.busy)
                        Text("Hold an item, then drag to select. Hold near the top or bottom to scroll while selecting.")
                            .font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 16) {
                            ForEach(model.photos) { photo in
                                PhotoTile(photo: photo, selected: model.selected.contains(photo.id), saved: model.saved.contains(photo.id)) { model.toggle(photo) }
                                    .disabled(model.busy || model.saved.contains(photo.id))
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(key: TileFramesKey.self, value: [photo.id: geometry.frame(in: .global)])
                                    })
                            }
                        }
                        .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
                        .background(DragSelectionBridge(
                            canBegin: { point in !model.busy && model.photos.contains { !model.saved.contains($0.id) && tileFrames[$0.id]?.contains(point) == true } },
                            changed: { point, beginning in updateSelection(at: point, beginning: beginning) },
                            ended: { dragStart = nil }
                        ))
                    }
                }.padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Camera Pocket")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showConnection.toggle() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Connection settings").disabled(model.busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.photos.isEmpty {
                    VStack(spacing: 6) {
                        Button { model.download() } label: {
                            Label("Download \(model.selected.count) to Photos", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent).disabled(model.busy || model.selected.isEmpty)
                        Text("Keep this app open while downloading.").font(.caption).foregroundStyle(.secondary)
                    }.padding().background(.regularMaterial)
                }
            }
            .alert("Camera Pocket", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

private struct TileFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// A single continuous recognizer avoids changing ScrollView's enabled state mid-touch.
// Ordinary swipes fail the hold recognizer immediately; an established hold owns
// selection and scrolls the underlying UIScrollView at its visible edges.
private struct DragSelectionBridge: UIViewRepresentable {
    var canBegin: (CGPoint) -> Bool
    var changed: (CGPoint, Bool) -> Void
    var ended: () -> Void

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.attach = { [weak coordinator = context.coordinator] view in coordinator?.attach(view) }
        return view
    }
    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            if let view { coordinator?.attach(view) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) { coordinator.detach() }

    final class AttachmentView: UIView {
        var attach: ((UIView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { attach?(self) }
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: DragSelectionBridge
        weak var scroll: UIScrollView?
        private var displayLink: CADisplayLink?
        private var finger = CGPoint.zero
        private lazy var hold: UILongPressGestureRecognizer = {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            gesture.minimumPressDuration = 0.35
            gesture.allowableMovement = 10
            gesture.delegate = self
            return gesture
        }()
        init(_ parent: DragSelectionBridge) { self.parent = parent }
        func attach(_ view: UIView) {
            var ancestor = view.superview
            while let candidate = ancestor {
                if let found = candidate as? UIScrollView {
                    guard found !== scroll else { return }
                    detach()
                    scroll = found
                    found.addGestureRecognizer(hold)
                    return
                }
                ancestor = candidate.superview
            }
        }
        func detach() {
            displayLink?.invalidate(); displayLink = nil
            scroll?.removeGestureRecognizer(hold)
            scroll = nil
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scroll, let window = scroll.window else { return false }
            return parent.canBegin(gestureRecognizer.location(in: window))
        }
        @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
            guard let scroll, let window = scroll.window else { return }
            switch gesture.state {
            case .began:
                finger = gesture.location(in: window)
                parent.changed(finger, true)
                UISelectionFeedbackGenerator().selectionChanged()
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            case .changed:
                finger = gesture.location(in: window)
                parent.changed(finger, false)
            case .ended, .cancelled, .failed:
                displayLink?.invalidate(); displayLink = nil
                parent.ended()
            default: break
            }
        }
        @objc private func tick(_ link: CADisplayLink) {
            guard let scroll, let window = scroll.window else {
                displayLink?.invalidate(); displayLink = nil
                parent.ended()
                return
            }
            let viewport = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: window)
            let band: CGFloat = 72
            let top = max(0, min(1, (viewport.minY + band - finger.y) / band))
            let bottom = max(0, min(1, (finger.y - viewport.maxY + band) / band))
            let speed = (bottom - top) * 500
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let step = CGFloat(min(link.targetTimestamp - link.timestamp, 0.05))
            let y = min(maximum, max(minimum, scroll.contentOffset.y + speed * step))
            if y != scroll.contentOffset.y { scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false) }
            // Repeat even for a stationary finger: new rows move underneath it.
            parent.changed(CGPoint(x: finger.x, y: min(viewport.maxY - 1, max(viewport.minY + 1, finger.y))), false)
        }
    }
}
