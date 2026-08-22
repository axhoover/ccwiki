// Prints the CGWindowID of the frontmost window owned by the named app.
//
// Used by scripts/shots.sh: `screencapture -l` needs a window number, and the
// AppleScript route to one needs the Accessibility permission on top of the
// Screen Recording permission the capture itself needs. CoreGraphics needs
// neither, so this is the smaller ask.
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "CityDesk"
let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    guard window[kCGWindowOwnerName as String] as? String == owner,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, width > 300,
          let number = window[kCGWindowNumber as String] as? Int
    else { continue }
    print(number)
    exit(0)
}
exit(1)
