//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2019 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////


import Foundation
import SSH
import Combine
import Dispatch
import ios_system

@_cdecl("blink_ssh_main")
public func blink_ssh_main(argc: Int32, argv: Argv) -> Int32 {
  setvbuf(thread_stdin, nil, _IONBF, 0)
  setvbuf(thread_stdout, nil, _IONBF, 0)
  setvbuf(thread_stderr, nil, _IONBF, 0)
  
  let session = Unmanaged<MCPSession>.fromOpaque(thread_context).takeUnretainedValue()
  let cmd = BlinkSSH(mcp: session)
  return cmd.start(argc, argv: argv.args(count: argc))
}

@_cdecl("tmux_attach_main")
public func tmux_attach_main(argc: Int32, argv: Argv) -> Int32 {
  setvbuf(thread_stdin, nil, _IONBF, 0)
  setvbuf(thread_stdout, nil, _IONBF, 0)
  setvbuf(thread_stderr, nil, _IONBF, 0)

  let args = Array(argv.args(count: argc).dropFirst())
  if args.count == 1, args[0] == "-h" || args[0] == "--help" {
    tmuxAttachWriteLine(tmuxAttachUsage, stream: thread_stdout)
    return 0
  }

  guard let token = tmuxAttachTokenArgument(from: args) else {
    tmuxAttachWriteLine(tmuxAttachUsage, stream: thread_stderr)
    return -1
  }

  guard let request = TmuxNotificationRequest.fromTmuxAttachToken(token) else {
    tmuxAttachWriteLine("Invalid tmux attach token.", stream: thread_stderr)
    return -1
  }

  let invocation: TmuxAttachInvocation
  do {
    invocation = try TmuxAttachInvocation.build(from: request)
  } catch {
    tmuxAttachWriteLine(error.localizedDescription, stream: thread_stderr)
    return -1
  }

  let session = Unmanaged<MCPSession>.fromOpaque(thread_context).takeUnretainedValue()
  let cmd = BlinkSSH(mcp: session)
  return cmd.start(Int32(invocation.sshArgv.count), argv: invocation.sshArgv)
}

@_cdecl("tmux_pane_bridge_main")
public func tmux_pane_bridge_main(argc: Int32, argv: Argv) -> Int32 {
  setvbuf(thread_stdin, nil, _IONBF, 0)
  setvbuf(thread_stdout, nil, _IONBF, 0)
  setvbuf(thread_stderr, nil, _IONBF, 0)

  let args = Array(argv.args(count: argc).dropFirst())
  if args.count == 1, args[0] == "-h" || args[0] == "--help" {
    tmuxAttachWriteLine(tmuxPaneBridgeUsage, stream: thread_stdout)
    return 0
  }

  let request: TmuxNotificationRequest
  switch tmuxPaneBridgeResolveRequest(from: args) {
  case .success(let value):
    request = value
  case .failure(let error):
    switch error {
    case .missingRequestSpecifier:
      tmuxAttachWriteLine(tmuxPaneBridgeUsage, stream: thread_stderr)
    default:
      tmuxAttachWriteLine(error.localizedDescription, stream: thread_stderr)
    }
    return -1
  }

  let session = Unmanaged<MCPSession>.fromOpaque(thread_context).takeUnretainedValue()
  let cmd = TmuxPaneBridgeCommand(mcp: session)
  let attemptID = tmuxPaneBridgeAttemptIDArgument(from: args)
  return cmd.start(request: request, attemptID: attemptID)
}

let tmuxAttachUsage = "Usage: tmux-attach --token <base64url-json>"
let tmuxPaneBridgeUsage = "Usage: tmux-pane-bridge --request-id <uuid> | --token <base64url-json> [--attempt-id <uuid>]"

func tmuxAttachTokenArgument(from args: [String]) -> String? {
  tmuxLongOptionValue(name: "--token", from: args)
}

func tmuxPaneRequestIDArgument(from args: [String]) -> String? {
  tmuxLongOptionValue(name: "--request-id", from: args)
}

func tmuxPaneBridgeAttemptIDArgument(from args: [String]) -> String? {
  tmuxLongOptionValue(name: "--attempt-id", from: args)
}

private func tmuxLongOptionValue(name: String, from args: [String]) -> String? {
  var idx = 0
  while idx < args.count {
    let arg = args[idx]
    if arg == name {
      guard idx + 1 < args.count else {
        return nil
      }
      let value = args[idx + 1]
      return value.isEmpty ? nil : value
    }
    if arg.hasPrefix(name + "=") {
      let value = String(arg.dropFirst((name + "=").count))
      return value.isEmpty ? nil : value
    }
    idx += 1
  }
  return nil
}

enum TmuxAttachInvocationError: LocalizedError, Equatable {
  case missingHostAlias
  case missingPaneTarget
  case missingSessionName(String)

  var errorDescription: String? {
    switch self {
    case .missingHostAlias:
      return "Missing host alias in tmux attach request."
    case .missingPaneTarget:
      return "Missing pane target in tmux attach request."
    case .missingSessionName(let paneTarget):
      return "Missing session name for pane target \(paneTarget)."
    }
  }
}

struct TmuxAttachInvocation: Equatable {
  let hostAlias: String
  let remoteCommand: String

  var sshArgv: [String] {
    ["ssh", hostAlias, "-t", remoteCommand]
  }

  static func build(from request: TmuxNotificationRequest) throws -> TmuxAttachInvocation {
    let cleanHost = request.hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanHost.isEmpty else {
      throw TmuxAttachInvocationError.missingHostAlias
    }

    let cleanPane = request.paneTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanPane.isEmpty else {
      throw TmuxAttachInvocationError.missingPaneTarget
    }

    let inferredSession: String? = {
      guard let separator = cleanPane.firstIndex(of: ":") else {
        return nil
      }
      let candidate = cleanPane[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
      return candidate.isEmpty ? nil : String(candidate)
    }()
    let cleanSession = request.sessionName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? request.sessionName!.trimmingCharacters(in: .whitespacesAndNewlines)
      : (inferredSession ?? "")
    guard !cleanSession.isEmpty else {
      throw TmuxAttachInvocationError.missingSessionName(cleanPane)
    }

    let remoteCommand = "tmux attach-session -t \(tmuxShellQuote(cleanSession)) \\; select-pane -t \(tmuxShellQuote(cleanPane))"
    return TmuxAttachInvocation(hostAlias: cleanHost, remoteCommand: remoteCommand)
  }
}

extension TmuxNotificationRequest {
  var tmuxAttachToken: String? {
    guard let data = try? JSONEncoder().encode(self) else {
      return nil
    }
    return data.tmuxBase64URLString
  }

  static func fromTmuxAttachToken(_ token: String) -> TmuxNotificationRequest? {
    guard let data = Data(tmuxBase64URL: token) else {
      return nil
    }
    return try? JSONDecoder().decode(TmuxNotificationRequest.self, from: data)
  }
}

enum TmuxPaneBridgeRequestResolutionError: LocalizedError, Equatable {
  case missingRequestSpecifier
  case invalidRequestID(String)
  case invalidToken

  var errorDescription: String? {
    switch self {
    case .missingRequestSpecifier:
      return "Missing tmux pane bridge request id or token."
    case .invalidRequestID(let requestID):
      return "Invalid or expired tmux pane bridge request id '\(requestID)'."
    case .invalidToken:
      return "Invalid tmux pane bridge token."
    }
  }
}

func tmuxPaneBridgeResolveRequest(
  from args: [String],
  requestStore: TmuxPaneLaunchRequestStore = .shared
) -> Result<TmuxNotificationRequest, TmuxPaneBridgeRequestResolutionError> {
  if let requestID = tmuxPaneRequestIDArgument(from: args) {
    guard let request = requestStore.consume(requestID: requestID) else {
      return .failure(.invalidRequestID(requestID))
    }
    return .success(request)
  }

  if let token = tmuxAttachTokenArgument(from: args) {
    guard let request = TmuxNotificationRequest.fromTmuxAttachToken(token) else {
      return .failure(.invalidToken)
    }
    return .success(request)
  }

  return .failure(.missingRequestSpecifier)
}

final class TmuxPaneLaunchRequestStore {
  static let shared = TmuxPaneLaunchRequestStore()

