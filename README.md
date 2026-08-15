# Floating Rows for NSOutlineView

This Swift package provides floating header rows for AppKit’s `NSOutlineView`.
The idea is the same as `floatsGroupRows` for `NSTableView`, but extended to support a multi-level stack of floating rows.

https://github.com/user-attachments/assets/a3406a8b-dfe1-4993-bca0-dfd733930242

## Usage

This library only manages the row stack; the views for the floating rows are left up to you.

An example usage for a view controller that manages an outline view could look like this:

```swift
import FloatingRowStack

final class SomeViewController: NSViewController {
    // ...
    
    private var floatingRowStack: FloatingRowStack? = nil
    
    private func someSetup() {
        self.floatingRowStack = FloatingRowStack(
            outlineView: self.outlineView,
            configuration: FloatingRowStack.Configuration(
                stackRowHeight: 22.0,
                minDescendantsHeight: 3.0 * 22.0),
            containerView: self.floatingView,
            makeRowView: { [weak self] level, item in
                guard level <= 2 else {
                    return nil
                }
                return self?.makeFloatingStackRowView(level: level, item: item)
            })
    }
}
```

The following is an example SwiftUI implementation for the `containerView`:

```swift
import SwiftUI

struct FloatingView: View {
    let contentView: NSView
    
    var body: some View {
        StaticViewRepresentation(view: self.contentView)
            .background {
                Canvas { canvas, size in
                    let stackRowHeight = 22.0
                    
                    func drawLine(y: CGFloat, inset: CGFloat) {
                        let line = Path {
                            $0.move(to: CGPoint(x: inset, y: y))
                            $0.addLine(to: CGPoint(x: size.width - inset, y: y))
                            $0.addLine(to: CGPoint(x: size.width - inset, y: y - 1.0))
                            $0.addLine(to: CGPoint(x: inset, y: y - 1.0))
                            $0.closeSubpath()
                        }
                        canvas.fill(line, with: .color(Color(NSColor.separatorColor)))
                    }
                    
                    for y in stride(from: stackRowHeight, to: size.height, by: stackRowHeight) {
                        drawLine(y: y, inset: 16.0)
                    }
                    
                    drawLine(y: size.height, inset: 0)
                }
            }
            .background(.regularMaterial)
            .background(alignment: .bottom) {
                // shadow below floating row stack
                LinearGradient(
                    colors: [.black.opacity(0.5), .black.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom)
                .frame(height: 12.0)
                .offset(y: 12.0)
            }
    }
}

struct StaticViewRepresentation: NSViewRepresentable {
    let view: NSView
    
    func makeNSView(context: Context) -> some NSView {
        self.view
    }
    
    func updateNSView(_ nsView: NSViewType, context: Context) {}
}
```

The above `FloatingView` would be used like this:

```swift
let floatingView = FloatingView(contentView: NSView())

self.floatingRowStack = FloatingRowStack(
    // ...
    containerView: NSHostingView(rootView: floatingView),
    contentView: floatingView.contentView,
    // ...
)
```
