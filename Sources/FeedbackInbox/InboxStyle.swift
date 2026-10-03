import SwiftUI

/// Semantic presentation values. Consumers can pass their existing design-system roles.
@MainActor public struct InboxStyle {
    public var background: Color
    public var composerBackground: Color
    public var cardBackground: Color
    public var ink: Color
    public var secondaryInk: Color
    public var errorInk: Color
    public var accent: Color
    public var onAccent: Color
    public var controlFont: Font
    public var bodyFont: Font
    public var titleFont: Font
    public var captionFont: Font
    public var navigationFont: Font
    public var inset: CGFloat
    public var spacing: CGFloat
    public var controlSpacing: CGFloat
    public var radius: CGFloat
    public var touchSize: CGFloat
    public init(background: Color = .clear, composerBackground: Color? = nil, cardBackground: Color = .secondary.opacity(0.08),
                ink: Color = .primary, secondaryInk: Color = .secondary, errorInk: Color = .red,
                accent: Color = .accentColor, onAccent: Color = .white, controlFont: Font = .body,
                bodyFont: Font = .body, titleFont: Font = .headline, captionFont: Font = .caption,
                navigationFont: Font = .body, inset: CGFloat = 16, spacing: CGFloat = 12,
                controlSpacing: CGFloat = 8, radius: CGFloat = 12, touchSize: CGFloat = 44) {
        self.background=background; self.composerBackground=composerBackground ?? background; self.cardBackground=cardBackground; self.ink=ink; self.secondaryInk=secondaryInk
        self.errorInk=errorInk; self.accent=accent; self.onAccent=onAccent; self.controlFont=controlFont
        self.bodyFont=bodyFont; self.titleFont=titleFont; self.captionFont=captionFont; self.navigationFont=navigationFont
        self.inset=inset; self.spacing=spacing; self.controlSpacing=controlSpacing; self.radius=radius; self.touchSize=touchSize
    }
}