  private struct Entry {
    let request: TmuxNotificationRequest
    let expiresAt: Date
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private let defaultTTL: TimeInterval

  init(defaultTTL: TimeInterval = 60) {
    self.defaultTTL = defaultTTL
  }

  func register(request: TmuxNotificationRequest, ttl: TimeInterval? = nil) -> String {
    let now = Date()
    let expiresAt = now.addingTimeInterval(ttl ?? defaultTTL)
    let requestID = UUID().uuidString.lowercased()

    lock.lock()
    _purgeExpiredLocked(now: now)
    entries[requestID] = Entry(request: request, expiresAt: expiresAt)
    lock.unlock()
    return requestID
  }

  func consume(requestID: String) -> TmuxNotificationRequest? {
    let cleanID = requestID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !cleanID.isEmpty else {
      return nil
    }

    let now = Date()
    lock.lock()
    _purgeExpiredLocked(now: now)
    guard let entry = entries.removeValue(forKey: cleanID), entry.expiresAt > now else {
      lock.unlock()
      return nil
    }
    lock.unlock()
    return entry.request
  }

  private func _purgeExpiredLocked(now: Date) {
    entries = entries.filter { $0.value.expiresAt > now }
  }
}

private extension Data {
  init?(tmuxBase64URL value: String) {
    var base64 = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
      base64 += String(repeating: "=", count: 4 - remainder)
    }
    guard let decoded = Data(base64Encoded: base64) else {
      return nil
    }
    self = decoded
  }

  var tmuxBase64URLString: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

private func tmuxShellQuote(_ value: String) -> String {
  "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

private func tmuxAttachWriteLine(_ message: String, stream: UnsafeMutablePointer<FILE>?) {
  guard let stream else {
    return
  }
  fputs((message + "\n"), stream)
}

enum TmuxPaneBridgeError: LocalizedError {
  case missingHostAlias
  case missingPaneTarget
  case missingSessionName
  case invalidPaneID(String)
  case remoteCommandFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingHostAlias:
      return "Missing host alias in tmux pane bridge request."
    case .missingPaneTarget:
      return "Missing pane target in tmux pane bridge request."
    case .missingSessionName:
      return "Missing session name in tmux pane bridge request."
    case .invalidPaneID(let value):
      return "Failed to resolve pane id from target. Received '\(value)'."
    case .remoteCommandFailed(let output):
      return output.isEmpty ? "Remote tmux command failed." : output
    }
  }
}

func tmuxControlModeDecodeValue(_ value: String) -> Data {
  let bytes = Array(value.utf8)
  var output: [UInt8] = []
  output.reserveCapacity(bytes.count)

  var idx = 0
  while idx < bytes.count {
    let byte = bytes[idx]
    if byte != 0x5c { // '\'
      output.append(byte)
      idx += 1
      continue
    }

    guard idx + 1 < bytes.count else {
      output.append(byte)
      idx += 1
      continue
    }

    let next = bytes[idx + 1]
    if idx + 3 < bytes.count,
       (48...55).contains(next),
       (48...55).contains(bytes[idx + 2]),
       (48...55).contains(bytes[idx + 3]) {
      let value = (next - 48) * 64 + (bytes[idx + 2] - 48) * 8 + (bytes[idx + 3] - 48)
      output.append(value)
      idx += 4
      continue
    }

    switch next {
    case 0x6e: // n
      output.append(0x0a)
    case 0x72: // r
      output.append(0x0d)
    case 0x74: // t
      output.append(0x09)
    case 0x5c: // \
      output.append(0x5c)
    default:
      output.append(next)
    }
    idx += 2
  }

  return Data(output)
}

final class TmuxPassthroughUnwrapper {
  private enum State {
    case plain
    case sawEscape
    case dcs(buffer: [UInt8], sawEscape: Bool)
  }

  private static let escape: UInt8 = 0x1b
  private static let dcsStart: UInt8 = 0x50 // P
  private static let stringTerminator: UInt8 = 0x5c // \
  private static let tmuxPrefix: [UInt8] = Array("tmux;".utf8)

  private var state: State = .plain

  func process(_ data: Data) -> Data {
    guard !data.isEmpty else { return Data() }
    var output: [UInt8] = []
    output.reserveCapacity(data.count)
    for byte in data {
      _consume(byte: byte, output: &output)
    }
    return Data(output)
  }

  func flush() -> Data {
    var output: [UInt8] = []
    switch state {
    case .plain:
      break
    case .sawEscape:
      output.append(Self.escape)
    case .dcs(let buffer, let sawEscape):
      output.append(Self.escape)
      output.append(Self.dcsStart)
      output.append(contentsOf: buffer)
      if sawEscape {
        output.append(Self.escape)
      }
    }
    state = .plain
    return Data(output)
  }

  private func _consume(byte: UInt8, output: inout [UInt8]) {
    switch state {
    case .plain:
      if byte == Self.escape {
        state = .sawEscape
      } else {
        output.append(byte)
      }
    case .sawEscape:
      if byte == Self.dcsStart {
        state = .dcs(buffer: [], sawEscape: false)
      } else if byte == Self.escape {
        output.append(Self.escape)
        state = .sawEscape
      } else {
        output.append(Self.escape)
        output.append(byte)
        state = .plain
      }
    case .dcs(var buffer, let sawEscape):
      if sawEscape {
        if byte == Self.stringTerminator {
          _appendCompletedDCS(buffer, output: &output)
          state = .plain
        } else if byte == Self.escape {
          buffer.append(Self.escape)
          // ESC ESC encodes a literal ESC in DCS payload. Once consumed,
          // the next byte should be parsed as normal payload content.
          state = .dcs(buffer: buffer, sawEscape: false)
        } else {
          buffer.append(Self.escape)
          buffer.append(byte)
          state = .dcs(buffer: buffer, sawEscape: false)
        }
      } else if byte == Self.escape {
        state = .dcs(buffer: buffer, sawEscape: true)
      } else {
        buffer.append(byte)
        state = .dcs(buffer: buffer, sawEscape: false)
      }
    }
  }

  private func _appendCompletedDCS(_ payload: [UInt8], output: inout [UInt8]) {
    if let unwrapped = _unwrapTmuxPayload(payload) {
      output.append(contentsOf: unwrapped)
      return
    }

    output.append(Self.escape)
    output.append(Self.dcsStart)
    output.append(contentsOf: payload)
    output.append(Self.escape)
    output.append(Self.stringTerminator)
  }

  private func _unwrapTmuxPayload(_ payload: [UInt8]) -> [UInt8]? {
    guard payload.starts(with: Self.tmuxPrefix) else {
      return nil
    }

    var current = payload
    while current.starts(with: Self.tmuxPrefix) {
      current.removeFirst(Self.tmuxPrefix.count)
      current = _undoubleEscapes(current)

      // Nested passthrough can remain wrapped as:
      // ESC P tmux;... ESC \
      // Strip the DCS envelope only when the inner body is still tmux-prefixed.
      guard current.count >= 4 else {
        continue
      }
      guard
        current[0] == Self.escape,
        current[1] == Self.dcsStart,
        current[current.count - 2] == Self.escape,
        current[current.count - 1] == Self.stringTerminator
      else {
        continue
      }

      let nestedBody = Array(current[2..<(current.count - 2)])
      guard nestedBody.starts(with: Self.tmuxPrefix) else {
        continue
      }
      current = nestedBody
    }
    return current
  }

  private func _undoubleEscapes(_ payload: [UInt8]) -> [UInt8] {
    var output: [UInt8] = []
    output.reserveCapacity(payload.count)
    var idx = 0
    while idx < payload.count {
      let byte = payload[idx]
      if byte == Self.escape, idx + 1 < payload.count, payload[idx + 1] == Self.escape {
        output.append(Self.escape)
        idx += 2
        continue
      }
      output.append(byte)
      idx += 1
    }
    return output
  }
}

final class TmuxControlModeFramingStripper {
  private enum State {
    case plain
    case sawEscape
    case matchingPrefix(index: Int, captured: [UInt8])
  }

