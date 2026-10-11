// Prints the CGWindowID of the frontmost window of one app: the process with
// the given pid, or, given anything else, the app with that name.
//
//   window-id <pid>      what scripts/shots.sh uses
//   window-id <name>     e.g. "CCwiki Dev"
//
// Used by scripts/shots.sh: `screencapture -l` needs a window number, and the
// AppleScript route to one needs the Accessibility permission on top of the
// Screen Recording permission the capture itself needs. CoreGraphics needs
// neither, so this is the smaller ask.
//
// shots.sh passes the pid of the build it launched. A name would also match
// another copy: the release, "CCwiki", is often open beside the build from
// source, which is "CCwiki Dev", and a capture of the wrong window looks
// plausible enough to go unnoticed.
import CoreGraphics
import Foundation

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "CCwiki Dev"
let pid = Int(target)
let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let isTarget: Bool
    if let pid {
        isTarget = window[kCGWindowOwnerPID as String] as? Int == pid
    } else {
        isTarget = window[kCGWindowOwnerName as String] as? String == target
    }
    guard isTarget,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, width > 300,
          let number = window[kCGWindowNumber as String] as? Int
    else { continue }
    print(number)
    exit(0)
}
exit(1)
