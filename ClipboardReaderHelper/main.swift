import Foundation
import AppKit
import Darwin

private enum HelperExit: Int32 {
    case success = 0
    case unavailable = 10
    case unstable = 11
    case oversized = 12
    case invalidArguments = 13
    case watchdogExpired = 14
}

private struct Arguments {
    let pasteboardName: String
    let type: String
    let expectedChangeCount: Int
    let mode: String
    let maximumBytes: Int
    let selfTimeoutMilliseconds: Int

    init?(_ values: [String]) {
        var parsed: [String: String] = [:]
        var index = 1
        while index + 1 < values.count {
            parsed[values[index]] = values[index + 1]
            index += 2
        }
        guard let pasteboardName = parsed["--pasteboard-name"],
              let type = parsed["--type"],
              let expectedString = parsed["--expected-change-count"],
              let expectedChangeCount = Int(expectedString),
              let mode = parsed["--mode"],
              mode == "data" || mode == "string",
              let maximumString = parsed["--maximum-bytes"],
              let maximumBytes = Int(maximumString),
              maximumBytes > 0,
              let timeoutString = parsed["--self-timeout-milliseconds"],
              let selfTimeoutMilliseconds = Int(timeoutString),
              (100...60_000).contains(selfTimeoutMilliseconds) else { return nil }
        self.pasteboardName = pasteboardName
        self.type = type
        self.expectedChangeCount = expectedChangeCount
        self.mode = mode
        self.maximumBytes = maximumBytes
        self.selfTimeoutMilliseconds = selfTimeoutMilliseconds
    }
}

private func finish(_ status: HelperExit) -> Never {
    Darwin.exit(status.rawValue)
}

guard let arguments = Arguments(CommandLine.arguments) else {
    finish(.invalidArguments)
}

DispatchQueue.global(qos: .utility).asyncAfter(
    deadline: .now() + .milliseconds(arguments.selfTimeoutMilliseconds)
) {
    Darwin._exit(HelperExit.watchdogExpired.rawValue)
}

let pasteboard = NSPasteboard(name: NSPasteboard.Name(arguments.pasteboardName))
let pasteboardType = NSPasteboard.PasteboardType(arguments.type)
let beforeCount = pasteboard.changeCount
let beforeTypes = pasteboard.types?.map(\.rawValue).sorted() ?? []
guard beforeCount == arguments.expectedChangeCount,
      beforeTypes.contains(arguments.type) else {
    finish(.unstable)
}

let payload: Data?
if arguments.mode == "string" {
    payload = pasteboard.string(forType: pasteboardType)?.data(using: .utf8)
} else {
    payload = pasteboard.data(forType: pasteboardType)
}

let afterCount = pasteboard.changeCount
let afterTypes = pasteboard.types?.map(\.rawValue).sorted() ?? []
guard afterCount == beforeCount, afterTypes == beforeTypes else {
    finish(.unstable)
}
guard let payload else {
    finish(.unavailable)
}
guard payload.count <= arguments.maximumBytes else {
    finish(.oversized)
}

FileHandle.standardOutput.write(payload)
finish(.success)
