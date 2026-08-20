import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let warningLabel: NSMenuItem
    private let toggleItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        warningLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warningLabel.isEnabled = false
        warningLabel.isHidden = true
        menu.addItem(warningLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = Self.idleImage
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state in the icon tint, the menu bar title, and the
    /// menu item titles. The counter sits beside the feather so elapsed time is
    /// readable at a glance without opening the menu; idle shows the icon
    /// alone, so the width cost is paid only while recording. Call once a
    /// second while recording.
    func update(recording: Bool, elapsed: String?) {
        let counter = elapsed ?? "0:00"
        stateLabel.title = recording ? "● recording · \(counter)" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        if let button = statusItem.button {
            // The menu bar is a vibrant appearance, where a template image is
            // drawn as a mask in the system-determined colour — vibrancy
            // discards contentTintColor, so the feather came out monochrome
            // (and black, since the SVG's `currentColor` strokes rasterise
            // black). Swap in a non-template image with the colour baked in;
            // those render their own pixels and are unaffected.
            button.image = recording ? Self.recordingImage : Self.idleImage
            // The red feather is the state signal; the digits are data, so
            // they stay in the normal menu bar colour — systemRed is a
            // saturated indicator colour and hard to read as text. The colour
            // is set explicitly because an attributedTitle renders with its
            // own attributes and inherits nothing from the button.
            //
            // Monospaced digits, or the title reflows every time a digit
            // changes width and the whole menu bar jitters once a second.
            button.attributedTitle = recording
                ? NSAttributedString(
                    string: " \(counter)",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(
                            ofSize: NSFont.smallSystemFontSize,
                            weight: .regular
                        ),
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
                : NSAttributedString(string: "")
        }
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    /// Show a persistent warning line in the menu; nil hides it. Used when a
    /// recording is running but producing unusable audio — the user needs to
    /// see it while there is still a meeting left to save.
    func updateWarning(_ text: String?) {
        warningLabel.title = text ?? ""
        warningLabel.isHidden = text == nil
    }

    /// Idle: a template image, so the system paints it to match the menu bar
    /// in either appearance. Recording: colour baked in, template off.
    private static let idleImage: NSImage? = {
        let image = featherImage()
        image?.isTemplate = true
        return image
    }()

    private static let recordingImage: NSImage? = {
        guard let base = featherImage() else { return nil }
        return tinted(base, with: .systemRed)
    }()

    /// Repaint an image's opaque pixels in `color`. Works off the alpha
    /// channel, so it doesn't matter what colour the source rasterised to —
    /// which is the point, since the SVG's `currentColor` gives us black.
    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}
