//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2023 Blink Mobile Shell Project
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


import XCTest

@testable import Blink

final class SSHCommandTest: XCTestCase {
  func testSSHCommandParams() throws {
    var cmd: SSHCommand
    XCTAssertThrowsError(try SSHCommand.parse(["-t", "-T", "user@host"]))
    XCTAssertThrowsError(try SSHCommand.parse(["-o", "ForwardAgent", "yes", "user@host"]))
    cmd = try SSHCommand.parse(["-L", "11:forward:00", "-o", "ForwardAgent=yes", "user@host","-vv", "-p", "2222", "-L", "forward", "--", "cat", "-v", "hello"])
    XCTAssertTrue(cmd.customPort == 2222)
    XCTAssertTrue(cmd.command == ["cat", "-v", "hello"])
    XCTAssertTrue(cmd.localForward.count == 2)
    // Resolved at the SSH Config level
    XCTAssertTrue(cmd.agentForward == false)
    XCTAssertTrue(cmd.verbosity == 2)
  }
}

final class TmuxAttachCommandTests: XCTestCase {
  func testTokenRoundTripPreservesPayload() throws {
    let request = TmuxNotificationRequest(hostAlias: "allen", sessionName: "trade", paneTarget: "trade:1.1")
    let token = try XCTUnwrap(request.tmuxAttachToken)
    let decoded = try XCTUnwrap(TmuxNotificationRequest.fromTmuxAttachToken(token))
    XCTAssertEqual(decoded, request)
  }

  func testBuildInvocationUsesSessionFallbackFromPaneTarget() throws {
    let request = TmuxNotificationRequest(hostAlias: "allen", sessionName: nil, paneTarget: "market:1.1")
    let invocation = try TmuxAttachInvocation.build(from: request)

    XCTAssertEqual(invocation.hostAlias, "allen")
    XCTAssertEqual(invocation.sshArgv, [
      "ssh",
      "allen",
      "-t",
      "tmux attach-session -t 'market' \\; select-pane -t 'market:1.1'"
    ])
    XCTAssertFalse(invocation.remoteCommand.contains("\"'market'\""))
  }

  func testBuildInvocationEscapesSingleQuotesForRemoteShell() throws {
    let request = TmuxNotificationRequest(hostAlias: "allen", sessionName: "o'clock", paneTarget: "o'clock:1.1")
    let invocation = try TmuxAttachInvocation.build(from: request)

    XCTAssertTrue(invocation.remoteCommand.contains("'o'\"'\"'clock'"))
  }

  func testBuildInvocationRejectsMissingSessionAndUnqualifiedPane() {
    let request = TmuxNotificationRequest(hostAlias: "allen", sessionName: nil, paneTarget: "pane-without-session")
    XCTAssertThrowsError(try TmuxAttachInvocation.build(from: request)) { error in
      XCTAssertEqual(error as? TmuxAttachInvocationError, .missingSessionName("pane-without-session"))
    }
  }

  func testTokenArgumentParsingSupportsTwoForms() {
    XCTAssertEqual(tmuxAttachTokenArgument(from: ["--token", "abc123"]), "abc123")
    XCTAssertEqual(tmuxAttachTokenArgument(from: ["--token=abc123"]), "abc123")
    XCTAssertNil(tmuxAttachTokenArgument(from: ["--token"]))
    XCTAssertNil(tmuxAttachTokenArgument(from: ["--other", "value"]))
  }

}

final class TmuxControlPlaneRouteTests: XCTestCase {
  func testNamespacedPathsOnly() {
    XCTAssertEqual(tmuxControlSessionsPathForTesting(), "/v1/tmux/sessions")
    XCTAssertEqual(tmuxControlPaneOutputPathForTesting(target: "work:1.2", lines: 500), "/v1/tmux/panes/work:1.2/output?lines=500")
    XCTAssertEqual(tmuxControlPaneInputPathForTesting(target: "work:1.2"), "/v1/tmux/panes/work:1.2/input")
    XCTAssertEqual(tmuxControlPaneEscapePathForTesting(target: "work:1.2"), "/v1/tmux/panes/work:1.2/escape")
  }

  func testPaneTargetPathEncodingEscapesSlashAndSpace() {
    XCTAssertEqual(tmuxControlEncodePathComponent("dev path/1.2"), "dev%20path%2F1.2")
    XCTAssertEqual(tmuxControlEncodePathComponent("session:1.2"), "session:1.2")
  }

