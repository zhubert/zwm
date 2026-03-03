import CoreGraphics

/// The minimal set of backend calls needed to transition from one layout to the next.
public struct FrameDiff: Sendable, Equatable {
    /// Windows whose frame changed and need a setFrame call.
    public let toSet: [FrameChange]
    /// Window that should receive focus, if changed.
    public let toFocus: UInt32?

    public init(toSet: [FrameChange] = [], toFocus: UInt32? = nil) {
        self.toSet = toSet
        self.toFocus = toFocus
    }

    public var isEmpty: Bool {
        toSet.isEmpty && toFocus == nil
    }
}

public struct FrameChange: Sendable, Equatable {
    public let windowId: UInt32
    public let frame: CGRect

    public init(windowId: UInt32, frame: CGRect) {
        self.windowId = windowId
        self.frame = frame
    }
}

/// Compare old and new layout results to produce the minimal set of changes.
/// Only includes windows whose frame moved by more than `tolerance` pixels
/// (avoids floating-point jitter).
public func diffLayouts(
    old: LayoutResult,
    new: LayoutResult,
    oldFocusedWindowId: UInt32?,
    newFocusedWindowId: UInt32?,
    tree: TreeState,
    tolerance: CGFloat = 1.0
) -> FrameDiff {
    var changes: [FrameChange] = []

    for (nodeId, newFrame) in new.frames {
        // Look up the macOS window ID for this node
        guard let windowNode = tree.windowNode(nodeId) else { continue }
        let wid = windowNode.windowId

        if let oldFrame = old.frames[nodeId] {
            if !framesEqual(oldFrame, newFrame, tolerance: tolerance) {
                changes.append(FrameChange(windowId: wid, frame: newFrame))
            }
        } else {
            // New window not in old layout — always set
            changes.append(FrameChange(windowId: wid, frame: newFrame))
        }
    }

    let focusChange: UInt32?
    if newFocusedWindowId != oldFocusedWindowId {
        focusChange = newFocusedWindowId
    } else {
        focusChange = nil
    }

    return FrameDiff(toSet: changes, toFocus: focusChange)
}

private func framesEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
    abs(a.origin.x - b.origin.x) < tolerance
        && abs(a.origin.y - b.origin.y) < tolerance
        && abs(a.size.width - b.size.width) < tolerance
        && abs(a.size.height - b.size.height) < tolerance
}