  private static let escape: UInt8 = 0x1b
  private static let dcs: UInt8 = 0x50 // P
  private static let stringTerminator: UInt8 = 0x5c // \
  private static let prefixTail: [UInt8] = Array("1000p".utf8)

  private var state: State = .plain
  private var framingDepth = 0

  func process(_ data: Data) -> Data {
    guard !data.isEmpty else { return Data() }
    var output: [UInt8] = []
    output.reserveCapacity(data.count)

    for byte in data {
      switch state {
      case .plain:
        if byte == Self.escape {
          state = .sawEscape
        } else {
          output.append(byte)
        }
      case .sawEscape:
        if byte == Self.dcs {
          state = .matchingPrefix(index: 0, captured: [Self.escape, Self.dcs])
        } else if byte == Self.stringTerminator {
          if framingDepth > 0 {
            framingDepth -= 1
          } else {
            output.append(Self.escape)
            output.append(Self.stringTerminator)
          }
          state = .plain
        } else if byte == Self.escape {
          output.append(Self.escape)
          state = .sawEscape
        } else {
          output.append(Self.escape)
          output.append(byte)
          state = .plain
        }
      case .matchingPrefix(var idx, var captured):
        if idx < Self.prefixTail.count, byte == Self.prefixTail[idx] {
          captured.append(byte)
          idx += 1
          if idx == Self.prefixTail.count {
            framingDepth += 1
            state = .plain
          } else {
            state = .matchingPrefix(index: idx, captured: captured)
          }
        } else {
          output.append(contentsOf: captured)
          if byte == Self.escape {
            state = .sawEscape
          } else {
            output.append(byte)
            state = .plain
          }
        }
      }
    }

    return Data(output)
  }

  func flush() -> Data {
    var output: [UInt8] = []
    switch state {
    case .plain:
      break
    case .sawEscape:
      output.append(Self.escape)
    case .matchingPrefix(_, let captured):
      output.append(contentsOf: captured)
    }
    state = .plain
    return Data(output)
  }
}

final class TmuxOSCSequenceFilter {
  private enum State {
    case plain
    case sawEscape
    case osc(payload: [UInt8], sawEscape: Bool)
  }

  private enum OSCTerminator {
    case bel
    case st
  }

  private static let escape: UInt8 = 0x1b
  private static let osc: UInt8 = 0x5d // ]
  private static let bell: UInt8 = 0x07
  private static let st: UInt8 = 0x5c // \
  private static let semicolon: UInt8 = 0x3b
  private static let osc7: UInt8 = 0x37 // 7

  private(set) var osc7ConsumedCount: Int = 0
  private(set) var malformedCount: Int = 0

  private var state: State = .plain

  func process(_ data: Data) -> Data {
    guard !data.isEmpty else { return Data() }
    var output: [UInt8] = []
    output.reserveCapacity(data.count)

    for byte in data {
      switch state {
      case .plain:
        if byte == Self.escape {
          state = .sawEscape
        } else {
          output.append(byte)
        }
      case .sawEscape:
        if byte == Self.osc {
          state = .osc(payload: [], sawEscape: false)
        } else if byte == Self.escape {
          output.append(Self.escape)
          state = .sawEscape
        } else {
          output.append(Self.escape)
          output.append(byte)
          state = .plain
        }
      case .osc(var payload, let sawEscape):
        if sawEscape {
          if byte == Self.st {
            _emitOSC(payload, terminator: .st, output: &output)
            state = .plain
          } else if byte == Self.escape {
            payload.append(Self.escape)
            state = .osc(payload: payload, sawEscape: true)
          } else {
            payload.append(Self.escape)
            payload.append(byte)
            state = .osc(payload: payload, sawEscape: false)
          }
        } else if byte == Self.bell {
          _emitOSC(payload, terminator: .bel, output: &output)
          state = .plain
        } else if byte == Self.escape {
          state = .osc(payload: payload, sawEscape: true)
        } else {
          payload.append(byte)
          state = .osc(payload: payload, sawEscape: false)
        }
      }
    }

    return Data(output)
  }

  func flush() -> Data {
    var output: [UInt8] = []
    switch state {
    case .plain:
      break
    case .sawEscape:
      output.append(Self.escape)
    case .osc(let payload, let sawEscape):
      malformedCount += 1
      output.append(Self.escape)
      output.append(Self.osc)
      output.append(contentsOf: payload)
      if sawEscape {
        output.append(Self.escape)
      }
    }
    state = .plain
    return Data(output)
  }

  private func _emitOSC(_ payload: [UInt8], terminator: OSCTerminator, output: inout [UInt8]) {
    if _isOSC7(payload) {
      osc7ConsumedCount += 1
      return
    }

    output.append(Self.escape)
    output.append(Self.osc)
    output.append(contentsOf: payload)
    switch terminator {
    case .bel:
      output.append(Self.bell)
    case .st:
      output.append(Self.escape)
      output.append(Self.st)
    }
  }

  private func _isOSC7(_ payload: [UInt8]) -> Bool {
    guard let first = payload.first, first == Self.osc7 else {
      return false
    }
    return payload.count == 1 || payload[1] == Self.semicolon
  }
}

func tmuxControlModeConsumeLines(
  buffer: inout Data,
  chunk: Data,
  framingStripper: TmuxControlModeFramingStripper? = nil
) -> [String] {
  let normalizedChunk = framingStripper?.process(chunk) ?? chunk
  if !normalizedChunk.isEmpty {
    buffer.append(normalizedChunk)
  }
  return tmuxControlModeDrainLines(buffer: &buffer, flush: false)
}

func tmuxControlModeFlushLines(
  buffer: inout Data,
  framingStripper: TmuxControlModeFramingStripper? = nil
) -> [String] {
  if let framingStripper {
    let pending = framingStripper.flush()
    if !pending.isEmpty {
      buffer.append(pending)
    }
  }
  return tmuxControlModeDrainLines(buffer: &buffer, flush: true)
}

private func tmuxControlModeDrainLines(buffer: inout Data, flush: Bool) -> [String] {
  guard !buffer.isEmpty else { return [] }

  var lines: [String] = []
  var lineStart = buffer.startIndex
  var cursor = lineStart

  while cursor < buffer.endIndex {
    let byte = buffer[cursor]
    guard byte == 0x0a || byte == 0x0d else {
      cursor = buffer.index(after: cursor)
      continue
    }

    let segment = buffer[lineStart..<cursor]
    if !segment.isEmpty {
      let raw = String(decoding: segment, as: UTF8.self)
      if !raw.isEmpty {
        lines.append(raw)
      }
    }

    cursor = buffer.index(after: cursor)
    while cursor < buffer.endIndex {
      let next = buffer[cursor]
      if next == 0x0a || next == 0x0d {
        cursor = buffer.index(after: cursor)
      } else {
        break
      }
    }
    lineStart = cursor
  }

  if flush {
    let pending = buffer[lineStart..<buffer.endIndex]
    if !pending.isEmpty {
      let raw = String(decoding: pending, as: UTF8.self)
      if !raw.isEmpty {
        lines.append(raw)
      }
    }
    buffer.removeAll(keepingCapacity: true)
    return lines
  }

  if lineStart > buffer.startIndex {
    buffer.removeSubrange(buffer.startIndex..<lineStart)
  }
  return lines
}

enum TmuxControlModeEvent: Equatable {
  case paneOutput(paneID: String, payload: Data)
  case error(String)
  case exit(String?)
  case control(String)
  case plain(String)
}

func tmuxControlModeParseEvent(line: String) -> TmuxControlModeEvent {
  if line.hasPrefix("%output ") {
    let components = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard components.count >= 3 else {
      return .control(line)
    }
    let paneID = String(components[1])
    let payload = tmuxControlModeDecodeValue(String(components[2]))
    return .paneOutput(paneID: paneID, payload: payload)
  }

  if line.hasPrefix("%extended-output ") {
    let payloadPrefixCount = "%extended-output ".count
    let remainder = String(line.dropFirst(payloadPrefixCount))
    if let separator = remainder.range(of: " : ") {
      let header = remainder[..<separator.lowerBound]
      let parts = header.split(separator: " ")
      guard let pane = parts.first else {
        return .control(line)
      }
      let payload = tmuxControlModeDecodeValue(String(remainder[separator.upperBound...]))
      return .paneOutput(paneID: String(pane), payload: payload)
    }

    let parts = remainder.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count >= 2 else {
      return .control(line)
    }

    let paneID = String(parts[0])
    let payloadSource: String
    if parts.count == 2 {
      let value = String(parts[1])
      payloadSource = Int(value) != nil ? "" : value
    } else {
      let marker = String(parts[1])
      if marker == ":" || Int(marker) != nil {
        payloadSource = String(parts[2])
      } else {
        payloadSource = "\(marker) \(parts[2])"
      }
    }
    let payload = tmuxControlModeDecodeValue(payloadSource)
    return .paneOutput(paneID: paneID, payload: payload)
  }

  if line.hasPrefix("%error") {
    let message = line.dropFirst("%error".count).trimmingCharacters(in: .whitespaces)
    return .error(message.isEmpty ? line : message)
  }

  if line.hasPrefix("%exit") {
    let reason = line.dropFirst("%exit".count).trimmingCharacters(in: .whitespaces)
    return .exit(reason.isEmpty ? nil : reason)
  }

  if line.hasPrefix("%") {
    return .control(line)
  }

  return .plain(line)
}

func tmuxControlModeSendKeysCommands(paneID: String, bytes: [UInt8], chunkSize: Int = 48) -> [String] {
  guard !paneID.isEmpty, !bytes.isEmpty else {
    return []
  }

  let safeChunkSize = max(1, min(chunkSize, 128))
  let quotedPane = tmuxShellQuote(paneID)
  var commands: [String] = []
  commands.reserveCapacity((bytes.count + safeChunkSize - 1) / safeChunkSize)

  var idx = 0
  while idx < bytes.count {
    let end = min(idx + safeChunkSize, bytes.count)
    let chunk = bytes[idx..<end]
    let payload = chunk.map { String(format: "%02x", Int($0)) }.joined(separator: " ")
    commands.append("send-keys -t \(quotedPane) -H \(payload)\n")
    idx = end
  }

  return commands
}

func tmuxCapturePaneCommand(paneTarget: String, lines: Int) -> String {
  let safeLines = max(1, lines)
  return "tmux capture-pane -p -t \(tmuxShellQuote(paneTarget)) -S -\(safeLines)"
}

private func tmuxWriteToFD(_ fd: Int32, data: Data) {
  guard !data.isEmpty else { return }
  data.withUnsafeBytes { rawBuffer in
    guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
    var offset = 0
    while offset < rawBuffer.count {
      let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
      if written <= 0 {
        break
      }
      offset += written
    }
  }
}

private final class TmuxStreamCaptureWriter: Writer {
  private var buffer = Data()
  private let lock = NSLock()

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: buffer, as: UTF8.self)
  }

  func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    let data = Data(buf)
    lock.lock()
    buffer.append(data)
    lock.unlock()
    return AnyPublisher.just(length).setFailureType(to: Error.self).eraseToAnyPublisher()
  }
}