  func testSessionsErrorCodeMapsToRuntimeUpgradeGuidance() {
    let payload = """
    {"code":"incompatible_tmux_runtime","error":"tmux runtime missing required pane inbox capabilities","missing_capabilities":["pane_activity"]}
    """
    let message = tmuxControlSessionsErrorMessageForTesting(
      statusCode: 422,
      hostAlias: "allen",
      payload: payload
    )
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("upgrade tmux") ?? false)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("pane_activity") ?? false)
  }

  func testSessionsLegacy500ErrorStillMapsToRuntimeUpgradeGuidance() {
    let payload = """
    {"error":"tmux list-panes did not return a valid pane_activity value"}
    """
    let message = tmuxControlSessionsErrorMessageForTesting(
      statusCode: 500,
      hostAlias: "allen",
      payload: payload
    )
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("upgrade tmux") ?? false)
  }
}

final class TmuxPickerDisplayTests: XCTestCase {
  func testSessionTitleShowsAttachedIndicatorWhenEnabled() {
    let title = tmuxSessionPickerTitle(name: "work", attached: true, showAttachedIndicator: true)
    XCTAssertEqual(title, "work • attached")
  }

  func testSessionTitleHidesAttachedIndicatorWhenDisabled() {
    let title = tmuxSessionPickerTitle(name: "work", attached: true, showAttachedIndicator: false)
    XCTAssertEqual(title, "work")
  }

  func testPaneTitleShowsStarWhenEnabled() {
    let title = tmuxPanePickerTitle(
      windowName: "editor",
      paneIndex: 2,
      currentPath: "/tmp/project",
      active: true,
      showActiveStar: true
    )
    XCTAssertEqual(title, "★ editor • pane 2 • project")
  }

  func testPaneTitleHidesStarWhenDisabled() {
    let title = tmuxPanePickerTitle(
      windowName: "editor",
      paneIndex: 2,
      currentPath: "/tmp/project",
      active: true,
      showActiveStar: false
    )
    XCTAssertEqual(title, "editor • pane 2 • project")
  }

  func testInboxPreviewPrefersPreviewText() {
    let preview = tmuxPaneInboxPreviewText(
      previewText: "build succeeded",
      currentCommand: "make test",
      fallbackPath: "/tmp/project"
    )
    XCTAssertEqual(preview, "build succeeded")
  }

  func testInboxPreviewFallsBackToCurrentCommand() {
    let preview = tmuxPaneInboxPreviewText(
      previewText: "   ",
      currentCommand: "python server.py",
      fallbackPath: "/tmp/project"
    )
    XCTAssertEqual(preview, "python server.py")
  }
}

final class TmuxPaneInboxSortingTests: XCTestCase {
  private func _item(
    hostAlias: String,
    sessionName: String,
    windowIndex: Int,
    paneIndex: Int,
    paneTarget: String,
    paneActivity: Int64
  ) -> TmuxPaneInboxItem {
    TmuxPaneInboxItem(
      hostAlias: hostAlias,
      hostName: hostAlias,
      sessionName: sessionName,
      sessionAttached: false,
      windowIndex: windowIndex,
      windowName: "window \(windowIndex)",
      paneIndex: paneIndex,
      paneTarget: paneTarget,
      currentPath: "/tmp",
      active: false,
      paneActivity: paneActivity,
      currentCommand: "bash",
      previewText: "preview",
      hasUnreadNotification: false
    )
  }

  func testSortPanesOrdersByMostRecentActivityFirst() {
    let older = _item(
      hostAlias: "beta",
      sessionName: "build",
      windowIndex: 1,
      paneIndex: 0,
      paneTarget: "build:1.0",
      paneActivity: 1000
    )
    let newer = _item(
      hostAlias: "alpha",
      sessionName: "ops",
      windowIndex: 3,
      paneIndex: 2,
      paneTarget: "ops:3.2",
      paneActivity: 2000
    )

    let sorted = tmuxPaneInboxSortPanesByRecentActivity([older, newer])
    XCTAssertEqual(sorted.map(\.paneTarget), ["ops:3.2", "build:1.0"])
  }

  func testSortPanesUsesDeterministicTieBreakers() {
    let items = [
      _item(hostAlias: "zeta", sessionName: "work", windowIndex: 2, paneIndex: 0, paneTarget: "work:2.0", paneActivity: 3000),
      _item(hostAlias: "alpha", sessionName: "zeta", windowIndex: 1, paneIndex: 0, paneTarget: "zeta:1.0", paneActivity: 3000),
      _item(hostAlias: "alpha", sessionName: "alpha", windowIndex: 2, paneIndex: 0, paneTarget: "alpha:2.0", paneActivity: 3000),
      _item(hostAlias: "alpha", sessionName: "alpha", windowIndex: 1, paneIndex: 1, paneTarget: "alpha:1.1", paneActivity: 3000),
      _item(hostAlias: "alpha", sessionName: "alpha", windowIndex: 1, paneIndex: 0, paneTarget: "alpha:1.0", paneActivity: 3000)
    ]

    let sortedTargets = tmuxPaneInboxSortPanesByRecentActivity(items).map(\.paneTarget)
    XCTAssertEqual(sortedTargets, [
      "alpha:1.0",
      "alpha:1.1",
      "alpha:2.0",
      "zeta:1.0",
      "work:2.0"
    ])
  }
}

