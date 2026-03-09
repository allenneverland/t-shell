////////////////////////////////////////////////////////////////////////////////
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

import Combine
import Foundation
import SystemConfiguration

import RevenueCat
import BlinkConfig

enum RevenueCatRuntime {
  enum State {
    case enabled(apiKey: String)
    case disabled(reason: String)
  }

  private static let _disabledLogLock = NSLock()
  private static let _configurationLock = NSLock()
  private static var _disabledLogContexts = Set<String>()
  private static var _configured = false
  private static let _placeholderFragments = [
    "REVCAT_PUBKEY",
    "REPLACE_WITH",
    "YOUR_REVENUECAT",
    "CHANGEME",
  ]

  static let state: State = {
    let raw = XCConfig.infoPlistRevCatPubliKey()
    let key = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty {
      return .disabled(reason: "Missing `REVCAT_PUBKEY` build setting.")
    }
    let keyUpper = key.uppercased()
    if key.contains("$(") || _placeholderFragments.contains(where: { keyUpper.contains($0) }) {
      return .disabled(reason: "`REVCAT_PUBKEY` is a placeholder. Set your RevenueCat public SDK key.")
    }
    if key.count < 16 {
      return .disabled(reason: "`REVCAT_PUBKEY` looks invalid (too short).")
    }
    if key.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil {
      return .disabled(reason: "`REVCAT_PUBKEY` contains invalid characters.")
    }
    return .enabled(apiKey: key)
  }()

  static var isEnabled: Bool {
    if case .enabled = state {
      return true
    }
    return false
  }

  static var isConfigured: Bool {
    _configurationLock.lock()
    defer { _configurationLock.unlock() }
    return _configured
  }

  static var appUserID: String {
    guard isEnabled else {
      return "revcat_disabled"
    }
    guard isConfigured else {
      return "revcat_unconfigured"
    }
    return Purchases.shared.appUserID
  }

  static var unavailableUserMessage: String {
    guard case .disabled(let reason) = state else {
      return "In-app purchases are unavailable."
    }
    return "In-app purchases are unavailable. \(reason)"
  }

  static func failFastIfNeeded() {
    #if DEBUG
    if case .disabled(let reason) = state, !isRunningTests {
      preconditionFailure("[RevenueCat] \(reason)")
    }
    #endif
  }

  static func logDisabledIfNeeded(context: String) {
    guard case .disabled(let reason) = state else {
      return
    }
    _disabledLogLock.lock()
    defer { _disabledLogLock.unlock() }
    if _disabledLogContexts.contains(context) {
      return
    }
    _disabledLogContexts.insert(context)
    NSLog("[RevenueCat] Disabled (\(context)): \(reason)")
  }

  private static var isRunningTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  static func markConfigured() {
    _configurationLock.lock()
    defer { _configurationLock.unlock() }
    _configured = true
  }
}

public class AppStoreEntitlementsSource: NSObject, EntitlementsSource, PurchasesDelegate {
  public weak var delegate: EntitlementsSourceDelegate?
  
  public func purchases(_ purchases: Purchases, receivedUpdated purchaserInfo: CustomerInfo) {
    var dict = Dictionary<String, Entitlement>()
    for (key, value) in purchaserInfo.entitlements.all {
      dict[key] = Entitlement(
        id: value.identifier,
        active: value.isActive,
        unlockProductID: value.productIdentifier,
        period: EntitlementPeriodType(from: value.periodType)
      )
    }
    delegate?.didUpdateEntitlements(
      source: self,
      entitlements: dict,
      activeSubscriptions: purchaserInfo.activeSubscriptions,
      nonSubscriptionTransactions: Set(purchaserInfo.nonSubscriptions.map({$0.productIdentifier}))
    )
  }
  
  public func startUpdates() {
    guard RevenueCatRuntime.isEnabled, RevenueCatRuntime.isConfigured else {
      RevenueCatRuntime.logDisabledIfNeeded(context: "Entitlements.startUpdates")
      return
    }
    Purchases.shared.delegate = self
  }
}

fileprivate extension EntitlementPeriodType {
  init(from period: RevenueCat.PeriodType) {
    switch period {
    case .normal:
      self = Self.Normal
    case .intro:
      self = Self.Intro
    case .trial:
      self = Self.Trial
    case .prepaid:
      self = Self.None
    }
  }
}

@discardableResult
func configureRevCat() -> Bool {
  guard case .enabled(let apiKey) = RevenueCatRuntime.state else {
    RevenueCatRuntime.failFastIfNeeded()
    RevenueCatRuntime.logDisabledIfNeeded(context: "configure")
    return false
  }

  Purchases.logLevel = .debug
  let cfg = Configuration
    .builder(withAPIKey: apiKey)
    .with(appUserID: nil)
    .with(userDefaults: UserDefaults.suite)
    .build()

  Purchases.configure(with: cfg)
  RevenueCatRuntime.markConfigured()
  return true
}
