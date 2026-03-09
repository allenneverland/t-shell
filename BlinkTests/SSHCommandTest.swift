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
  func testNamespacedProfilePaths() {
    let profile = TmuxControlPlaneProfile.namespacedV1
    XCTAssertEqual(profile.sessionsPath, "/v1/tmux/sessions")
    XCTAssertEqual(profile.paneOutputPath(target: "work:1.2", lines: 500), "/v1/tmux/panes/work:1.2/output?lines=500")
    XCTAssertEqual(profile.paneInputPath(target: "work:1.2"), "/v1/tmux/panes/work:1.2/input")
    XCTAssertEqual(profile.paneEscapePath(target: "work:1.2"), "/v1/tmux/panes/work:1.2/escape")
  }

  func testFlatProfilePaths() {
    let profile = TmuxControlPlaneProfile.flat
    XCTAssertEqual(profile.sessionsPath, "/sessions")
    XCTAssertEqual(profile.paneOutputPath(target: "work:1.2", lines: 500), "/panes/work:1.2/output?lines=500")
    XCTAssertEqual(profile.paneInputPath(target: "work:1.2"), "/panes/work:1.2/input")
    XCTAssertEqual(profile.paneEscapePath(target: "work:1.2"), "/panes/work:1.2/escape")
  }

  func testPaneTargetPathEncodingEscapesSlashAndSpace() {
    XCTAssertEqual(tmuxControlEncodePathComponent("dev path/1.2"), "dev%20path%2F1.2")
    XCTAssertEqual(tmuxControlEncodePathComponent("session:1.2"), "session:1.2")
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
    XCTAssertTrue(script.contains("\"$HOME/.local/bin/tmuxd\" hooks verify --json"))
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

  func testParseTmuxBellHookVerifyJSON() {
    let json = """
    {"persistent_config_ok":true,"runtime_server_present":false,"runtime_hook_ok":false,"overall_ok":true,"reasons":[],"warnings":["runtime tmux server is not running"]}
    """
    XCTAssertTrue(TmuxSSHOnboardingService.parseTmuxBellHookVerifyJSONForTesting(json))
  }

  func testManagedTmuxdLocalPortCandidates() {
    XCTAssertEqual(TmuxSSHOnboardingService.tmuxdLocalPortCandidatesForTesting(), [8787, 8790, 8791])
  }

  func testLocalHealthScriptIncludesPythonFallbackAndDynamicPort() {
    let script = TmuxSSHOnboardingService.localHealthzScriptForTesting(port: 8790)
    XCTAssertTrue(script.contains("127.0.0.1:$port/v1/healthz"))
    XCTAssertTrue(script.contains("command -v python3"))
    XCTAssertTrue(script.contains("command -v python"))
    XCTAssertTrue(script.contains("tmuxd process exited before health check succeeded on 127.0.0.1:$port."))
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