private final class TmuxControlModeOutputBridge: Writer {
  private let targetPaneID: String
  private let stdoutFD: Int32
  private let stderrFD: Int32
  private let onControlReady: (() -> Void)?
  private var lineBuffer = Data()
  private var didSignalControlReady = false
  private let framingStripper = TmuxControlModeFramingStripper()
  private let passthroughUnwrapper = TmuxPassthroughUnwrapper()
  private let oscFilter = TmuxOSCSequenceFilter()

  init(targetPaneID: String, stdoutFD: Int32, stderrFD: Int32, onControlReady: (() -> Void)? = nil) {
    self.targetPaneID = targetPaneID
    self.stdoutFD = stdoutFD
    self.stderrFD = stderrFD
    self.onControlReady = onControlReady
  }

  func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    let lines = tmuxControlModeConsumeLines(
      buffer: &lineBuffer,
      chunk: Data(buf),
      framingStripper: framingStripper
    )
    for line in lines {
      _handleLine(line)
    }

    return AnyPublisher.just(length).setFailureType(to: Error.self).eraseToAnyPublisher()
  }

  private func _handleLine(_ line: String) {
    if line.hasPrefix("%") {
      _signalControlReadyIfNeeded()
    }
    switch tmuxControlModeParseEvent(line: line) {
    case .paneOutput(let paneID, let payload):
      guard paneID == targetPaneID else { return }
      let unwrapped = passthroughUnwrapper.process(payload)
      let filtered = oscFilter.process(unwrapped)
      _writeStdout(filtered)
    case .error(let message):
      _writeStderr("[tmux-pane-bridge] \(message)\r\n")
    case .exit(let reason):
      if let reason, !reason.isEmpty {
        _writeStderr("\r\n[tmux-pane-bridge] remote control session exited: \(reason)\r\n")
      } else {
        _writeStderr("\r\n[tmux-pane-bridge] remote control session exited.\r\n")
      }
    case .control:
      return
    case .plain(let text):
      _writeStderr(text + "\r\n")
    }
  }

  func flushPendingLine() {
    let pendingLines = tmuxControlModeFlushLines(
      buffer: &lineBuffer,
      framingStripper: framingStripper
    )
    for line in pendingLines {
      _handleLine(line)
    }
    _writeStdout(oscFilter.process(passthroughUnwrapper.flush()))
    _writeStdout(oscFilter.flush())
  }

  private func _writeStdout(_ data: Data) {
    _write(fd: stdoutFD, data: data)
  }

  private func _writeStderr(_ text: String) {
    _write(fd: stderrFD, data: Data(text.utf8))
  }

  private func _write(fd: Int32, data: Data) {
    tmuxWriteToFD(fd, data: data)
  }

  private func _signalControlReadyIfNeeded() {
    guard !didSignalControlReady else { return }
    didSignalControlReady = true
    onControlReady?()
  }
}

private final class TmuxControlModeCommandWriter: Writer {
  private let paneID: String
  private let downstream: Writer

  init(paneID: String, downstream: Writer) {
    self.paneID = paneID
    self.downstream = downstream
  }

  func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    let bytes = [UInt8](Data(buf))
    let commands = tmuxControlModeSendKeysCommands(paneID: paneID, bytes: bytes)
    guard !commands.isEmpty else {
      return AnyPublisher.just(length).setFailureType(to: Error.self).eraseToAnyPublisher()
    }

    let payload = Data(commands.joined().utf8)
    let data = payload.withUnsafeBytes { DispatchData(bytes: $0) }
    return downstream.write(data, max: data.count)
      .map { _ in length }
      .eraseToAnyPublisher()
  }
}

private final class TmuxControlModeInputBridge: WriterTo {
  private let input: DispatchInputStream
  private let paneID: String

  init(inputFD: Int32, paneID: String) {
    self.input = DispatchInputStream(stream: dup(inputFD))
    self.paneID = paneID
  }

  func writeTo(_ w: Writer) -> AnyPublisher<Int, Error> {
    let commandWriter = TmuxControlModeCommandWriter(paneID: paneID, downstream: w)
    return input.writeTo(commandWriter)
  }

  func close() {
    input.close()
  }
}

@objc final class TmuxPaneBridgeCommand: NSObject {
  private let bootstrapCaptureLines = 800
  private let mcp: MCPSession
  private let outstream: Int32
  private let instream: Int32
  private let errstream: Int32
  private let device: TermDevice
  private let currentRunLoop = RunLoop.current
  private var timer: Timer?

  private var stdout = OutputStream(file: thread_stdout)
  private var stderr = OutputStream(file: thread_stderr)
  private var exitCode: Int32 = 0
  private var connection: SSH.SSHClient?
  private var stream: SSH.Stream?
  private var inputBridge: TmuxControlModeInputBridge?
  private var outputBridge: TmuxControlModeOutputBridge?
  private var connectCancellable: AnyCancellable?
  private var writeCancellables: [AnyCancellable] = []
  private var didSendInitialRefresh = false
  private var lifecycleRequest: TmuxNotificationRequest?
  private var lifecycleAttemptID: String?
  private var didSendConnectedLifecycleEvent = false
  private var didSendTerminalLifecycleEvent = false

