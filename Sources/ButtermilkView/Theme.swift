#if canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#endif

/// Fonts, colors and spacing used to render a document.
public struct Theme {
    public var font: PlatformFont
    public var codeFont: PlatformFont
    public var textColor: PlatformColor
    public var secondaryColor: PlatformColor
    public var linkColor: PlatformColor
    public var codeBackground: PlatformColor
    public var selectedCellBackground: PlatformColor
    /// Font size multipliers for heading levels 1 to 6.
    public var headingScale: [CGFloat] = [1.9, 1.5, 1.25, 1.1, 1.0, 0.9]
    /// Space after each block.
    public var blockSpacing: CGFloat = 8
    /// Indentation per nesting level (lists and quotes).
    public var indent: CGFloat = 24
    public var lineHeightMultiple: CGFloat = 1.15

    public init(font: PlatformFont, codeFont: PlatformFont, textColor: PlatformColor, secondaryColor: PlatformColor,
                linkColor: PlatformColor, codeBackground: PlatformColor, selectedCellBackground: PlatformColor) {
        self.font = font; self.codeFont = codeFont; self.textColor = textColor; self.secondaryColor = secondaryColor
        self.linkColor = linkColor; self.codeBackground = codeBackground; self.selectedCellBackground = selectedCellBackground
    }

    /// The system look: system fonts and semantic colors, so dark mode works.
    public static var standard: Theme {
        #if canImport(AppKit)
        let size = NSFont.systemFontSize + 2
        return Theme(font: .systemFont(ofSize: size), codeFont: .monospacedSystemFont(ofSize: size - 1, weight: .regular),
                     textColor: .textColor, secondaryColor: .secondaryLabelColor, linkColor: .linkColor,
                     codeBackground: .quaternaryLabelColor.withAlphaComponent(0.12),
                     selectedCellBackground: .selectedTextBackgroundColor)
        #else
        let body = UIFont.preferredFont(forTextStyle: .body)
        return Theme(font: body, codeFont: .monospacedSystemFont(ofSize: body.pointSize - 1, weight: .regular),
                     textColor: .label, secondaryColor: .secondaryLabel, linkColor: .link,
                     codeBackground: .tertiarySystemFill, selectedCellBackground: .systemBlue.withAlphaComponent(0.25))
        #endif
    }
}

extension PlatformFont {
    func with(bold: Bool = false, italic: Bool = false, size: CGFloat? = nil) -> PlatformFont {
        #if canImport(AppKit)
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size ?? pointSize) ?? self
        #else
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let descriptor = fontDescriptor.withSymbolicTraits(traits) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: size ?? pointSize)
        #endif
    }

    var isBold: Bool {
        #if canImport(AppKit)
        fontDescriptor.symbolicTraits.contains(.bold)
        #else
        fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    var isItalic: Bool {
        #if canImport(AppKit)
        fontDescriptor.symbolicTraits.contains(.italic)
        #else
        fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }
}