final class TmuxPaneBridgeCodecTests: XCTestCase {
  private let esc: UInt8 = 0x1b

  func testDecodeControlModeOutputOctalEscapes() {
    let decoded = tmuxControlModeDecodeValue("hello\\040world\\012")
    XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "hello world\n")
  }

  func testDecodeControlModeOutputKeepsBackslash() {
    let decoded = tmuxControlModeDecodeValue("path\\\\to\\\\bin")
    XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "path\\to\\bin")
  }

  func testSendKeysCommandsChunkInput() {
    let commands = tmuxControlModeSendKeysCommands(
      paneID: "%17",
      bytes: Array("abcdef".utf8),
      chunkSize: 3
    )
    XCTAssertEqual(commands, [
      "send-keys -t '%17' -H 61 62 63\n",
      "send-keys -t '%17' -H 64 65 66\n"
    ])
  }

  func testParseControlModeOutputEvent() {
    let event = tmuxControlModeParseEvent(line: "%output %17 hello\\040world")
    XCTAssertEqual(event, .paneOutput(paneID: "%17", payload: Data("hello world".utf8)))
  }

  func testParseControlModeErrorEvent() {
    let event = tmuxControlModeParseEvent(line: "%error can't find pane")
    XCTAssertEqual(event, .error("can't find pane"))
  }

  func testParseControlModePlainEvent() {
    let event = tmuxControlModeParseEvent(line: "open terminal failed: not a terminal")
    XCTAssertEqual(event, .plain("open terminal failed: not a terminal"))
  }

  func testParseExtendedOutputEventWithAgeAndColon() {
    let event = tmuxControlModeParseEvent(line: "%extended-output %17 0 : hello\\040world")
    XCTAssertEqual(event, .paneOutput(paneID: "%17", payload: Data("hello world".utf8)))
  }

  func testParseExtendedOutputEventWithoutColonDelimiter() {
    let event = tmuxControlModeParseEvent(line: "%extended-output %17 0 hello\\040world")
    XCTAssertEqual(event, .paneOutput(paneID: "%17", payload: Data("hello world".utf8)))
  }

  func testConsumeLinesSupportsCRDelimitedControlModeFrames() {
    var buffer = Data()
    let chunk = Data("%output %17 hello\\040world\r%output %17 next\\012\r".utf8)
    let lines = tmuxControlModeConsumeLines(buffer: &buffer, chunk: chunk)
    XCTAssertEqual(lines, ["%output %17 hello\\040world", "%output %17 next\\012"])
    XCTAssertTrue(buffer.isEmpty)
  }

  func testConsumeLinesStripsDCSFramingFromCCMode() {
    var buffer = Data()
    let framingStripper = TmuxControlModeFramingStripper()
    let prefix = "\u{1B}P1000p"
    let suffix = "\u{1B}\\"
    let chunk = Data("\(prefix)%begin 1 2 0\r%exit\r\(suffix)".utf8)
    let lines = tmuxControlModeConsumeLines(buffer: &buffer, chunk: chunk, framingStripper: framingStripper)
    XCTAssertEqual(lines, ["%begin 1 2 0", "%exit"])
    let flushed = tmuxControlModeFlushLines(buffer: &buffer, framingStripper: framingStripper)
    XCTAssertTrue(flushed.isEmpty)
  }

  func testFramingStripperPreservesNonCCDCSPayload() {
    let stripper = TmuxControlModeFramingStripper()
    let payload = Data([esc, 0x50]) + Data("tmux;raw".utf8) + Data([esc, 0x5c])
    let output = stripper.process(payload) + stripper.flush()
    XCTAssertEqual(output, payload)
  }

  func testCapturePaneCommandQuotesTargetAndClampsLines() {
    let command = tmuxCapturePaneCommand(paneTarget: "o'clock:1.2", lines: 0)
    XCTAssertEqual(command, "tmux capture-pane -p -t 'o'\"'\"'clock:1.2' -S -1")
  }

  func testPassthroughUnwrapperUnwrapsSingleLayerTmuxDCS() {
    let inner = Data([esc, 0x5d]) + Data("7;file://host/home/allen".utf8) + Data([0x07])
    let wrapped = _wrapAsTmuxPassthrough(inner, layers: 1)
    let unwrapper = TmuxPassthroughUnwrapper()
    XCTAssertEqual(unwrapper.process(wrapped), inner)
  }

  func testPassthroughUnwrapperUnwrapsNestedTmuxDCS() {
    let inner = Data([esc, 0x5d]) + Data("7;file://host/work".utf8) + Data([0x07])
    let wrapped = _wrapAsTmuxPassthrough(inner, layers: 2)
    let unwrapper = TmuxPassthroughUnwrapper()
    XCTAssertEqual(unwrapper.process(wrapped), inner)
  }

  func testPassthroughUnwrapperHandlesChunkBoundaries() {
    let inner = Data([esc, 0x5d]) + Data("7;file://host/chunk".utf8) + Data([0x07])
    let wrapped = _wrapAsTmuxPassthrough(inner, layers: 1)
    let split = wrapped.count / 2
    let unwrapper = TmuxPassthroughUnwrapper()
    let part1 = unwrapper.process(wrapped.prefix(split))
    let part2 = unwrapper.process(wrapped.dropFirst(split))
    XCTAssertEqual(part1 + part2 + unwrapper.flush(), inner)
  }

  func testPassthroughUnwrapperKeepsNonTmuxDCS() {
    let nonTmuxDCS = Data([esc, 0x50]) + Data("plain;dcs".utf8) + Data([esc, 0x5c])
    let unwrapper = TmuxPassthroughUnwrapper()
    XCTAssertEqual(unwrapper.process(nonTmuxDCS), nonTmuxDCS)
  }

  func testOSCFilterConsumesOSC7BELSequence() {
    let filter = TmuxOSCSequenceFilter()
    let input = Data("left".utf8)
      + Data([esc, 0x5d])
      + Data("7;file://host/home/allen".utf8)
      + Data([0x07])
      + Data("right".utf8)
    let output = filter.process(input) + filter.flush()
    XCTAssertEqual(output, Data("leftright".utf8))
    XCTAssertEqual(filter.osc7ConsumedCount, 1)
  }

  func testOSCFilterConsumesOSC7STAcrossChunks() {
    let filter = TmuxOSCSequenceFilter()
    let part1 = Data("a".utf8) + Data([esc, 0x5d]) + Data("7;file://host/work".utf8) + Data([esc])
    let part2 = Data([0x5c]) + Data("b".utf8)
    let output = filter.process(part1) + filter.process(part2) + filter.flush()
    XCTAssertEqual(output, Data("ab".utf8))
    XCTAssertEqual(filter.osc7ConsumedCount, 1)
  }

  func testOSCFilterKeepsNonOSC7Sequence() {
    let filter = TmuxOSCSequenceFilter()
    let osc8 = Data([esc, 0x5d]) + Data("8;id=1;https://example.com".utf8) + Data([0x07])
    let output = filter.process(osc8) + filter.flush()
    XCTAssertEqual(output, osc8)
    XCTAssertEqual(filter.osc7ConsumedCount, 0)
  }

  private func _wrapAsTmuxPassthrough(_ payload: Data, layers: Int) -> Data {
    guard layers > 0 else { return payload }
    var current = payload
    for _ in 0..<layers {
      current = Data([esc, 0x50])
        + Data("tmux;".utf8)
        + _doubleEscapes(current)
        + Data([esc, 0x5c])
    }
    return current
  }

  private func _doubleEscapes(_ payload: Data) -> Data {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(payload.count * 2)
    for byte in payload {
      bytes.append(byte)
      if byte == esc {
        bytes.append(byte)
      }
    }
    return Data(bytes)
  }
}

