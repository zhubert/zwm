import CoreGraphics
import Testing
@testable import ZWMServer

@Test func parseSimpleKey() {
    let combo = parseKeyCombo("h")
    #expect(combo != nil)
    #expect(combo?.keyCode == 0x04)
    #expect(combo?.modifiers == CGEventFlags())
}

@Test func parseAltKey() {
    let combo = parseKeyCombo("alt-h")
    #expect(combo != nil)
    #expect(combo?.keyCode == 0x04)
    #expect(combo?.modifiers == .maskAlternate)
}

@Test func parseAltShiftKey() {
    let combo = parseKeyCombo("alt-shift-h")
    #expect(combo != nil)
    #expect(combo?.keyCode == 0x04)
    let expected: CGEventFlags = [.maskAlternate, .maskShift]
    #expect(combo?.modifiers == expected)
}

@Test func parseCtrlCmdKey() {
    let combo = parseKeyCombo("ctrl-cmd-q")
    #expect(combo != nil)
    #expect(combo?.keyCode == 0x0C) // q
    let expected: CGEventFlags = [.maskControl, .maskCommand]
    #expect(combo?.modifiers == expected)
}

@Test func parseNumberKey() {
    let combo = parseKeyCombo("alt-1")
    #expect(combo != nil)
    #expect(combo?.keyCode == 0x12)
    #expect(combo?.modifiers == .maskAlternate)
}

@Test func parseEnterKey() {
    let combo = parseKeyCombo("alt-enter")
    #expect(combo != nil)
    #expect(combo?.keyCode == 0x24)
}

@Test func parseOptionAlias() {
    let combo = parseKeyCombo("option-j")
    #expect(combo != nil)
    #expect(combo?.modifiers == .maskAlternate)
    #expect(combo?.keyCode == 0x26) // j
}

@Test func parseInvalidKey() {
    let combo = parseKeyCombo("alt-nonexistent")
    #expect(combo == nil)
}

@Test func parseEmptyString() {
    let combo = parseKeyCombo("")
    #expect(combo == nil)
}

@Test func parseArrowKeys() {
    #expect(parseKeyCombo("alt-left")?.keyCode == 0x7B)
    #expect(parseKeyCombo("alt-right")?.keyCode == 0x7C)
    #expect(parseKeyCombo("alt-down")?.keyCode == 0x7D)
    #expect(parseKeyCombo("alt-up")?.keyCode == 0x7E)
}