  init(mcp: MCPSession) {
    self.mcp = mcp
    self.outstream = fileno(thread_stdout)
    self.instream = fileno(thread_stdin)
    self.errstream = fileno(thread_stderr)
    self.device = tty()
    super.init()
  }

  func start(request: TmuxNotificationRequest, attemptID: String?) -> Int32 {
    mcp.registerSSHClient(self)
    let originalRawMode = device.rawMode
    defer {
      mcp.unregisterSSHClient(self)
      device.rawMode = originalRawMode
    }

    let cleanHost = request.hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanHost.isEmpty else {
      print(TmuxPaneBridgeError.missingHostAlias.localizedDescription, to: &stderr)
      return -1
    }

    let cleanPane = request.paneTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanPane.isEmpty else {
      print(TmuxPaneBridgeError.missingPaneTarget.localizedDescription, to: &stderr)
      return -1
    }

    let requestedSession = request.sessionName?.trimmingCharacters(in: .whitespacesAndNewlines)
    lifecycleRequest = TmuxNotificationRequest(
      hostAlias: cleanHost,
      sessionName: requestedSession?.isEmpty == true ? nil : requestedSession,
      paneTarget: cleanPane
    )
    let cleanAttemptID = attemptID?.trimmingCharacters(in: .whitespacesAndNewlines)
    lifecycleAttemptID = (cleanAttemptID?.isEmpty == false) ? cleanAttemptID : nil
    didSendConnectedLifecycleEvent = false
    didSendTerminalLifecycleEvent = false

    let inferredSession = cleanPane.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanSession = request.sessionName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? request.sessionName!.trimmingCharacters(in: .whitespacesAndNewlines)
      : (inferredSession ?? "")
    guard !cleanSession.isEmpty else {
      print(TmuxPaneBridgeError.missingSessionName.localizedDescription, to: &stderr)
      _emitLifecycleEvent(
        .failed,
        reason: TmuxPaneBridgeError.missingSessionName.localizedDescription,
        failureCode: .invalidRequest,
        terminal: true
      )
      return -1
    }

    lifecycleRequest = TmuxNotificationRequest(
      hostAlias: cleanHost,
      sessionName: cleanSession,
      paneTarget: cleanPane
    )
    _emitLifecycleEvent(.starting)

    let hostName: String
    let config: SSHClientConfig
    do {
      let commandHost = try SSHCommand.parse([cleanHost]).bkSSHHost()
      let host = try BKConfig().bkSSHHost(cleanHost, extending: commandHost)
      hostName = host.hostName ?? cleanHost
      config = try SSHClientConfigProvider.config(host: host, using: device)
    } catch {
      let reason = "Configuration error - \(error)"
      print(reason, to: &stderr)
      _emitLifecycleEvent(
        .failed,
        reason: reason,
        failureCode: _failureCode(for: error, fallbackReason: reason),
        terminal: true
      )
      return -1
    }

    let connect = SSHPool.dial(
      hostName,
      with: config,
      withControlMaster: .no,
      withProxy: { [weak self] command, sockIn, sockOut in
        self?.mcp.setActiveSession()
        BlinkSSH.executeProxyCommand(command: command, sockIn: sockIn, sockOut: sockOut)
      }
    )

    connectCancellable = connect
      .flatMap { [weak self] conn -> AnyPublisher<SSH.SSHClient, Error> in
        guard let self else {
          return .fail(error: TmuxPaneBridgeError.remoteCommandFailed("Bridge command was released unexpectedly."))
        }
        self.connection = conn

        if let banner = conn.issueBanner, !banner.isEmpty {
          print(banner, to: &self.stdout)
        }

        conn.handleSessionException = { [weak self] error in
          guard let self else { return }
          let reason = "SSH session exception: \(error)"
          print(reason, to: &self.stderr)
          self._emitLifecycleEvent(
            .failed,
            reason: reason,
            failureCode: self._failureCode(for: error, fallbackReason: reason),
            terminal: true
          )
          self.exitCode = -1
          self.kill()
        }

        return self._resolvePaneID(on: conn, paneTarget: cleanPane)
          .flatMap { [weak self] paneID -> AnyPublisher<SSH.SSHClient, Error> in
            guard let self else {
              return .fail(error: TmuxPaneBridgeError.remoteCommandFailed("Bridge command was released unexpectedly."))
            }
            return self._capturePaneBootstrap(on: conn, paneTarget: cleanPane)
              .flatMap { [weak self] _ -> AnyPublisher<SSH.SSHClient, Error> in
                guard let self else {
                  return .fail(error: TmuxPaneBridgeError.remoteCommandFailed("Bridge command was released unexpectedly."))
                }
                return self._startBridge(
                  on: conn,
                  sessionName: cleanSession,
                  paneTarget: cleanPane,
                  paneID: paneID
                )
              }
              .eraseToAnyPublisher()
          }
          .eraseToAnyPublisher()
      }
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self else { return }
          switch completion {
          case .failure(let error):
            let reason = "Error connecting tmux pane bridge. \(error)"
            print(reason, to: &self.stderr)
            self._emitLifecycleEvent(
              .failed,
              reason: reason,
              failureCode: self._failureCode(for: error, fallbackReason: reason),
              terminal: true
            )
            self.exitCode = -1
            self.kill()
          case .finished:
            // Keep run loop alive; stream callbacks handle normal shutdown.
            break
          }
        },
        receiveValue: { _ in }
      )

    awaitRunLoop()
    _cleanup()
    return exitCode
  }

  private func _resolvePaneID(on conn: SSH.SSHClient, paneTarget: String) -> AnyPublisher<String, Error> {
    let command = "tmux display-message -p -t \(tmuxShellQuote(paneTarget)) '#{pane_id}'"
    return _execCapture(on: conn, command: command)
      .tryMap { output in
        let paneID = output
          .components(separatedBy: .newlines)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .first(where: { !$0.isEmpty }) ?? ""
        guard paneID.hasPrefix("%") else {
          throw TmuxPaneBridgeError.invalidPaneID(paneID)
        }
        return paneID
      }
      .eraseToAnyPublisher()
  }

  private func _startBridge(
    on conn: SSH.SSHClient,
    sessionName: String,
    paneTarget: String,
    paneID: String
  ) -> AnyPublisher<SSH.SSHClient, Error> {
    let remoteCommand = "tmux -CC attach-session -t \(tmuxShellQuote(sessionName)) -f ignore-size,active-pane \\; select-pane -t \(tmuxShellQuote(paneTarget))"
    let pty = SSH.SSHClient.PTY(rows: Int32(max(1, device.rows)), columns: Int32(max(1, device.cols)))
    var environment: [String: String] = [:]
    if let term = getenv("TERM") {
      environment["TERM"] = String(cString: term)
    }

    return conn.requestExec(command: remoteCommand, withPTY: pty, withEnvVars: environment)
      .tryMap { [weak self] stream in
        guard let self else {
          throw TmuxPaneBridgeError.remoteCommandFailed("Bridge command was released unexpectedly.")
        }

        let outputBridge = TmuxControlModeOutputBridge(
          targetPaneID: paneID,
          stdoutFD: self.outstream,
          stderrFD: self.errstream,
          onControlReady: { [weak self] in
            self?._emitLifecycleEvent(.connected)
            self?._sendInitialRefreshIfNeeded()
          }
        )
        let inputBridge = TmuxControlModeInputBridge(inputFD: self.instream, paneID: paneID)
        self.outputBridge = outputBridge
        self.inputBridge = inputBridge
        self.didSendInitialRefresh = false
        self.stream = stream

        stream.handleFailure = { [weak self] error in
          guard let self else { return }
          outputBridge.flushPendingLine()
          let reason = "Tmux pane bridge failed. \(error)"
          print(reason, to: &self.stderr)
          self._emitLifecycleEvent(
            .failed,
            reason: reason,
            failureCode: self._failureCode(for: error, fallbackReason: reason),
            terminal: true
          )
          self.exitCode = -1
          self.kill()
        }
        stream.handleCompletion = { [weak self, weak stream] in
          guard let self else { return }
          outputBridge.flushPendingLine()
          let status = stream?.exitStatus ?? 0
          if status != 0 {
            self.exitCode = -1
            let reason = "Tmux pane bridge exited with status \(status) for \(sessionName) \(paneTarget)."
            print(reason, to: &self.stderr)
            self._emitLifecycleEvent(
              .failed,
              reason: reason,
              failureCode: .exitedNonZero,
              exitStatus: status,
              terminal: true
            )
          } else if self.didSendConnectedLifecycleEvent {
            self._emitLifecycleEvent(
              .disconnected,
              failureCode: .disconnected,
              exitStatus: status,
              terminal: true
            )
          } else {
            let reason = "Tmux pane bridge exited before control channel became ready."
            self._emitLifecycleEvent(
              .failed,
              reason: reason,
              failureCode: .bootstrapDisconnected,
              exitStatus: status,
              terminal: true
            )
          }
          self.kill()
        }
        stream.connect(stdout: outputBridge, stdin: inputBridge, stderr: outputBridge)
        self.device.rawMode = true
        return conn
      }
      .eraseToAnyPublisher()
  }

  private func _capturePaneBootstrap(
    on conn: SSH.SSHClient,
    paneTarget: String
  ) -> AnyPublisher<Void, Error> {
    let command = tmuxCapturePaneCommand(paneTarget: paneTarget, lines: bootstrapCaptureLines)
    return _execCapture(on: conn, command: command)
      .map { [weak self] output in
        guard let self else { return }
        guard !output.isEmpty else { return }
        tmuxWriteToFD(self.outstream, data: Data(output.utf8))
        if !output.hasSuffix("\n") {
          tmuxWriteToFD(self.outstream, data: Data("\r\n".utf8))
        }
      }
      .eraseToAnyPublisher()
  }

  private func _execCapture(on conn: SSH.SSHClient, command: String) -> AnyPublisher<String, Error> {
    conn.requestExec(command: command)
      .flatMap { stream -> AnyPublisher<String, Error> in
        let writer = TmuxStreamCaptureWriter()
        return Future<String, Error> { promise in
          stream.handleFailure = { error in
            promise(.failure(error))
          }
          stream.handleCompletion = {
            if stream.exitStatus != 0 {
              let output = writer.text.trimmingCharacters(in: .whitespacesAndNewlines)
              promise(.failure(TmuxPaneBridgeError.remoteCommandFailed(output)))
              return
            }
            promise(.success(writer.text))
          }
          stream.connect(stdout: writer, stderr: writer)
        }
        .eraseToAnyPublisher()
      }
      .eraseToAnyPublisher()
  }

  private func _sendControlCommand(_ command: String) {
    guard let stream else { return }
    let payload = Data((command + "\n").utf8)
    let data = payload.withUnsafeBytes { DispatchData(bytes: $0) }
    var cancellable: AnyCancellable?
    cancellable = stream.write(data, max: data.count)
      .sink(
        receiveCompletion: { [weak self] _ in
          if let cancellable {
            self?.writeCancellables.removeAll(where: { $0 === cancellable })
          }
        },
        receiveValue: { _ in }
      )
    if let cancellable {
      writeCancellables.append(cancellable)
    }
  }

  @objc func sigwinch() {
    _sendControlCommand("refresh-client -C \(Int(device.cols))x\(Int(device.rows))")
  }

  private func _sendInitialRefreshIfNeeded() {
    guard !didSendInitialRefresh else { return }
    guard stream != nil else { return }
    didSendInitialRefresh = true
    _sendControlCommand("refresh-client -C \(Int(device.cols))x\(Int(device.rows))")
  }

  @objc func kill() {
    connectCancellable = nil
    awake()
  }

  private func _cleanup() {
    inputBridge?.close()
    outputBridge?.flushPendingLine()
    stream?.cancel()
    stream = nil
    inputBridge = nil
    outputBridge = nil
    writeCancellables = []
    connectCancellable = nil
    connection = nil
    didSendInitialRefresh = false
    lifecycleRequest = nil
    lifecycleAttemptID = nil
    didSendConnectedLifecycleEvent = false
    didSendTerminalLifecycleEvent = false
  }

  private func _failureCode(for error: Error, fallbackReason: String?) -> TmuxPaneBridgeFailureCode {
    if let bridgeError = error as? TmuxPaneBridgeError {
      switch bridgeError {
      case .missingHostAlias, .missingPaneTarget, .missingSessionName, .invalidPaneID:
        return .invalidRequest
      case .remoteCommandFailed(let output):
        return _failureCode(from: output)
      }
    }
    return _failureCode(from: "\(fallbackReason ?? "") \(error.localizedDescription)")
  }

  private func _failureCode(from message: String?) -> TmuxPaneBridgeFailureCode {
    let normalized = message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard !normalized.isEmpty else {
      return .unknown
    }

    if normalized.contains("missing host alias")
      || normalized.contains("missing pane target")
      || normalized.contains("missing session name")
      || normalized.contains("invalid tmux pane bridge token")
      || normalized.contains("invalid or expired tmux pane bridge request id")
      || normalized.contains("failed to resolve pane id")
    {
      return .invalidRequest
    }

    if normalized.contains("configuration error") {
      return .configurationError
    }

    if normalized.contains("rejected credentials")
      || normalized.contains("permission denied")
      || normalized.contains("authentication failed")
      || normalized.contains("host key verification failed")
      || normalized.contains("publickey")
    {
      return .authRejected
    }

    if normalized.contains("invalid or insecure")
      || normalized.contains("invalid url")
      || normalized.contains("unsupported url")
      || normalized.contains("unsupported endpoint")
    {
      return .endpointInvalid
    }

    if normalized.contains("host not found")
      || normalized.contains("name or service not known")
      || normalized.contains("no such host")
      || normalized.contains("could not resolve hostname")
    {
      return .hostNotFound
    }

    if normalized.contains("timed out")
      || normalized.contains("network is unreachable")
      || normalized.contains("connection reset")
      || normalized.contains("connection refused")
      || normalized.contains("software caused connection abort")
    {
      return .transport
    }

    if normalized.contains("exited with status") {
      return .exitedNonZero
    }

    return .commandFailed
  }

  private func _emitLifecycleEvent(
    _ event: TmuxPaneBridgeLifecycleEvent,
    reason: String? = nil,
    failureCode: TmuxPaneBridgeFailureCode? = nil,
    attemptID: String? = nil,
    exitStatus: Int32? = nil,
    terminal: Bool = false
  ) {
    guard let request = lifecycleRequest else {
      return
    }
    if event == .connected {
      guard !didSendConnectedLifecycleEvent else {
        return
      }
      didSendConnectedLifecycleEvent = true
    }
    if terminal {
      guard !didSendTerminalLifecycleEvent else {
        return
      }
      didSendTerminalLifecycleEvent = true
    }

    let cleanReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanFailureCode = failureCode?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resolvedAttemptID = (attemptID ?? lifecycleAttemptID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    DispatchQueue.main.async {
      var userInfo: [String: String] = [
        TmuxPaneBridgeLifecycleUserInfoKey.event: event.rawValue,
        TmuxPaneBridgeLifecycleUserInfoKey.hostAlias: request.hostAlias,
        TmuxPaneBridgeLifecycleUserInfoKey.sessionName: request.sessionName ?? "",
        TmuxPaneBridgeLifecycleUserInfoKey.paneTarget: request.paneTarget,
        TmuxPaneBridgeLifecycleUserInfoKey.reason: cleanReason ?? ""
      ]
      if !cleanFailureCode.isEmpty {
        userInfo[TmuxPaneBridgeLifecycleUserInfoKey.failureCode] = cleanFailureCode
      }
      if !resolvedAttemptID.isEmpty {
        userInfo[TmuxPaneBridgeLifecycleUserInfoKey.attemptID] = resolvedAttemptID
      }
      if let exitStatus {
        userInfo[TmuxPaneBridgeLifecycleUserInfoKey.exitStatus] = String(exitStatus)
      }
      NotificationCenter.default.post(
        name: .BLKTmuxPaneBridgeLifecycle,
        object: nil,
        userInfo: userInfo
      )
    }
  }

  private func awaitRunLoop() {
    let timer = Timer(timeInterval: TimeInterval(INT_MAX), repeats: true) { _ in }
    self.timer = timer
    currentRunLoop.add(timer, forMode: .default)
    CFRunLoopRun()
  }

  private func awake() {
    let cfRunLoop = currentRunLoop.getCFRunLoop()
    timer?.invalidate()
    CFRunLoopStop(cfRunLoop)
  }
}