final class TmuxNotificationPayloadResolverTests: XCTestCase {
  func testResolvesLegacyCamelCaseFields() {
    let userInfo: [AnyHashable: Any] = [
      "hostId": "dev-host",
      "sessionId": "work",
      "paneId": "work:1.2"
    ]

    let request = TmuxNotificationPayloadResolver.resolve(userInfo)
    XCTAssertEqual(
      request,
      TmuxNotificationRequest(hostAlias: "dev-host", sessionName: "work", paneTarget: "work:1.2")
    )
  }

  func testResolvesLegacySnakeCaseFields() {
    let userInfo: [AnyHashable: Any] = [
      "host_id": "prod-host",
      "session_id": "ops",
      "pane_id": "ops:0.0"
    ]

    let request = TmuxNotificationPayloadResolver.resolve(userInfo)
    XCTAssertEqual(
      request,
      TmuxNotificationRequest(hostAlias: "prod-host", sessionName: "ops", paneTarget: "ops:0.0")
    )
  }

  func testResolvesDeviceAndPaneTargetFields() {
    let userInfo: [AnyHashable: Any] = [
      "deviceId": "ios-device-1",
      "paneTarget": "dev:2.1"
    ]

    let request = TmuxNotificationPayloadResolver.resolve(userInfo) { deviceID in
      deviceID == "ios-device-1" ? "lookup-host" : nil
    }
    XCTAssertEqual(
      request,
      TmuxNotificationRequest(hostAlias: "lookup-host", sessionName: "dev", paneTarget: "dev:2.1")
    )
  }

