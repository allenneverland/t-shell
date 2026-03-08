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
