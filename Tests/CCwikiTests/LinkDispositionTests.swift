import AppKit
import Foundation
import Testing
@testable import CCwiki

/// What a click on a link means, as Safari reads it (reader-comforts §1.4).
/// The page's links, the rows SwiftUI draws and the links WebKit follows
/// itself all come through this one table, so a ⌘-click means the same
/// thing wherever it lands.
struct LinkDispositionTests {

    private static func click(
        command: Bool = false, shift: Bool = false, option: Bool = false, middle: Bool = false
    ) -> LinkDisposition {
        LinkDisposition.forClick(command: command, shift: shift, option: option, middleButton: middle)
    }

    // MARK: The table

    @Test("a click, or ⇧ or ⌥ alone, opens the link where you are")
    func here() {
        #expect(Self.click() == .here)
        #expect(Self.click(shift: true) == .here)
        #expect(Self.click(option: true) == .here)
        #expect(Self.click(shift: true, option: true) == .here)
    }

    @Test("⌘-click opens a tab behind the current one; ⇧⌘-click opens one in front")
    func tabs() {
        #expect(Self.click(command: true) == .newTab(inBackground: true))
        #expect(Self.click(command: true, shift: true) == .newTab(inBackground: false))
    }

    @Test("⌥⌘-click opens a new window, with ⇧ or without")
    func window() {
        #expect(Self.click(command: true, option: true) == .newWindow)
        #expect(Self.click(command: true, shift: true, option: true) == .newWindow)
    }

    @Test("the middle button is a ⌘-click without the key")
    func middleButton() {
        #expect(Self.click(middle: true) == .newTab(inBackground: true))
        #expect(Self.click(shift: true, middle: true) == .newTab(inBackground: false))
        #expect(Self.click(option: true, middle: true) == .newWindow)
        #expect(Self.click(command: true, middle: true) == .newTab(inBackground: true))
    }

    @Test("no click opens the site: only the link menu's Open Link on cryptology.city does")
    func neverOnSite() {
        for command in [false, true] {
            for shift in [false, true] {
                for option in [false, true] {
                    for middle in [false, true] {
                        let disposition = Self.click(
                            command: command, shift: shift, option: option, middle: middle)
                        #expect(disposition != .onSite)
                    }
                }
            }
        }
    }

    // MARK: The page's message

    @Test("the navigate message is read key by key")
    func readsMessage() {
        let message: [String: Any] = [
            "type": "navigate",
            "href": "ccwiki://wiki/page/Primitives%2Fpseudorandom-function.md",
            "command": true,
            "shift": true,
            "option": false,
            "middleButton": false,
        ]
        #expect(LinkDisposition.forClick(message: message) == .newTab(inBackground: false))
    }

    @Test("JavaScript's Booleans arrive as NSNumber and read as Booleans")
    func bridgedBooleans() {
        let message: [String: Any] = [
            "command": NSNumber(value: false),
            "shift": NSNumber(value: false),
            "option": NSNumber(value: false),
            "middleButton": NSNumber(value: true),
        ]
        #expect(LinkDisposition.forClick(message: message) == .newTab(inBackground: true))
    }

    @Test("a key that is missing, null or not a Boolean is not held")
    func absentKeys() {
        let bare: [String: Any] = ["type": "navigate", "href": "ccwiki://wiki/folder/Primitives"]
        #expect(LinkDisposition.forClick(message: bare) == .here)

        let odd: [String: Any] = ["command": NSNull(), "middleButton": "yes", "shift": true]
        #expect(LinkDisposition.forClick(message: odd) == .here)
    }

    @Test("the old single modified flag is not read: the page sends each key")
    func oldMessage() {
        let message: [String: Any] = ["type": "navigate", "href": "x", "modified": true]
        #expect(LinkDisposition.forClick(message: message) == .here)
    }

    // MARK: Links WebKit follows itself

    @Test("WebKit's button mask: 4 is the middle button, 1 the primary, 0 none")
    func navigationButtons() {
        #expect(LinkDisposition.forNavigation(buttonNumber: 4, modifierFlags: [])
            == .newTab(inBackground: true))
        #expect(LinkDisposition.forNavigation(buttonNumber: 1, modifierFlags: []) == .here)
        #expect(LinkDisposition.forNavigation(buttonNumber: 0, modifierFlags: []) == .here)
    }

    @Test("WebKit's modifier flags read as the page's keys do")
    func navigationModifiers() {
        #expect(LinkDisposition.forNavigation(buttonNumber: 1, modifierFlags: [.command])
            == .newTab(inBackground: true))
        #expect(LinkDisposition.forNavigation(buttonNumber: 1, modifierFlags: [.command, .shift])
            == .newTab(inBackground: false))
        #expect(LinkDisposition.forNavigation(buttonNumber: 1, modifierFlags: [.command, .option])
            == .newWindow)
        #expect(LinkDisposition.forNavigation(buttonNumber: 1, modifierFlags: [.shift]) == .here)
        #expect(LinkDisposition.forNavigation(buttonNumber: 4, modifierFlags: [.option])
            == .newWindow)
    }

    @Test("keys that are not part of the table change nothing")
    func otherModifiers() {
        #expect(LinkDisposition.forNavigation(
            buttonNumber: 1, modifierFlags: [.command, .capsLock, .function, .numericPad])
            == .newTab(inBackground: true))
        #expect(LinkDisposition.forNavigation(buttonNumber: 1, modifierFlags: [.control]) == .here)
    }
}