  func testResolvesSnakeDeviceAndPaneTargetWithSessionName() {
    let userInfo: [AnyHashable: Any] = [
      "device_id": "ios-device-2",
      "pane_target": "abc:3.4",
      "session_name": "explicit-session"
    ]

    let request = TmuxNotificationPayloadResolver.resolve(userInfo) { deviceID in
      deviceID == "ios-device-2" ? "lookup-host-2" : nil
    }
    XCTAssertEqual(
      request,
      TmuxNotificationRequest(hostAlias: "lookup-host-2", sessionName: "explicit-session", paneTarget: "abc:3.4")
    )
  }

  func testDirectHostFieldWinsOverDeviceLookup() {
    let userInfo: [AnyHashable: Any] = [
      "hostId": "direct-host",
      "deviceId": "ios-device-3",
      "paneTarget": "dev:9.9"
    ]

    let request = TmuxNotificationPayloadResolver.resolve(userInfo) { _ in
      "lookup-host-3"
    }
    XCTAssertEqual(
      request,
      TmuxNotificationRequest(hostAlias: "direct-host", sessionName: "dev", paneTarget: "dev:9.9")
    )
  }

  func testMissingPaneReturnsNil() {
    let userInfo: [AnyHashable: Any] = [
      "hostId": "dev-host",
      "sessionId": "work"
    ]
    XCTAssertNil(TmuxNotificationPayloadResolver.resolve(userInfo))
  }

  func testDeviceLookupFailureReturnsNil() {
    let userInfo: [AnyHashable: Any] = [
      "deviceId": "unknown-device",
      "paneTarget": "dev:0.1"
    ]
    XCTAssertNil(TmuxNotificationPayloadResolver.resolve(userInfo) { _ in nil })
  }
}

final class ShellRuntimeBootstrapTests: XCTestCase {
  override class func setUp() {
    super.setUp()
    AppDelegate.prepareShellRuntimeSynchronously()
  }

  func testShellRuntimeRegistersSSHCommands() {
    let commands = Set(AppDelegate.availableShellCommands())
    XCTAssertTrue(commands.contains("ssh"))
    XCTAssertTrue(commands.contains("scp"))
    XCTAssertTrue(commands.contains("sftp"))
    XCTAssertTrue(commands.contains("tmux-pane-bridge"))
  }

  func testShellRuntimePreparationIsIdempotent() {
    AppDelegate.prepareShellRuntimeSynchronously()
    let commands = Set(AppDelegate.availableShellCommands())
    XCTAssertTrue(commands.contains("ssh"))
  }
}

final class TmuxSSHOnboardingServiceAPNSNormalizationTests: XCTestCase {
  func testNormalizeAPNSKeyBase64AcceptsPEM() {
    let pem = """
-----BEGIN PRIVATE KEY-----
abc123
-----END PRIVATE KEY-----
"""
    let expected = pem.data(using: .utf8)?.base64EncodedString()
    XCTAssertEqual(TmuxSSHOnboardingService.normalizeAPNSKeyBase64(pem), expected)
  }

  func testNormalizeAPNSKeyBase64AcceptsBase64WithLineBreaks() {
    let input = "YWJj\nMTIz\r\n"
    XCTAssertEqual(TmuxSSHOnboardingService.normalizeAPNSKeyBase64(input), "YWJjMTIz")
  }

  func testNormalizeAPNSKeyBase64RejectsInvalidInput() {
    XCTAssertNil(TmuxSSHOnboardingService.normalizeAPNSKeyBase64("not-a-valid-base64"))
    XCTAssertNil(TmuxSSHOnboardingService.normalizeAPNSKeyBase64("   "))
  }
}

final class TmuxSSHOnboardingServiceTailscaleDiagnosticsTests: XCTestCase {
  func testTailscaleVersionGateRequires152OrNewer() {
    XCTAssertFalse(TmuxSSHOnboardingService.tailscaleVersionMeetsMinimum("1.51.9"))
    XCTAssertTrue(TmuxSSHOnboardingService.tailscaleVersionMeetsMinimum("1.52.0"))
    XCTAssertTrue(TmuxSSHOnboardingService.tailscaleVersionMeetsMinimum("tailscale v1.54.1-tabcdef"))
  }

