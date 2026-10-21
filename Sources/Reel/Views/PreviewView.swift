import AppKit
import AVFoundation
import SwiftUI

struct PreviewView: NSViewRepresentable {
    let studio: Studio
    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(studio: studio) }
    func updateNSView(_ nsView: PreviewNSView, context: Context) {}
}

/// Shows the player. Click to play/pause; drag the selected graphic to move it on the frame.
final class PreviewNSView: NSView {
    private let studio: Studio
    private let playerLayer = AVPlayerLayer()
    private var dragging: (id: UUID, offset: CGPoint)?
    private var downPoint: CGPoint?

    init(studio: Studio) {
        self.studio = studio
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = studio.player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    /// The area the video occupies inside the view (y up, like AppKit's default).
    private var videoRect: CGRect {
        let size = studio.previewSize
        let s = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// Normalised frame position, (0,0) = top-left.
    private func normalized(_ p: CGPoint) -> CGPoint {
        let r = videoRect
        return CGPoint(x: (p.x - r.minX) / r.width, y: 1 - (p.y - r.minY) / r.height)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        downPoint = p
        if case .graphic(let id)? = studio.selection, let g = studio.project.graphics.first(where: { $0.id == id }),
           g.start <= studio.playback.time, studio.playback.time < g.end {
            let n = normalized(p)
            // Grab anywhere near the graphic.
            if abs(n.x - g.x) < max(0.08, g.scale / 2), abs(n.y - g.y) < max(0.08, g.scale) {
                studio.checkpoint()
                dragging = (id, CGPoint(x: g.x - n.x, y: g.y - n.y))
                NSCursor.closedHand.set()
            }
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let dragging else { return }
        let n = normalized(convert(e.locationInWindow, from: nil))
        studio.updateGraphic(dragging.id) {
            $0.x = min(1, max(0, n.x + dragging.offset.x))
            $0.y = min(1, max(0, n.y + dragging.offset.y))
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer { dragging = nil; downPoint = nil; NSCursor.arrow.set() }
        let p = convert(e.locationInWindow, from: nil)
        if dragging == nil, let d = downPoint, hypot(p.x - d.x, p.y - d.y) < 4 {
            if e.clickCount == 2 { window?.toggleFullScreen(nil) } else { studio.togglePlay() }
        }
    }
}

/// Global playback/editing keys. Ignored while typing in a text field.
struct KeyCatcher: NSViewRepresentable {
    let studio: Studio

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(studio: studio, view: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?
        private var shuttle: Float = 0

        func install(studio: Studio, view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] e in
                guard let self, let window = view?.window, e.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSText) else { return e }
                let mods = e.modifierFlags.intersection([.command, .control, .option])
                guard mods.isEmpty else { return e }
                let shift = e.modifierFlags.contains(.shift)
                switch e.keyCode {
                case 49: studio.togglePlay(); return nil                                  // space
                case 123: studio.step(frames: shift ? -studio.project.fps : -1); return nil // ←
                case 124: studio.step(frames: shift ? studio.project.fps : 1); return nil   // →
                case 51, 117: studio.deleteSelection(); return nil                       // delete
                case 115: studio.seek(to: 0); return nil                                  // home
                case 119: studio.seek(to: studio.project.duration); return nil            // end
                default: break
                }
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "s"?, "b"?: studio.split(); return nil
                case "k"?: self.shuttle = 0; studio.pause(); return nil
                case "l"?:
                    self.shuttle = self.shuttle <= 0 ? 1 : min(8, self.shuttle * 2)
                    studio.shuttle(self.shuttle); return nil
                case "j"?:
                    self.shuttle = self.shuttle >= 0 ? -1 : max(-8, self.shuttle * 2)
                    studio.shuttle(self.shuttle); return nil
                case "t"?: studio.addTitle(style: .bold); return nil
                default: return e
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