@objc public class BlinkSSH: NSObject {
  private typealias SSHConnection = AnyPublisher<SSH.SSHClient, Error>
  
  var outstream: Int32
  var instream: Int32
  var errstream: Int32
  let device: TermDevice
  var isTTY: Bool
  var stdout = OutputStream(file: thread_stdout)
  var stderr = OutputStream(file: thread_stderr)
  private var _mcp: MCPSession;

  var exitCode: Int32 = 0
  var connectionCancellable: AnyCancellable?
  let currentRunLoop = RunLoop.current
  var command: SSHCommand?
  var stream: SSH.Stream?
  var connection: SSH.SSHClient?
  var forwardTunnels: [PortForwardInfo] = []
  var remoteTunnels: [PortForwardInfo] = []
  var proxyThread: Thread?
  var socks: [OptionalBindAddressInfo] = []
  var timer: Timer?

  var outStream: DispatchOutputStream?
  var inStream: DispatchInputStream?
  var errStream: DispatchOutputStream?
  
  init(mcp: MCPSession) {
    _mcp = mcp;
    // Owed by ios_system, so beware to dup before using.
    self.outstream = fileno(thread_stdout)
    self.instream = fileno(thread_stdin)
    self.errstream = fileno(thread_stderr)
    self.device = tty()
    self.isTTY = ios_isatty(self.instream) != 0
    super.init()
  }

