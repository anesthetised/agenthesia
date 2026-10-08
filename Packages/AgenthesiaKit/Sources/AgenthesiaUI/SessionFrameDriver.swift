import AgenthesiaCore
import AppKit

/// The live session view owns this driver and stops it when detached. Hidden views can flush on reappearance.
final class SessionFrameDriver {
    private final class Target: NSObject {
        weak var session: SessionController?

        @objc func tick(_ link: CADisplayLink) { session?.publishTranscript() }
    }

    private let target = Target()
    private var link: CADisplayLink?

    func start(session: SessionController, in view: NSView) {
        stop()
        target.session = session
        let link = view.displayLink(target: target, selector: #selector(Target.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        session.publishTranscript()
    }

    func stop() {
        link?.invalidate()
        link = nil
        target.session?.publishTranscript()
        target.session = nil
    }

    isolated deinit { link?.invalidate() }
}
