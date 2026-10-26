import AppKit

// Small helpers for building the UI in code with Auto Layout.

func label(_ text: String, secondary: Bool = false, small: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    if secondary { l.textColor = .secondaryLabelColor }
    if small { l.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize) }
    l.lineBreakMode = .byTruncatingTail
    return l
}

func button(_ title: String, _ target: AnyObject?, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    return b
}

func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = .centerY
    s.spacing = spacing
    return s
}

func vstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = spacing
    return s
}

extension NSView {
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }

    /// Makes a view added to a vertical stack span the stack's full width.
    func fillWidth(of stack: NSStackView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left),
            trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right),
        ])
    }
}

/// A titled group box whose content fills it.
func box(_ title: String, _ content: NSView) -> NSBox {
    let b = NSBox()
    b.title = title
    b.titlePosition = .atTop
    b.contentViewMargins = NSSize(width: 10, height: 8)
    let holder = b.contentView!
    holder.addSubview(content)
    content.pinEdges(to: holder, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
    b.setContentHuggingPriority(.defaultHigh, for: .vertical)
    return b
}

func setEnabled(_ enabled: Bool, _ views: [NSControl]) {
    views.forEach { $0.isEnabled = enabled }
}