  @objc public func start(_ argc: Int32, argv: [String]) -> Int32 {
    _mcp.registerSSHClient(self)
    let originalRawMode = device.rawMode
    defer {
      _mcp.unregisterSSHClient(self)
      device.rawMode = originalRawMode
    }

    let cmd: SSHCommand
    do {
      cmd = try SSHCommand.parse(Array(argv[1...]))
      command = cmd
    } catch {
      let message = SSHCommand.message(for: error)
      print("\(message)", to: &stderr)
      return -1
    }
    
    let host: BKSSHHost
    let hostName: String
    let config: SSHClientConfig
    do {
      let commandHost = try cmd.bkSSHHost()
      host = try BKConfig().bkSSHHost(cmd.hostAlias, extending: commandHost)
      hostName = host.hostName ?? cmd.hostAlias
      config = try SSHClientConfigProvider.config(host: host, using: device)
    } catch {
      print("Configuration error - \(error)", to: &stderr)
      return -1
    }


    // The HostName is the defined by "host", or the one from the command.

    if cmd.printConfiguration {
      print("Configuration for \(cmd.hostAlias) as \(hostName)", to: &stdout)
      print("\(config.description)", to: &stdout)
      return 0
    }

    let connect: SSHConnection
    if let control = cmd.control {
      guard
        let conn = SSHPool.connection(for: hostName, with: config)
      else {
        print("No connection for \(cmd.hostAlias) to control", to: &stderr)
        return -1
      }
      switch control {
      // case .stop:
      //   SSHPool.deregister(runningCommand: cmd, on: conn)
      //   return 0
      case .forward:
        connect = .just(conn)
        break
      case .cancel:
        SSHPool.deregister(allTunnelsForConnection: conn)
        return 0
//      case .exit:
//        // This one would require to have a handle to the Session as well.
//        SSHPool.deregister(allFor: connection)
      default:
        print("Unknown control parameter \(control)", to: &stderr)
        return -1
      }
    } else {
      // Disable CM on -W, this way we attach it to the main connection only
      let useControlMaster = (cmd.stdioHostAndPort != nil) ? .no : (host.controlMaster ?? .no)
      
      connect = SSHPool.dial(
        hostName,
        with: config,
        withControlMaster: useControlMaster,
        withProxy: { [weak self] in
          guard let self = self
          else {
            return
          }
          self._mcp.setActiveSession()
          Self.executeProxyCommand(command: $0, sockIn: $1, sockOut: $2)
        })
    }
    
    var environment: [String: String] = .init(minimumCapacity: host.sendEnv?.count ?? 0)
    
    host.sendEnv?.forEach({ env in
      // SKIP nil values
      if let value = getenv(env) {
        environment[env] = String(cString: value)
      }
    })

    connectionCancellable = connect.flatMap { conn -> SSHConnection in
      self.connection = conn

      if let banner = conn.issueBanner,
         !banner.isEmpty {
        print(banner, to: &self.stdout)
      }
      
      conn.handleSessionException = { error in
        print("Exception received \(error)", to: &self.stderr)
        self.kill()
      }
      
      if cmd.startsSession {
        if let addr = conn.clientAddressIP() {
          print("Connected to \(addr)", to: &self.stdout)
        }

        // AgentForwardingPrompt
        var sendAgent = host.forwardAgent ?? false
        // Add forwarded keys after the connection is established, to make sure they won't be used
        // during login.
        // TODO: We do not need to change the sendAgent flag here, but ssh_config was not adding it.
        // Let configs change and do later.
        if let bkHost = BKHosts.withHost(cmd.hostAlias),
           let agent = conn.agent {
          if self.loadAgentForwardKeys(bkHost: bkHost, agent: agent) {
            sendAgent = true
          }
        }

        return self.startInteractiveSessions(conn,
                                             command: host.remoteCommand,
                                             requestTTY: host.requestTty ?? .auto,
                                             withEnvVars: environment,
                                             sendAgent: sendAgent)
      }
      return .just(conn)
    }
    .flatMap { self.startStdioTunnel($0, command: cmd) }
    // TODO In order to support ExitOnForwardFailure, we will have to become a bit smarter here.
    // ExitOnForwardFailure only closes if the bind for -L/-R fails
    // TODO Note, we are not merging localForward on host and cmd yet. There can also be -o.
    .flatMap { self.startForwardTunnels( (host.localForward ?? []), on: $0, exitOnFailure: host.exitOnForwardFailure ?? false) }
    .flatMap { self.startRemoteTunnels( (host.remoteForward ?? []), on: $0, exitOnFailure: host.exitOnForwardFailure ?? false) }
    .flatMap { self.startDynamicForwarding( (host.dynamicForward ?? []), on: $0, exitOnFailure: host.exitOnForwardFailure ?? false) }
    .sink(receiveCompletion: { completion in
      switch completion {
      case .failure(let error):
        print("Error connecting to \(cmd.hostAlias). \(error)", to: &self.stderr)
        self.exitCode = -1
        self.kill()
      default:
        // Connection OK
        break
      }
    }, receiveValue: { conn in
      if !cmd.blocks {
        self.kill()
      }
    })

    awaitRunLoop()

    stream?.cancel()
    outStream?.close()
    inStream?.close()
    errStream?.close()
    stream = nil
    outStream = nil
    inStream = nil
    errStream = nil
    
    if let conn = self.connection, cmd.blocks {
      if cmd.startsSession { SSHPool.deregister(shellOn: conn) }
      forwardTunnels.forEach { SSHPool.deregister(localForward:  $0, on: conn) }
      remoteTunnels.forEach  { SSHPool.deregister(remoteForward: $0, on: conn) }
      socks.forEach { SSHPool.deregister(socksBindAddress: $0, on: conn) }
    }
    
    connectionCancellable = nil
    self.connection = nil
    return exitCode
  }

  static func executeProxyCommand(command: String, sockIn: Int32, sockOut: Int32) {
    /* Prepare /dev/null socket for the stderr redirection */
    let devnull = open("/dev/null", O_WRONLY);
    if devnull == -1 {
      ios_exit(1)
    }

    /* redirect in and out to stdin, stdout */
    ios_dup2(sockIn,  STDIN_FILENO)
    ios_dup2(sockOut, STDOUT_FILENO)
    ios_dup2(devnull, STDERR_FILENO)

    ios_system(command);
  }