  func testClassifyTailscaleServeFailureOperatorPermission() {
    let output = "Error: permission denied: node is managed by --operator=admin"
    let message = TmuxSSHOnboardingService.classifyTailscaleServeFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("operator") ?? false)
  }

  func testClassifyTailscaleServeFailureCertificateConsent() {
    let output = "HTTPS certificate is not enabled yet, visit admin console to enable certs"
    let message = TmuxSSHOnboardingService.classifyTailscaleServeFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("certificate") ?? false)
  }

  func testClassifyTailscaleServeFailureInvalidArgumentFormat() {
    let output = "Error: invalid argument format\ntry `tailscale serve --help` for usage info"
    let message = TmuxSSHOnboardingService.classifyTailscaleServeFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("syntax") ?? false)
  }

  func testClassifyTailscaleServeFailureForegroundListenerConflict() {
    let output = "sending serve config: updating config: foreground listener already exists for port 443"
    let message = TmuxSSHOnboardingService.classifyTailscaleServeFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("8787/8443/9443") ?? false)
  }

  func testClassifyTmuxdStartupFailurePortConflict() {
    let output = "listen tcp 127.0.0.1:8787: bind: address already in use"
    let message = TmuxSSHOnboardingService.classifyTmuxdStartupFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("8787/8790/8791") ?? false)
  }

  func testTailscaleServeScriptUsesNonInteractiveFlags() {
    let commands = TmuxSSHOnboardingService.tailscaleServeConfigScriptForTesting()
      .split(separator: "\n")
      .map(String.init)
    XCTAssertEqual(commands.count, 3)
    XCTAssertTrue(commands.allSatisfy { $0.contains("tailscale serve --yes --bg --https=") })
    XCTAssertTrue(commands.allSatisfy { $0.contains("--set-path=/") })
    XCTAssertTrue(commands.allSatisfy { $0.contains("http://127.0.0.1:8787") })
    XCTAssertTrue(commands.contains(where: { $0.contains("--https=8787") }))
    XCTAssertTrue(commands.contains(where: { $0.contains("--https=8443") }))
    XCTAssertTrue(commands.contains(where: { $0.contains("--https=9443") }))
    XCTAssertFalse(commands.contains(where: { $0.contains("--https=8790") }))
    XCTAssertFalse(commands.contains(where: { $0.contains("--https=443 ") }))
  }

  func testTmuxBellHookInstallScriptUsesManagedTmuxdBinary() {
    let script = TmuxSSHOnboardingService.tmuxBellHookInstallScriptForTesting()
    XCTAssertTrue(script.contains("\"$HOME/.local/bin/tmuxd\" hooks install"))
  }

  func testTmuxBellHookVerifyScriptChecksNotifyBellHook() {
    let script = TmuxSSHOnboardingService.tmuxBellHookVerifyScriptForTesting()
    XCTAssertTrue(script.contains("\"$HOME/.local/bin/tmuxd\" hooks verify --json --strict --probe-runtime"))
  }

  func testClassifyTmuxBellHookFailurePermissionDeniedMentionsTmuxConf() {
    let output = "Remote command failed with exit status 1.\nstderr:\npermission denied: /home/dev/.tmux.conf"
    let message = TmuxSSHOnboardingService.classifyTmuxBellHookFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains(".tmux.conf") ?? false)
  }

  func testClassifyTmuxBellHookFailureForEmptyRuntimeAlertBellHook() {
    let output = "Remote command failed with exit status 1.\nstdout:\nalert-bell"
    let message = TmuxSSHOnboardingService.classifyTmuxBellHookFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("runtime") ?? false)
  }

  func testClassifyTmuxBellHookFailureForSetHookSyntaxError() {
    let output = "Remote command failed with exit status 1.\nstderr:\ntmuxd fatal error: internal error: `tmux set-hook` failed: syntax error"
    let message = TmuxSSHOnboardingService.classifyTmuxBellHookFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("syntax") ?? false)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("tmuxd") ?? false)
  }

  func testClassifyTmuxBellHookFailureForMissingRunHookCapability() {
    let output = "Remote command failed with exit status 1.\nstderr:\nunknown command: run-hook"
    let message = TmuxSSHOnboardingService.classifyTmuxBellHookFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("upgrade tmux") ?? false)
  }

  func testClassifyTmuxBellHookFailureForRawBellProbeMessage() {
    let output = "tmux pane raw BEL probe failed (`printf '\\a'` did not trigger alert-bell): runtime raw BEL probe did not trigger `alert-bell` hook"
    let message = TmuxSSHOnboardingService.classifyTmuxBellHookFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("detached probe pane") ?? false)
    XCTAssertFalse(message?.localizedCaseInsensitiveContains("~/.tmux.conf is writable") ?? true)
  }

  func testClassifySelfTestFailureBadDeviceTokenIsNonRetryable() {
    let classified = TmuxSSHOnboardingService.classifySelfTestFailureForTesting(
      statusRaw: "bad_device_token",
      attempted: 1,
      delivered: 0,
      failed: 1,
      detail: "APNs rejected token"
    )
    XCTAssertNotNil(classified)
    XCTAssertFalse(classified?.retryable ?? true)
    XCTAssertTrue(classified?.message.localizedCaseInsensitiveContains("rejected") ?? false)
  }

  func testClassifySelfTestFailureAttemptedZeroIsNonRetryable() {
    let classified = TmuxSSHOnboardingService.classifySelfTestFailureForTesting(
      statusRaw: "dispatch_failed",
      attempted: 0,
      delivered: 0,
      failed: 0,
      detail: "no recipients"
    )
    XCTAssertNotNil(classified)
    XCTAssertFalse(classified?.retryable ?? true)
    XCTAssertTrue(classified?.message.localizedCaseInsensitiveContains("no active recipients") ?? false)
  }

  func testParseTmuxBellHookVerifyJSON() {
    let json = """
    {"persistent_config_ok":true,"runtime_server_present":true,"runtime_hook_ok":true,"runtime_options_ok":true,"runtime_probe_performed":true,"runtime_probe_hook_ok":true,"runtime_probe_raw_bel_ok":true,"runtime_probe_reason_codes":[],"overall_ok":true,"reasons":[],"warnings":[]}
    """
    XCTAssertTrue(TmuxSSHOnboardingService.parseTmuxBellHookVerifyJSONForTesting(json))
  }

  func testTmuxBellHookVerifyFailureMessageForUnsupportedTmuxVersion() {
    let json = """
    {"persistent_config_ok":true,"runtime_server_present":true,"runtime_hook_ok":true,"runtime_options_ok":true,"runtime_probe_performed":false,"runtime_probe_hook_ok":false,"runtime_probe_raw_bel_ok":false,"runtime_probe_compatible":false,"minimum_tmux_version":"3.1.0","detected_tmux_version":"tmux 2.9","required_capabilities":["run-hook"],"missing_capabilities":["run-hook"],"runtime_probe_reason_codes":["runtime_probe_tmux_version_unsupported","runtime_probe_missing_run_hook"],"overall_ok":false,"reasons":["tmux 2.9 is too old"],"warnings":[]}
    """
    let message = TmuxSSHOnboardingService.tmuxBellHookVerificationFailureMessageForTesting(json)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("incompatible") ?? false)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("upgrade tmux") ?? false)
  }

  func testClassifyTmuxBellHookFailureForRuntimeServerNotRunning() {
    let output = "runtime tmux server is not running; start tmux and retry onboarding."
    let message = TmuxSSHOnboardingService.classifyTmuxBellHookFailureMessage(output)
    XCTAssertNotNil(message)
    XCTAssertTrue(message?.localizedCaseInsensitiveContains("active tmux server") ?? false)
  }

  func testManagedTmuxdLocalPortCandidates() {
    XCTAssertEqual(TmuxSSHOnboardingService.tmuxdLocalPortCandidatesForTesting(), [8787, 8790, 8791])
  }

  func testLocalHealthScriptIncludesPythonFallbackAndDynamicHost() {
    let script = TmuxSSHOnboardingService.localHealthzScriptForTesting(port: 8790, host: "::1")
    XCTAssertTrue(script.contains("host='::1'"))
    XCTAssertTrue(script.contains("health_url=\"http://$url_host:$port/v1/healthz\""))
    XCTAssertTrue(script.contains("url_host=\"[$url_host]\""))
    XCTAssertTrue(script.contains("command -v python3"))
    XCTAssertTrue(script.contains("command -v python"))
    XCTAssertTrue(script.contains("tmuxd process exited before health check succeeded on $host:$port."))
  }

  func testStartTmuxdScriptUsesExplicitBindAddrAndPortFlags() {
    let script = TmuxSSHOnboardingService.startTmuxdScriptForTesting(port: 8791, bindAddr: "0.0.0.0")
    XCTAssertTrue(script.contains("bind_addr='0.0.0.0'"))
    XCTAssertTrue(script.contains("--bind-addr \"$bind_addr\" --port \"$port\""))
    XCTAssertTrue(script.contains("config_file=\"${TMUXD_CONFIG_FILE:-$HOME/.config/tmuxd/config.toml}\""))
  }

  func testResolveExistingTmuxdRuntimeScriptUsesEnvAndConfigFallback() {
    let script = TmuxSSHOnboardingService.resolveExistingTmuxdRuntimeScriptForTesting()
    XCTAssertTrue(script.contains("bind_addr=\"${TMUXD_BIND_ADDR:-}\""))
    XCTAssertTrue(script.contains("port=\"${TMUXD_PORT:-}\""))
    XCTAssertTrue(script.contains("config_file=\"${TMUXD_CONFIG_FILE:-$HOME/.config/tmuxd/config.toml}\""))
    XCTAssertTrue(script.contains("printf 'bind_addr=%s\\n' \"$bind_addr\""))
    XCTAssertTrue(script.contains("printf 'port=%s\\n' \"$port\""))
  }

  func testParseResolvedTmuxdRuntimeParsesValidOutput() {
    let raw = """
    bind_addr=0.0.0.0
    port=8791
    """
    let parsed = TmuxSSHOnboardingService.parseResolvedTmuxdRuntimeForTesting(raw)
    XCTAssertEqual(parsed?.bindAddr, "0.0.0.0")
    XCTAssertEqual(parsed?.port, 8791)
  }

  func testParseResolvedTmuxdRuntimeRejectsInvalidPort() {
    let raw = """
    bind_addr=127.0.0.1
    port=abc
    """
    XCTAssertNil(TmuxSSHOnboardingService.parseResolvedTmuxdRuntimeForTesting(raw))
  }

  func testLocalHealthHostNormalizationForWildcardBindAddr() {
    XCTAssertEqual(TmuxSSHOnboardingService.localHealthHostForBindAddressForTesting("0.0.0.0"), "127.0.0.1")
    XCTAssertEqual(TmuxSSHOnboardingService.localHealthHostForBindAddressForTesting("::"), "127.0.0.1")
    XCTAssertEqual(TmuxSSHOnboardingService.localHealthHostForBindAddressForTesting("[::1]"), "::1")
    XCTAssertEqual(TmuxSSHOnboardingService.localHealthHostForBindAddressForTesting("10.0.0.15"), "10.0.0.15")
  }

  func testPreferredServeRoutePrefersManagedFallbackPorts() {
    let status = """
    https://host.tailnet.ts.net:8790 (tailnet only)
    |-- / proxy http://127.0.0.1:8787
    https://host.tailnet.ts.net:8443 (tailnet only)
    |-- / proxy http://127.0.0.1:8787
    """
    let route = TmuxSSHOnboardingService.preferredTailscaleHTTPSRouteForTesting(statusOutput: status)
    XCTAssertEqual(route, "https://host.tailnet.ts.net:8443")
  }

  func testPreferredServeRouteAcceptsTrailingSlashProxyTarget() {
    let status = """
    https://host.tailnet.ts.net:8787 (tailnet only)
    |-- / proxy http://127.0.0.1:8787/
    """
    let route = TmuxSSHOnboardingService.preferredTailscaleHTTPSRouteForTesting(statusOutput: status)
    XCTAssertEqual(route, "https://host.tailnet.ts.net:8787")
  }

  func testPreferredServeRouteSupportsCustomProxyTarget() {
    let status = """
    https://host.tailnet.ts.net:8787 (tailnet only)
    |-- / proxy http://127.0.0.1:8787
    https://host.tailnet.ts.net:8443 (tailnet only)
    |-- / proxy http://127.0.0.1:8790
    """
    let route = TmuxSSHOnboardingService.preferredTailscaleHTTPSRouteForTesting(
      statusOutput: status,
      target: "http://127.0.0.1:8790"
    )
    XCTAssertEqual(route, "https://host.tailnet.ts.net:8443")
  }

  func testFormatExecFailureIncludesBothStdoutAndStderr() {
    let message = TmuxSSHOnboardingService.formatExecFailureForTesting(
      exitStatus: 1,
      stdout: "serve status: no handler configured",
      stderr: "permission denied",
      command: "tailscale serve --yes --bg --https=8787 --set-path=/ http://127.0.0.1:8787"
    )
    XCTAssertTrue(message.contains("stderr:"))
    XCTAssertTrue(message.contains("stdout:"))
    XCTAssertTrue(message.contains("serve status: no handler configured"))
    XCTAssertTrue(message.contains("permission denied"))
  }
}

