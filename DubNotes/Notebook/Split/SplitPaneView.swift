import PDFKit
import SwiftUI
import UIKit

// MARK: - Read-only page column

/// A continuous, read-only column of rendered pages with its own zoom and scroll: what a split pane shows for
/// another notebook. Pages render lazily near the viewport and are released when far away.
final class ReadOnlyColumnView: UIScrollView, UIScrollViewDelegate {
    private let content = UIView()
    private var sources: [PageRenderer.Source] = []
    private var frames: [CGRect] = []
    private var imageViews: [Int: UIImageView] = [:]
    private var rendering = Set<Int>()
    private var didFit = false
    private var generation = 0
    private let queue = DispatchQueue(label: "dubnotes.split.render", qos: .userInitiated)

    private static let margin: CGFloat = 12
    private static let gap: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 0.5
        maximumZoomScale = 3
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func load(_ sources: [PageRenderer.Source]) {
        self.sources = sources
        generation += 1
        for v in imageViews.values { v.removeFromSuperview() }
        imageViews = [:]
        rendering = []
        let maxW = sources.map { CGFloat($0.page.pageWidth) }.max() ?? CGFloat(PageUnits.width)
        let w = maxW + Self.margin * 2
        var y = Self.margin
        frames = []
        for s in sources {
            let pw = CGFloat(s.page.pageWidth), ph = CGFloat(s.page.pageHeight)
            frames.append(CGRect(x: (w - pw) / 2, y: y, width: pw, height: ph))
            y += ph + Self.gap
        }
        let size = CGSize(width: w, height: y)
        let z = zoomScale
        content.bounds = CGRect(origin: .zero, size: size)
        content.center = CGPoint(x: size.width * z / 2, y: size.height * z / 2)
        contentSize = CGSize(width: size.width * z, height: size.height * z)
        updateVisible()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        if !didFit, !sources.isEmpty {
            didFit = true
            let w = content.bounds.width
            zoomScale = max(minimumZoomScale, min(1, bounds.width / w))
        }
        let slack = max((bounds.width - contentSize.width) / 2, 0)
        contentInset = UIEdgeInsets(top: 0, left: slack, bottom: 0, right: slack)
        updateVisible()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisible() }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { setNeedsLayout() }

    /// Re-renders one page (the host edited it).
    func refresh(pageId: String) {
        guard let i = sources.firstIndex(where: { $0.page.id == pageId }) else { return }
        imageViews[i]?.removeFromSuperview()
        imageViews[i] = nil
        rendering.remove(i)
        updateVisible()
    }

    private func updateVisible() {
        guard !sources.isEmpty else { return }
        let vis = convert(bounds, to: content)
        let band = vis.insetBy(dx: 0, dy: -max(vis.height, 600))
        for (i, f) in frames.enumerated() {
            let near = f.intersects(band)
            if near {
                if imageViews[i] == nil && !rendering.contains(i) { render(i) }
            } else if let v = imageViews[i] {
                v.removeFromSuperview()
                imageViews[i] = nil
            }
        }
    }

    private func render(_ i: Int) {
        rendering.insert(i)
        let src = sources[i]
        let gen = generation
        queue.async { [weak self] in
            let image = PageRenderer.image(src, scale: 1.5)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.rendering.remove(i)
                let v = UIImageView(image: image)
                v.frame = self.frames[i]
                v.layer.cornerRadius = 4
                v.clipsToBounds = true
                self.content.addSubview(v)
                self.imageViews[i] = v
            }
        }
    }
}

struct ReadOnlyColumn: UIViewRepresentable {
    let sources: [PageRenderer.Source]

    func makeUIView(context: Context) -> ReadOnlyColumnView {
        let v = ReadOnlyColumnView(frame: .zero)
        v.load(sources)
        return v
    }

    func updateUIView(_ view: ReadOnlyColumnView, context: Context) {}
}

// MARK: - PDF and image references

struct PDFReferenceView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .clear
        v.document = PDFDocument(url: url)
        return v
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

// MARK: - The pane

/// The split pane for a host notebook: header (title, dock / float, close) over the reference content.
struct SplitPaneView: View {
    let session: NotebookSession
    @Binding var state: SplitState
    let onClose: () -> Void

    @State private var sources: [PageRenderer.Source]?

    private var title: String {
        switch state.kind {
        case .page: return state.notebookId.flatMap { session.library.notebook($0)?.name } ?? "Notebook"
        case .pdf, .image: return state.fileName ?? "Reference"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            SwiftUI.Divider()
            content
        }
        .background(Color(.secondarySystemBackground))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: state.kind == .page ? "book" : (state.kind == .pdf ? "doc.richtext" : "photo"))
                .foregroundStyle(.secondary)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            if state.kind != .image {
                Button { state.floating.toggle() } label: {
                    Image(systemName: state.floating ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(state.floating ? "Dock pane" : "Float pane")
            }
            Button(action: onClose) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                .accessibilityLabel("Close split screen")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    @ViewBuilder
    private var content: some View {
        switch state.kind {
        case .page:
            if let sources {
                ReadOnlyColumn(sources: sources)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await loadSources() }
            }
        case .pdf:
            if let ext = state.payloadExtension {
                PDFReferenceView(url: SplitStore.payloadURL(hostId: session.doc.id, ext: ext))
            }
        case .image:
            if let ext = state.payloadExtension,
               let img = UIImage(contentsOfFile: SplitStore.payloadURL(hostId: session.doc.id, ext: ext).path) {
                Image(uiImage: img).resizable().scaledToFit().padding(8)
            }
        }
    }

    private func loadSources() async {
        guard let id = state.notebookId else { return }
        let files = session.library.files
        let loaded: [PageRenderer.Source] = await Task.detached(priority: .userInitiated) {
            guard let doc = files.loadDocument(id) else { return [] }
            return doc.pages.map { Exporter.source($0, in: doc) }
        }.value
        sources = loaded
    }
}

// MARK: - Floating box

/// A box floating over the notebook: dragged by its header, resized by its corner, clamped to the screen.
struct FloatingBox<Content: View>: View {
    @Binding var rect: FloatRect
    let container: CGSize
    @ViewBuilder let content: () -> Content

    private var bounds: (w: Double, h: Double) { (Double(container.width), Double(container.height)) }

    @State private var dragStart: FloatRect?
    @State private var resizeStart: FloatRect?

    var body: some View {
        let r = rect.clamped(in: bounds)
        content()
            .frame(width: r.w, height: r.h)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            .overlay(alignment: .top) {
                // the header strip moves the box; its buttons sit above this and keep their own taps
                Color.clear.frame(height: 44).padding(.trailing, 90).contentShape(Rectangle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gesture(DragGesture(coordinateSpace: .global).onChanged { g in
                        let start = dragStart ?? r
                        dragStart = start
                        rect = FloatRect(x: start.x + g.translation.width, y: start.y + g.translation.height, w: start.w, h: start.h)
                            .clamped(in: bounds)
                    }.onEnded { _ in dragStart = nil })
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .rotationEffect(.degrees(90))
                    .font(.caption)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .global).onChanged { g in
                        let start = resizeStart ?? r
                        resizeStart = start
                        rect = FloatRect(x: start.x, y: start.y, w: start.w + g.translation.width, h: start.h + g.translation.height)
                            .clamped(in: bounds)
                    }.onEnded { _ in resizeStart = nil })
                    .accessibilityLabel("Resize")
            }
            .offset(x: r.x, y: r.y)
    }
}