  private func startInteractiveSessions(_ conn: SSH.SSHClient,
                                        command: String?,
                                        requestTTY: TTYBool,
                                        withEnvVars envVars: [String:String],
                                        sendAgent: Bool) -> SSHConnection {
    let rows = Int32(self.device.rows)
    let cols = Int32(self.device.cols)
    var pty: SSH.SSHClient.PTY? = nil
    if (requestTTY != .no) && 
       ( 
         (requestTTY == .force) ||
         // always request a TTY when standard input is a TTY
         ((requestTTY == .yes) && self.isTTY) ||
         // request a TTY when opening a login session
         ((requestTTY == .auto) && command == nil)
       ) {       
      pty = SSH.SSHClient.PTY(rows: rows, columns: cols)
      self.device.rawMode = true
    }

    // TERM is explicitely added
    var envVars = envVars
    envVars["TERM"] = String(cString: getenv("TERM"))

    let session: AnyPublisher<SSH.Stream, Error>
    if let command = command {
      session = conn.requestExec(command: command, withPTY: pty,
                                 withEnvVars: envVars,
                                 withAgentForwarding: sendAgent)      
    } else {
      session = conn.requestInteractiveShell(withPTY: pty,
                                             withEnvVars: envVars,
                                             withAgentForwarding: sendAgent)
    }

    return session.tryMap { s in
      let outs = DispatchOutputStream(stream: dup(self.outstream))
      let ins = DispatchInputStream(stream: dup(self.instream))
      let errs = DispatchOutputStream(stream: dup(self.errstream))

      s.handleCompletion = { [weak self] in
        // Once finished, exit.
        self?.kill()
        return
      }
      s.handleFailure = { [weak self] error in
        guard let self = self else {
          return
        }
        self.exitCode = -1
        print("Interactive Shell error. \(error)", to: &self.stderr)
        self.kill()
        return
      }

      s.connect(stdout: outs, stdin: ins, stderr: errs)
      self.outStream = outs
      self.inStream = ins
      self.errStream = errs
      SSHPool.register(shellOn: conn)
      self.stream = s
      return conn
    }.eraseToAnyPublisher()
  }

  private func startStdioTunnel(_ conn: SSH.SSHClient, command: SSHCommand) -> SSHConnection {
    guard let tunnel = command.stdioHostAndPort else {
      return .just(conn)
    }

    return conn.requestForward(to: tunnel.bindAddress, port: Int32(tunnel.port),
                          // Just informative.
                          from: "stdio", localPort: 22)
      .tryMap { s in
        SSHPool.register(stdioStream: s, runningCommand: command, on: conn)
        let outStream = DispatchOutputStream(stream: dup(self.outstream))
        let inStream = DispatchInputStream(stream: dup(self.instream))
        s.connect(stdout: outStream, stdin: inStream)

        s.handleCompletion = { [weak self] in
          print("Stdio Tunnel completed")
          SSHPool.deregister(allTunnelsForConnection: conn)
          self?.kill()
          //SSHPool.deregister(runningCommand: command, on: conn)
        }
        s.handleFailure = { [weak self] error in
          print("Stdio Tunnel completed")
          SSHPool.deregister(allTunnelsForConnection: conn)
          self?.kill()
          //SSHPool.deregister(runningCommand: command, on: conn)
        }
        
        return conn
      }.eraseToAnyPublisher()
  }

  private func startForwardTunnels(_ tunnels: [PortForwardInfo], 
                                   on conn: SSH.SSHClient,
                                   exitOnFailure: Bool) -> SSHConnection {
    let tunnels = tunnels.filter { !SSHPool.contains(localForward: $0, on: conn) }
    if tunnels.isEmpty {
      return .just(conn)
    }
    
    return tunnels.publisher
      .flatMap(maxPublishers: .max(1)) { tunnel -> AnyPublisher<Void, Error> in
        let lis = SSHPortForwardListener(on: tunnel.localPort, toDestination: tunnel.bindAddress, on: tunnel.remotePort, using: conn)
        
        // Await for Listener to bind and be ready.
        return lis.ready().map {
          SSHPool.register(lis, portForwardInfo: tunnel, on: conn)
          self.forwardTunnels.append(tunnel)
        }
        // In case of failure, exit report and continue.
        .tryCatch { error -> AnyPublisher<Void, Error> in
          if exitOnFailure {
            throw error
          }
          
          print("\(error)", to: &self.stderr)
          return .just(Void())
        } 
        .eraseToAnyPublisher()
      }
      .last()
      .map { conn }
      .eraseToAnyPublisher()
  }

  private func startRemoteTunnels(_ tunnels: [PortForwardInfo],
                                  on conn: SSH.SSHClient, 
                                  exitOnFailure: Bool) -> SSHConnection {
    let tunnels = tunnels.filter { !SSHPool.contains(remoteForward: $0, on: conn) }
    if tunnels.isEmpty {
      return .just(conn)
    }

    return tunnels.publisher
      .flatMap(maxPublishers: .max(1)) { tunnel -> AnyPublisher<Void, Error> in
        let client: SSHPortForwardClient
        client = SSHPortForwardClient(forward: tunnel.bindAddress,
                                      onPort: tunnel.remotePort,
                                      toRemotePort: tunnel.localPort,
                                      using: conn)
        
        
        // Await for Client to be setup and ready.
        return client.ready().map {
          self.remoteTunnels.append(tunnel)
          // Mark to dashboard
          SSHPool.register(client, portForwardInfo: tunnel, on: conn)
        }
        .tryCatch { error -> AnyPublisher<Void, Error> in
          if exitOnFailure {
            throw error
          }
          print("\(error)", to: &self.stderr)
          return .just(Void())
        }
        .eraseToAnyPublisher()
      }
      .last()
      .map {
        conn
      }
      .eraseToAnyPublisher()
  }

  private func startDynamicForwarding(_ bindAddresses: [OptionalBindAddressInfo], on conn: SSH.SSHClient, exitOnFailure: Bool) -> SSHConnection {
    let bindAddresses = bindAddresses.filter { !SSHPool.contains(socksBindAddress: $0, on: conn) }
    if bindAddresses.isEmpty {
      return .just(conn)
    }

    return bindAddresses.publisher
      .flatMap(maxPublishers: .max(1)) { bindAddress -> AnyPublisher<Void, Error> in
        do {
          let server = try SOCKSServer(bindAddress.port, proxy: conn)
          SSHPool.register(server, bindAddressInfo: bindAddress, on: conn)
          self.socks.append(bindAddress)
        } catch {
          return .fail(error: error)
        }
        return .just(Void())
      }
      .last()
      .map { conn }
      .eraseToAnyPublisher()    
  }

  private func loadAgentForwardKeys(bkHost: BKHosts, agent: SSHAgent) -> Bool {
    var constraints: [SSHAgentConstraint]? = nil
    let agentForwardPrompt = BKAgentForward(UInt32(bkHost.agentForwardPrompt?.intValue ?? 0))

    if agentForwardPrompt == BKAgentForwardConfirm {
      constraints = [SSHAgentUserPrompt()]
    } else if agentForwardPrompt == BKAgentForwardYes {
      constraints = []
    } else {
      return false
    }

    if constraints != nil {
      let _allIdentities = BKPubKey.all()
      for keyName in bkHost.agentForwardKeys {
        if let signer = _allIdentities.signerWithID(keyName) {
          agent.loadKey(signer, aka: keyName, constraints: constraints)
        }
      }
    }

    return true
  }

  @objc public func sigwinch() {
    var c: AnyCancellable?
    c = stream?
      .resizePty(rows: Int32(device.rows), columns: Int32(device.cols))
      .sink(receiveCompletion: { completion in
        if case .failure(let error) = completion {
          print(error)
        }
        c?.cancel()
      }, receiveValue: {})
  }

  @objc public func kill() {
    // Cancelling here makes sure the flows are cancelled.
    // Trying to do it at the runloop has the issue that flows may continue running.
    print("Kill received")
    connectionCancellable = nil
    
    awake()
  }

  func awaitRunLoop() {
    let timer = Timer(timeInterval: TimeInterval(INT_MAX), repeats: true) { _ in
      print("timer")
    }
    self.timer = timer
    self.currentRunLoop.add(timer, forMode: .default)
    CFRunLoopRun()
  }

  func awake() {
    let cfRunLoop = self.currentRunLoop.getCFRunLoop()
    self.timer?.invalidate()
    CFRunLoopStop(cfRunLoop)
  }

  deinit {
    print("OUT")
  }
}
