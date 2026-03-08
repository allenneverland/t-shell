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
import UIKit
import LocalAuthentication

enum SecurityScopedFileReadError: Error, LocalizedError {
  case noReadAccess
  case readFailed(underlying: Error)
  case emptyContent
  case invalidUTF8

  var errorDescription: String? {
    switch self {
    case .noReadAccess:
      return "Can't get read access to file."
    case .readFailed(let underlying):
      return underlying.localizedDescription
    case .emptyContent:
      return "File is empty."
    case .invalidUTF8:
      return "File is not valid UTF-8 text."
    }
  }
}

enum SecurityScopedFileReader {
  static func readData(from url: URL, options: Data.ReadingOptions = .alwaysMapped) throws -> Data {
    let hasSecurityScope = url.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
    }

    var coordinationError: NSError?
    var readResult: Result<Data, Error>?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
      readResult = Result {
        try Data(contentsOf: coordinatedURL, options: options)
      }
    }

    if let coordinationError {
      throw _mapError(coordinationError)
    }

    guard let readResult else {
      throw SecurityScopedFileReadError.readFailed(underlying: CocoaError(.fileReadUnknown))
    }

    switch readResult {
    case .success(let data):
      return data
    case .failure(let error):
      throw _mapError(error)
    }
  }

  static func readUTF8Text(from url: URL) throws -> String {
    let data = try readData(from: url)
    guard let text = String(data: data, encoding: .utf8) else {
      throw SecurityScopedFileReadError.invalidUTF8
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw SecurityScopedFileReadError.emptyContent
    }
    return trimmed
  }

  private static func _mapError(_ error: Error) -> SecurityScopedFileReadError {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
      return .noReadAccess
    }
    return .readFailed(underlying: error)
  }
}

@objc class LocalAuth: NSObject {
  
  @objc static let shared = LocalAuth()
  
  private var _didEnterBackgroundAt: Date? = nil
  private var _inProgress = false
  
  override init() {
    super.init()
    
    // warm up LAContext
    LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    
    if BKUserConfigurationManager.userSettingsValue(forKey: BKUserConfigAutoLock) {
      _didEnterBackgroundAt = Date.distantPast
    }
    
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: OperationQueue.main
    ) { _ in
      
      // Do not reset didEnterBackground if we locked
      if let didEnterBackgroundAt = self._didEnterBackgroundAt,
         Date().timeIntervalSince(didEnterBackgroundAt) > TimeInterval(self.getMaxMinutesTimeInterval() * 60) {
        return
      }
      self._didEnterBackgroundAt = Date()
    }
  }
  
  var lockRequired: Bool {
    guard
      let didEnterBackgroundAt = _didEnterBackgroundAt,
      BKUserConfigurationManager.userSettingsValue(forKey: BKUserConfigAutoLock),
      Date().timeIntervalSince(didEnterBackgroundAt) > TimeInterval(getMaxMinutesTimeInterval() * 60)
    else {
      return false
    }
    
    return true
  }
  
  @objc func getMaxMinutesTimeInterval() -> Int {
    UserDefaults.standard.value(forKey: "BKUserConfigLockIntervalKey") as? Int ?? 10
  }
  
  @objc func setNewLockTimeInterval(minutes: Int) {
    UserDefaults.standard.set(minutes, forKey: "BKUserConfigLockIntervalKey")
  }
  
  func unlock() {
    authenticate(
      callback: { [weak self] (success) in
        if success {
          self?.stopTrackTime()
        }
      },
      reason: "to unlock blink."
    )
  }
  
  func stopTrackTime() {
    _didEnterBackgroundAt = nil
  }
  
  @objc func authenticate(callback: @escaping (_ success: Bool) -> Void, reason: String = "to access sensitive data.") {
    if _inProgress {
      callback(false)
      return
    }
    _inProgress = true
    
    let context = LAContext()
    var error: NSError?
    guard
      context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    else {
      debugPrint(error?.localizedDescription ?? "Can't evaluate policy")
      _inProgress = false
      callback(false)
      return
    }

    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason ) { success, error in
      DispatchQueue.main.async {
        self._inProgress = false
        callback(success)
      }
    }
  }
}