final class SecurityScopedFileReaderTests: XCTestCase {
  func testReadUTF8TextTrimsWhitespaceAndNewlines() throws {
    let url = try _temporaryFile(data: " \nmy-key\n ".data(using: .utf8)!)
    defer { _removeTemporaryFile(url) }

    XCTAssertEqual(try SecurityScopedFileReader.readUTF8Text(from: url), "my-key")
  }

  func testReadUTF8TextRejectsInvalidUTF8() throws {
    let url = try _temporaryFile(data: Data([0xFF, 0xFE, 0xFD]))
    defer { _removeTemporaryFile(url) }

    XCTAssertThrowsError(try SecurityScopedFileReader.readUTF8Text(from: url)) { error in
      guard case SecurityScopedFileReadError.invalidUTF8 = error else {
        return XCTFail("Expected invalidUTF8, got \(error)")
      }
    }
  }

  func testReadUTF8TextRejectsEmptyContent() throws {
    let url = try _temporaryFile(data: " \n\t ".data(using: .utf8)!)
    defer { _removeTemporaryFile(url) }

    XCTAssertThrowsError(try SecurityScopedFileReader.readUTF8Text(from: url)) { error in
      guard case SecurityScopedFileReadError.emptyContent = error else {
        return XCTFail("Expected emptyContent, got \(error)")
      }
    }
  }

  private func _temporaryFile(data: Data) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("blink-security-scoped-\(UUID().uuidString)")
    try data.write(to: url, options: .atomic)
    return url
  }

  private func _removeTemporaryFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}
