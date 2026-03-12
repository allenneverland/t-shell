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

import CloudKit
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

import BlinkFileProvider
import BlinkConfig
import SSH

struct FileDomainView: View {
  @EnvironmentObject private var _nav: Nav
  var domain: FileProviderDomain
  var hostAlias: String
  let refreshList: () -> ()
  let saveHost: () -> ()
  @State private var _displayName: String = ""
  @State private var _remotePath: String = ""
  @State private var _loaded = false
  @State private var _errorMessage = ""

  @State private var showValidateConnectionProgress = false
  @State private var validateConnectionCompletion: Subscribers.Completion<ValidationError>? = nil
  @State private var validateConnectionCancellable: AnyCancellable? = nil

  var body: some View {
    List {
      Section {
        Field("Name", $_displayName, next: "Path", placeholder: "Required")
        Field("Path", $_remotePath,  next: "",     placeholder: "root folder on the remote")
      }
      Section(footer: Text("Validating the connection will save all changes made.")) {
        Button("Validate Connection", action: {
          _testConnection()
        })
          .alert(isPresented: $showValidateConnectionProgress) {
            if let completion = validateConnectionCompletion {
              switch completion {
              case .finished:
                return Alert(
                  title: Text("Validating Connection Succeded"),
                  message: Text("Connection tested successfully."),
                  dismissButton: .default(Text("Dismiss"))
                )
              case .failure(let error):
                return Alert(
                  title: Text("Validating Connection Failed"),
                  message: Text(error.localizedDescription),
                  dismissButton: .default(Text("Dismiss"))
                )
              }
            } else {
              return Alert(
                title: Text("Validating Connection"),
                message: Text("Connecting to remote..."),
                // message: Text(validateConnectionProgressMessage),
                dismissButton: .cancel(Text("Cancel"), action: { self.validateConnectionCancellable = nil })
              )
            }
          }
      }
      // Disabled for now. Although the cached can be erased, the cache in memory will still remain and that
      // will mess with state. Deleting the domain itself is the way to go.
//      Section {
//        Button(
//          action: _eraseCache,
//          label: { Label("Erase location cache", systemImage: "trash").foregroundColor(.red)}
//        )
//          .accentColor(.red)
//      }
    }
    .listStyle(GroupedListStyle())
    .navigationBarTitle("Files.app Location")
    .navigationBarItems(
      trailing: Group {
        Button("Update", action: {
          guard _validate() else { return }
          _updateDomain()
          refreshList()
          _nav.navController.popViewController(animated: true)
        }
        )//.disabled(_conflictedICloudHost != nil)
      }
    )
    .onAppear {
      if !_loaded {
        _loaded = true
        _displayName = domain.displayName
        _remotePath = domain.remotePath
      }
    }
    .alert(errorMessage: $_errorMessage)
  }

  private func _updateDomain() {
    domain.displayName = _displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    domain.remotePath = _remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
    domain.useReplicatedExtension = true
  }

  private func _validate() -> Bool {
    let cleanDisplayName = _displayName.trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      if cleanDisplayName.isEmpty {
        throw ValidationError.general(message: "Name is required", field: "Name")
      }
      return true
    } catch {
      _errorMessage = error.localizedDescription
      return false
    }
  }

  private func _testConnection() {
    guard _validate() else { return }
    _updateDomain()
    saveHost()

    let providerPath: BlinkFileProviderPath
    do {
      providerPath = try BlinkFileProviderPath(domain.connectionPathFor(alias: hostAlias))
    } catch {
      _errorMessage = "Could not resolve domain path."
      return
    }

    let conn = FilesTranslatorConnection(providerPath: providerPath,
                                         configurator: BlinkConfigFactoryConfiguration())
    self.validateConnectionCancellable = nil
    self.validateConnectionCompletion = nil
    // self.isValidatingConnection = true
    self.showValidateConnectionProgress = true

    self.validateConnectionCancellable = conn.rootTranslator
      .mapError { error in ValidationError.connection(message: "Connection error: \(error)") }
      .sink(
        receiveCompletion: {
          self.validateConnectionCompletion = $0
          //self.showValidateConnectionProgress = false
        },
        receiveValue: { _ in }
      )
  }
//  private func _eraseCache() {
//    if let nsDomain = domain.nsFileProviderDomain(alias: alias) {
//      _NSFileProviderManager.clearFileProviderCache(nsDomain)
//    }
//  }
}

fileprivate struct FileDomainRow: View {
  let domain: FileProviderDomain
  let alias: String
  let refreshList: () -> ()
  let saveHost: () -> ()

  var body: some View {
    Row(
      content: {
        HStack {
          if !domain.useReplicatedExtension {
            Text("DEPRECATED")
              .font(.footnote)
              .padding(6)
              .background(Color.red.opacity(0.3))
              .cornerRadius(8)
              .frame(maxHeight: .infinity)
          }
          Text(domain.displayName)
          Spacer()
          Text(domain.remotePath).font(.system(.subheadline))
        }
      },
      details: {
        FileDomainView(domain: domain, hostAlias: alias, refreshList: refreshList, saveHost: saveHost)
      }
    )
  }
}

struct FormLabel: View {
  let text: String
  var minWidth: CGFloat = 86

  var body: some View {
    Text(text).frame(minWidth: minWidth, alignment: .leading)
  }
}

struct Field: View {
  private let _id: String
  private let _label: String
  private let _placeholder: String
  @Binding private var value: String
  private let _next: String?
  private let _secureTextEntry: Bool
  private let _enabled: Bool
  private let _kbType: UIKeyboardType

  init(_ label: String, _ value: Binding<String>, next: String, placeholder: String, id: String? = nil, secureTextEntry: Bool = false, enabled: Bool = true, kbType: UIKeyboardType = .default) {
    _id = id ?? label
    _label = label
    _value = value
    _placeholder = placeholder
    _next = next
    _secureTextEntry = secureTextEntry
    _enabled = enabled
    _kbType = kbType
  }

  var body: some View {
    HStack {
      FormLabel(text: _label)
      FixedTextField(
        _placeholder,
        text: $value,
        id: _id,
        nextId: _next,
        secureTextEntry: _secureTextEntry,
        keyboardType: _kbType,
        autocorrectionType: .no,
        autocapitalizationType: .none,
        enabled: _enabled
      )
    }
  }
}

struct FieldSSHKey: View {
  @Binding var value: [String]
  var enabled: Bool = true
  var hasSSHKey: Bool

  var body: some View {
    Row(
      content: {
        HStack {
          if (hasSSHKey || value.isEmpty) {
            FormLabel(text: "Key")
            Spacer()
            Text(value.isEmpty ? "None" : value[0])
              .font(.system(.subheadline)).foregroundColor(.secondary)
          } else {
            Label("Key", systemImage: "exclamationmark.icloud.fill")
            Spacer()
            Text(value[0])
              .font(.system(.subheadline)).foregroundColor(.red)
          }
        }
      },
      details: {
        KeyPickerView(currentKey: enabled ? $value : .constant(value), multipleSelection: false)
      }
    )
  }
}


fileprivate struct FieldMoshCustomOptions: View {
  @Binding var prediction: BKMoshPrediction
  @Binding var overwrite: Bool
  @Binding var experimentalIP: BKMoshExperimentalIP
  var enabled: Bool

  var body: some View {
    Row(
      content: {
        HStack {
          FormLabel(text: "Advanced")
          Spacer()
          //Text(prediction.label + "...").font(.system(.subheadline)).foregroundColor(.secondary)
        }
      },
      details: {
        MoshCustomOptionsPickerView(
          predictionValue: enabled ? $prediction : .constant(prediction),
          overwriteValue: enabled ? $overwrite : .constant(overwrite),
          experimentalIPValue: enabled ? $experimentalIP : .constant(experimentalIP)
        )
      }
    )
  }
}

fileprivate struct FieldAgentForwardPrompt: View {
  @Binding var value: BKAgentForward
  var enabled: Bool

  var body: some View {
    Row(
      content: {
        HStack {
          FormLabel(text: "Agent Forwarding")
          Spacer()
          Text(value.label).font(.system(.subheadline)).foregroundColor(.secondary)
        }
      },
      details: {
        AgentForwardPromptPickerView(
          currentValue: enabled ? $value : .constant(value)
        )
      }
    )
  }
}

fileprivate struct FieldAgentForwardKeys: View {
  @Binding var value: [String]
  var enabled: Bool

  var body: some View {
    Row(
      content: {
        HStack {
          FormLabel(text: "Forward Keys")
          Spacer()
          Text(value.isEmpty ? "None" : value.joined(separator: ", "))
            .font(.system(.subheadline)).foregroundColor(.secondary)
        }
      },
      details: {
        KeyPickerView(currentKey: enabled ? $value : .constant(value), multipleSelection: true)
      }
    ).disabled(!enabled)
  }
}

struct FieldTextArea: View {
  private let _label: String
  @Binding private var value: String
  private let _enabled: Bool

  init(_ label: String, _ value: Binding<String>, enabled: Bool = true) {
    _label = label
    _value = value
    _enabled = enabled
  }

  var body: some View {
    Row(
      content: { FormLabel(text: _label) },
      details: {
        // TextEditor can't change background color
        RoundedRectangle(cornerRadius: 4, style: .circular)
          .fill(Color.primary)
          .overlay(
            TextEditor(text: _value)
              .font(.system(.body))
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .opacity(0.9).disabled(!_enabled)
          )
          .padding()
        .navigationTitle(_label)
        .navigationBarTitleDisplayMode(.inline)
      }
    )
  }
}

struct HostView: View {
  @EnvironmentObject private var _nav: Nav

  @State private var _host: BKHosts?
  private var _duplicatedHost: BKHosts? = nil
  @State private var _conflictedICloudHost: BKHosts? = nil
  @State private var _alias: String = ""
  @State private var _hostName: String = ""
  @State private var _port: String = ""
  @State private var _user: String = ""
  @State private var _password: String = ""
  @State private var _sshKeyName: [String] = []
  @State private var _proxyCmd: String = ""
  @State private var _proxyJump: String = ""
  @State private var _sshConfigAttachment: String = HostView.__sshConfigAttachmentExample
  @State private var _tmuxServiceURL: String = ""
  @State private var _tmuxServiceToken: String = ""
  @State private var _tmuxPushDeviceId: String = ""
  @State private var _tmuxPushDeviceName: String = ""
  @State private var _tmuxPushDeviceApiToken: String = ""
  @State private var _tmuxPushEnabled: Bool = false
  @State private var _tmuxAPNSKeyID: String = ""
  @State private var _tmuxAPNSTeamID: String = ""
  @State private var _tmuxAPNSPrivateKey: String = ""
  @State private var _tmuxImportAPNSFile: Bool = false
  @State private var _tmuxOnboardingRunning: Bool = false
  @State private var _tmuxOnboardingStatus: String = ""

  @State private var _moshServer: String = ""
  @State private var _moshPort: String = ""
  @State private var _moshPrediction: BKMoshPrediction = BKMoshPredictionAdaptive
  @State private var _moshPredictOverwrite: Bool = false
  @State private var _moshExperimentalIP: BKMoshExperimentalIP = BKMoshExperimentalIPNone
  @State private var _moshCommand: String = ""
  @State private var _domains: [FileProviderDomain] = []
  @State private var _domainsListVersion = 0;
  @State private var _loaded = false
  @State private var _enabled: Bool = true

  @State private var _agentForwardPrompt: BKAgentForward = BKAgentForwardNo
  @State private var _agentForwardKeys: [String] = []

  @State private var _errorMessage: String = ""

  private var _iCloudVersion: Bool
  private var _reloadList: () -> ()
  private var _cleanAlias: String {
    _alias.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private var _cleanHostName: String {
    _hostName.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private var _tmuxDefaultEndpoint: String {
    BKHosts.tmuxDefaultBaseURL(forHostName: _cleanHostName) ?? ""
  }
  private var _tmuxResolvedEndpointPreview: String {
    let rawOverride = _tmuxServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !rawOverride.isEmpty {
      return BKHosts.tmuxNormalizeBaseURL(rawOverride) ?? rawOverride
    }
    return _tmuxDefaultEndpoint
  }
  private var _tmuxEndpointOverrideErrorMessage: String? {
    let rawOverride = _tmuxServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawOverride.isEmpty else {
      return nil
    }
    do {
      _ = try _normalizedTmuxEndpointOverride(rawOverride)
      return nil
    } catch {
      return error.localizedDescription
    }
  }
  private var _autoAPNSBundleID: String {
    Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }


  init(host: BKHosts?, iCloudVersion: Bool = false, reloadList: @escaping () -> ()) {
    _host = host
    _iCloudVersion = iCloudVersion
    _conflictedICloudHost = host?.iCloudConflictCopy
    _reloadList = reloadList
  }

  init(duplicatingHost host: BKHosts, reloadList: @escaping () -> ()) {
    _host = nil
    _duplicatedHost = host
    _iCloudVersion = false
    _conflictedICloudHost = nil
    _reloadList = reloadList
  }

  private func _usageHint() -> String {
    var alias = _cleanAlias
    if alias.count < 2 {
      alias = "[alias]"
    }

    return "Use `mosh \(alias)` or `ssh \(alias)` from the shell to connect."
  }

  var body: some View {
    List {
      if let iCloudCopy = _conflictedICloudHost {
        Section(
          header: Label("CONFLICT DETECTED", systemImage: "exclamationmark.icloud.fill"),
          footer: Text("A conflict has been detected. Please choose a version to save to continue.").foregroundColor(.red)
        ) {
          Row(
            content: { Label("iCloud Version", systemImage: "icloud") },
            details: {
              HostView(host: iCloudCopy, iCloudVersion: true, reloadList: _reloadList)
            }
          )
          Button(
            action: {
              _saveICloudVersion()
              _nav.navController.popViewController(animated: true)
            },
            label: { Label("Save iCloud Version", systemImage: "icloud.and.arrow.down") }
          )
          Button(
            action: {
              _saveLocalVersion()
              _nav.navController.popViewController(animated: true)
            },
            label: { Label("Save Local Version", systemImage: "icloud.and.arrow.up") }
          )
        }
      }
      Section(
        header: Text(_conflictedICloudHost == nil ? "" : "Local Verion"),
        footer: Text(verbatim: _usageHint())
      ) {
        Field("Alias", $_alias, next: "HostName", placeholder: "Required")
      }.disabled(!_enabled)

      Section(header: Text("SSH")) {
        Field("HostName",  $_hostName,  next: "Port",      placeholder: "Host or IP address. Required", enabled: _enabled, kbType: .URL)
        Field("Port",      $_port,      next: "User",      placeholder: "22", enabled: _enabled, kbType: .numberPad)
        Field("User",      $_user,      next: "Password",  placeholder: BLKDefaults.defaultUserName(), enabled: _enabled)
        Field("Password",  $_password,  next: "ProxyCmd",  placeholder: "Ask Every Time", secureTextEntry: true, enabled: _enabled)
        FieldSSHKey(value: $_sshKeyName, enabled: _enabled, hasSSHKey: BKPubKey.all().contains(where: {
          if let keyName = _sshKeyName.first {
            return $0.id == keyName
          }
          return false
        }))
        Field("ProxyCmd",  $_proxyCmd,  next: "ProxyJump", placeholder: "ssh -W %h:%p bastion", enabled: _enabled)
        Field("ProxyJump", $_proxyJump, next: "Server",    placeholder: "bastion1,bastion2", enabled: _enabled)
        FieldTextArea("SSH Config", $_sshConfigAttachment, enabled: _enabled)
      }

      Section(
        header: Text("MOSH")
      ) {
        Field("Server",  $_moshServer,  next: "moshPort",    placeholder: "path/to/mosh-server")
        Field("Port",    $_moshPort,    next: "moshCommand", placeholder: "UDP PORT[:PORT2]", id: "moshPort", kbType: .numbersAndPunctuation)
        Field("Command", $_moshCommand, next: "Alias",       placeholder: "screen -r or tmux attach", id: "moshCommand")
        FieldMoshCustomOptions(
          prediction: $_moshPrediction,
          overwrite: $_moshPredictOverwrite,
          experimentalIP: $_moshExperimentalIP,
          enabled: _enabled
        )
      }.disabled(!_enabled)

      Section(
        header: Text("TMUX")
      ) {
        if let endpointError = _tmuxEndpointOverrideErrorMessage {
          Text(endpointError)
            .font(.footnote)
            .foregroundColor(.red)
        } else {
          Text(_tmuxResolvedEndpointPreview.isEmpty
               ? "Resolved Endpoint: configure HostName first"
               : "Resolved Endpoint: \(_tmuxResolvedEndpointPreview)")
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        Field(
          "Endpoint Override (Advanced)",
          $_tmuxServiceURL,
          next: "Service Token",
          placeholder: "Optional. Leave empty to use https://HostName",
          enabled: _enabled,
          kbType: .URL
        )
        Field("Service Token", $_tmuxServiceToken, next: "Push Device ID", placeholder: "Optional bearer token", secureTextEntry: true, enabled: _enabled)
        Field("Push Device ID", $_tmuxPushDeviceId, next: "Push Device Name", placeholder: "Optional device id for registration", enabled: _enabled)
        Field("Push Device Name", $_tmuxPushDeviceName, next: "Push Device API Token", placeholder: "Optional display name", enabled: _enabled)
        Field("Push Device API Token", $_tmuxPushDeviceApiToken, next: "Alias", placeholder: "Optional token", secureTextEntry: true, enabled: _enabled)
        Field("APNS Key ID", $_tmuxAPNSKeyID, next: "APNS Team ID", placeholder: "ABC123DEFG", enabled: _enabled)
        Field("APNS Team ID", $_tmuxAPNSTeamID, next: "Alias", placeholder: "TEAM123ABC", enabled: _enabled)
        Text(_autoAPNSBundleID.isEmpty
             ? "APNS Bundle ID (Auto): unavailable"
             : "APNS Bundle ID (Auto): \(_autoAPNSBundleID)")
          .font(.footnote)
          .foregroundColor(.secondary)
        Button(
          action: { _tmuxImportAPNSFile = true },
          label: { Label("Import APNS .p8 File", systemImage: "square.and.arrow.down") }
        ).disabled(!_enabled)
        FieldTextArea("APNS Private Key (.p8 or Base64)", $_tmuxAPNSPrivateKey, enabled: _enabled)
        Toggle("Enable Push Routing", isOn: $_tmuxPushEnabled)
          .disabled(!_enabled)
        Button(
          action: _runTmuxSSHOnboarding,
          label: {
            Label(
              _tmuxOnboardingRunning ? "正在執行一鍵 SSH Onboarding…" : "一鍵 SSH Onboarding（安裝 tmuxd + APNs + bell hook）",
              systemImage: "bolt.horizontal.circle"
            )
          }
        )
        .disabled(!_enabled || _tmuxOnboardingRunning)
        Button(
          action: _runTmuxAPNSRegistrationOnly,
          label: {
            Label(
              _tmuxOnboardingRunning ? "正在重試 APNs 註冊…" : "重試 APNs 註冊（不重跑遠端安裝）",
              systemImage: "arrow.clockwise.circle"
            )
          }
        )
        .disabled(
          !_enabled
          || _tmuxOnboardingRunning
          || _tmuxServiceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        if !_tmuxOnboardingStatus.isEmpty {
          Text(_tmuxOnboardingStatus)
            .font(.footnote)
            .foregroundColor(.secondary)
        }
      }.disabled(!_enabled)

      Section(
        header: Text("SSH AGENT")
      ) {
        FieldAgentForwardPrompt(value: $_agentForwardPrompt, enabled: _enabled)
        if _agentForwardPrompt != BKAgentForwardNo {
          FieldAgentForwardKeys(value: $_agentForwardKeys, enabled: _enabled)
        }
      }.disabled(!_enabled)

      Section(header: Label("Files.app", systemImage: "folder"),
              footer: Text("Access remote file systems from the Files.app. [Learn More](https://docs.blink.sh/advanced/files-app)")) {
        ForEach(_domains, content: { FileDomainRow(domain: $0, alias: _cleanAlias, refreshList: _refreshDomainsList, saveHost: _saveHost) })
          .onDelete { indexSet in
            _domains.remove(atOffsets: indexSet)
          }
        Button(
          action: {
            let displayName = _cleanAlias
            _domains.append(FileProviderDomain(
              id:UUID(),
              displayName: displayName.isEmpty ? "Location Name" : displayName,
              remotePath: "~",
              proto: "sftp",
              useReplicatedExtension: true
            ))
          },
          label: { Label("Add Location", systemImage: "folder.badge.plus") }
        )
      }
      .id(_domainsListVersion)
      .disabled(!_enabled)
    }
    .listStyle(GroupedListStyle())
    .alert(errorMessage: $_errorMessage)
    .navigationBarItems(
      leading: Group {
        Button("Discard", action: {
          _nav.navController.popViewController(animated: true)
        })
      },
      trailing: Group {
        if !_iCloudVersion {
          Button("Save", action: {
            _validate()
            _saveHost()
            _reloadList()
            _nav.navController.popViewController(animated: true)
          }).disabled(_conflictedICloudHost != nil)
        }
      }
    )
    .navigationBarBackButtonHidden(true)
    .navigationBarTitle(_host == nil ? "New Host" : _iCloudVersion ? "iCloud Host Version" : "Host" )
    .onAppear {
      if !_loaded {
        loadHost()
      }
    }
    .fileImporter(
      isPresented: $_tmuxImportAPNSFile,
      allowedContentTypes: [.data, .plainText],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else {
          return
        }
        do {
          _tmuxAPNSPrivateKey = try SecurityScopedFileReader.readUTF8Text(from: url)
        } catch let error as SecurityScopedFileReadError {
          switch error {
          case .emptyContent, .invalidUTF8:
            _errorMessage = "APNS .p8 file is empty or invalid UTF-8."
          case .noReadAccess, .readFailed:
            _errorMessage = "Failed to import APNS .p8 file: \(error.localizedDescription)"
          }
        } catch {
          _errorMessage = "Failed to import APNS .p8 file: \(error.localizedDescription)"
        }
      case .failure(let error):
        _errorMessage = "APNS file import failed: \(error.localizedDescription)"
      }
    }

  }

  private static var __sshConfigAttachmentExample: String { "# Compression no" }

  func loadHost() {
    _loaded = true

    guard let host = _host ?? _duplicatedHost else {
      return
    }

    _alias = host.host ?? ""
    _hostName = host.hostName ?? ""
    _port = host.port == nil ? "" : host.port.stringValue
    _user = host.user ?? ""
    _password = host.password ?? ""
    _sshKeyName = (host.key == nil || host.key.isEmpty) ? [] : [host.key]
    _proxyCmd = host.proxyCmd ?? ""
    _proxyJump = host.proxyJump ?? ""
    _sshConfigAttachment = host.sshConfigAttachment ?? ""
    if _sshConfigAttachment.isEmpty {
      _sshConfigAttachment = HostView.__sshConfigAttachmentExample
    }
    if let moshPort = host.moshPort {
      if let moshPortEnd = host.moshPortEnd {
        _moshPort = "\(moshPort):\(moshPortEnd)"
      } else {
        _moshPort = moshPort.stringValue
      }
    }

    _moshPrediction.rawValue = UInt32(host.prediction?.intValue ?? 0)
    _moshPredictOverwrite = host.moshPredictOverwrite == "yes"
    _moshExperimentalIP.rawValue = UInt32(host.moshExperimentalIP?.intValue ?? 0)
    _moshServer  = host.moshServer ?? ""
    _moshCommand = host.moshStartup ?? ""
    _agentForwardPrompt.rawValue = UInt32(host.agentForwardPrompt?.intValue ?? 0)
    _agentForwardKeys = host.agentForwardKeys ?? []
    _tmuxServiceURL = host.tmuxServiceURL ?? ""
    _tmuxServiceToken = host.tmuxServiceToken ?? ""
    _tmuxPushDeviceId = host.tmuxPushDeviceId ?? ""
    _tmuxPushDeviceName = host.tmuxPushDeviceName ?? ""
    _tmuxPushDeviceApiToken = host.tmuxPushDeviceApiToken ?? ""
    _tmuxPushEnabled = host.tmuxPushEnabled?.boolValue ?? false
    _tmuxAPNSKeyID = host.tmuxAPNSKeyID ?? ""
    _tmuxAPNSTeamID = host.tmuxAPNSTeamID ?? ""
    _tmuxAPNSPrivateKey = AppDelegate.tmuxAPNsPrivateKey(forHostAlias: _alias) ?? ""
    _enabled = !( _conflictedICloudHost != nil || _iCloudVersion)

    if _duplicatedHost == nil {
      _domains = FileProviderDomain.listFrom(jsonString: host.fpDomainsJSON)
    }
  }

  private func _normalizedTmuxEndpointOverride(_ rawValue: String) throws -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return ""
    }
    if trimmed.lowercased().hasPrefix("http://") {
      throw ValidationError.general(
        message: "Endpoint Override uses insecure HTTP. Migrate this host to https:// and rerun secure onboarding."
      )
    }
    guard let normalized = BKHosts.tmuxNormalizeBaseURL(trimmed) else {
      throw ValidationError.general(
        message: "Endpoint Override is invalid. Use https:// with a host."
      )
    }
    return normalized
  }

  private func _validate() {
    let cleanAlias = _cleanAlias

    do {
      if cleanAlias.isEmpty {
        throw ValidationError.general(
          message: "Alias is required."
        )
      }

      if let _ = cleanAlias.rangeOfCharacter(from: .whitespacesAndNewlines) {
        throw ValidationError.general(
          message: "Spaces are not permitted in the alias."
        )
      }

      if let _ = BKHosts.withHost(cleanAlias), cleanAlias != _host?.host {
        throw ValidationError.general(
          message: "Cannot have two hosts with the same alias."
        )
      }

      let cleanHostName = _cleanHostName
      if let _ = cleanHostName.rangeOfCharacter(from: .whitespacesAndNewlines) {
        throw ValidationError.general(message: "Spaces are not permitted in the host name.")
      }

      if cleanHostName.isEmpty {
        throw ValidationError.general(
          message: "HostName is required."
        )
      }

      let endpointOverride = _tmuxServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
      if !endpointOverride.isEmpty {
        _ = try _normalizedTmuxEndpointOverride(endpointOverride)
      }
    } catch {
      _errorMessage = error.localizedDescription
      return
    }
  }

  private func _saveHost() {
    let previousAlias = _host?.host.trimmingCharacters(in: .whitespacesAndNewlines)
    let newAlias = _cleanAlias
    let endpointOverrideRaw = _tmuxServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let tmuxEndpointOverride: String
    do {
      tmuxEndpointOverride = try _normalizedTmuxEndpointOverride(endpointOverrideRaw)
    } catch {
      _errorMessage = error.localizedDescription
      return
    }
    let savedHost = BKHosts.saveHost(
      previousAlias,
      withNewHost: newAlias,
      hostName: _hostName.trimmingCharacters(in: .whitespacesAndNewlines),
      sshPort: _port.trimmingCharacters(in: .whitespacesAndNewlines),
      user: _user.trimmingCharacters(in: .whitespacesAndNewlines),
      password: _password,
      hostKey: _sshKeyName.isEmpty ? "" : _sshKeyName[0],
      moshServer: _moshServer,
      moshPredictOverwrite: _moshPredictOverwrite ? "yes" : nil,
      moshExperimentalIP: _moshExperimentalIP,
      moshPortRange: _moshPort,
      startUpCmd: _moshCommand,
      prediction: _moshPrediction,
      proxyCmd: _proxyCmd,
      proxyJump: _proxyJump,
      sshConfigAttachment: _sshConfigAttachment == HostView.__sshConfigAttachmentExample ? "" : _sshConfigAttachment,
      fpDomainsJSON: FileProviderDomain.toJson(list: _domains),
      agentForwardPrompt: _agentForwardPrompt,
      agentForwardKeys: _agentForwardPrompt == BKAgentForwardNo ? [] : _agentForwardKeys,
      tmuxServiceURL: tmuxEndpointOverride,
      tmuxServiceToken: _tmuxServiceToken.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxPushDeviceId: _tmuxPushDeviceId.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxPushDeviceName: _tmuxPushDeviceName.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxPushDeviceApiToken: _tmuxPushDeviceApiToken.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxPushEnabled: NSNumber(value: _tmuxPushEnabled),
      tmuxAPNSKeyID: _tmuxAPNSKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxAPNSTeamID: _tmuxAPNSTeamID.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxAPNSBundleID: _autoAPNSBundleID
    )

    guard let host = savedHost else {
      return
    }

    let privateKey = _tmuxAPNSPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if !newAlias.isEmpty {
      AppDelegate.setTmuxAPNsPrivateKey(privateKey.isEmpty ? nil : privateKey, forHostAlias: newAlias)
    }
    if let previousAlias,
       !previousAlias.isEmpty,
       previousAlias != newAlias
    {
      AppDelegate.removeTmuxAPNsPrivateKey(forHostAlias: previousAlias)
    }

    BKHosts.updateHost(host.host, withiCloudId: host.iCloudRecordId, andLastModifiedTime: Date())
    BKiCloudSyncHandler.shared()?.check(forReachabilityAndSync: nil)
    #if targetEnvironment(macCatalyst)
    #else
    _NSFileProviderManager.syncWithBKHosts()
    #endif
  }

  private func _saveICloudVersion() {
    guard
      let host = _host,
      let iCloudHost = host.iCloudConflictCopy,
      let syncHandler = BKiCloudSyncHandler.shared()
    else {
      return
    }

    if let recordId = host.iCloudRecordId {
      syncHandler.deleteRecord(recordId, of: BKiCloudRecordTypeHosts)
    }
    let moshPort = iCloudHost.moshPort
    let moshPortEnd = iCloudHost.moshPortEnd

    var moshPortRange = moshPort?.stringValue ?? ""
    if let moshPort = moshPort, let moshPortEnd = moshPortEnd {
      moshPortRange = "\(moshPort):\(moshPortEnd)"
    }

    BKHosts.saveHost(
      host.host,
      withNewHost: iCloudHost.host,
      hostName: iCloudHost.hostName,
      sshPort: iCloudHost.port?.stringValue ?? "",
      user: iCloudHost.user,
      password: iCloudHost.password,
      hostKey: iCloudHost.key,
      moshServer: iCloudHost.moshServer,
      moshPredictOverwrite: iCloudHost.moshPredictOverwrite,
      moshExperimentalIP: BKMoshExperimentalIP(UInt32(iCloudHost.moshExperimentalIP?.intValue ?? 0)),
      moshPortRange: moshPortRange,
      startUpCmd: iCloudHost.moshStartup,
      prediction: BKMoshPrediction(UInt32(iCloudHost.prediction?.intValue ?? 0)),
      proxyCmd: iCloudHost.proxyCmd,
      proxyJump: iCloudHost.proxyJump,
      sshConfigAttachment: iCloudHost.sshConfigAttachment,
      fpDomainsJSON: iCloudHost.fpDomainsJSON,
      agentForwardPrompt: BKAgentForward(UInt32(iCloudHost.agentForwardPrompt?.intValue ?? 0)),
      agentForwardKeys: iCloudHost.agentForwardKeys,
      tmuxServiceURL: host.tmuxServiceURL,
      tmuxServiceToken: host.tmuxServiceToken,
      tmuxPushDeviceId: host.tmuxPushDeviceId,
      tmuxPushDeviceName: host.tmuxPushDeviceName,
      tmuxPushDeviceApiToken: host.tmuxPushDeviceApiToken,
      tmuxPushEnabled: host.tmuxPushEnabled,
      tmuxAPNSKeyID: host.tmuxAPNSKeyID,
      tmuxAPNSTeamID: host.tmuxAPNSTeamID,
      tmuxAPNSBundleID: _autoAPNSBundleID
    )

    BKHosts.updateHost(
      iCloudHost.host,
      withiCloudId: iCloudHost.iCloudRecordId,
      andLastModifiedTime: iCloudHost.lastModifiedTime
    )

    BKHosts.markHost(iCloudHost.host, for: BKHosts.record(fromHost: host), withConflict: false)
    syncHandler.check(forReachabilityAndSync: nil)

    _NSFileProviderManager.syncWithBKHosts()
  }

  private func _saveLocalVersion() {
    guard let host = _host, let syncHandler = BKiCloudSyncHandler.shared()
    else {
      return
    }
    syncHandler.deleteRecord(host.iCloudConflictCopy.iCloudRecordId, of: BKiCloudRecordTypeHosts)
    if (host.iCloudRecordId == nil) {
      BKHosts.markHost(host.iCloudConflictCopy.host, for: BKHosts.record(fromHost: host), withConflict: false)
    }
    syncHandler.check(forReachabilityAndSync: nil)
  }

  private func _runTmuxSSHOnboarding() {
    guard !_tmuxOnboardingRunning else {
      return
    }

    Task { @MainActor in
      _tmuxOnboardingRunning = true
      _tmuxOnboardingStatus = "Preparing onboarding…"
      _errorMessage = ""
      let originalTmuxState = (
        serviceURL: _tmuxServiceURL,
        serviceToken: _tmuxServiceToken,
        pushDeviceId: _tmuxPushDeviceId,
        pushDeviceName: _tmuxPushDeviceName,
        pushDeviceApiToken: _tmuxPushDeviceApiToken,
        pushEnabled: _tmuxPushEnabled
      )
      var preservePartialFailureState = false
      defer {
        _tmuxOnboardingRunning = false
      }

      do {
        let prerequisites = try _validatedTmuxOnboardingPrerequisites()

        _tmuxOnboardingStatus = "Checking notification permission…"
        let apnsToken = try await TmuxSSHOnboardingService.requireAPNSToken()
        let serviceToken = _tmuxServiceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? TmuxSSHOnboardingService.generateServiceToken()
          : _tmuxServiceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let (deviceId, deviceName) = _resolvedDeviceMetadata(alias: prerequisites.alias)

        _tmuxServiceToken = serviceToken
        _tmuxPushDeviceId = deviceId
        _tmuxPushDeviceName = deviceName
        _tmuxPushDeviceApiToken = ""
        _tmuxPushEnabled = false
        _tmuxOnboardingStatus = "Saving host settings…"
        _saveHost()

        guard
          let scene = UIApplication.shared.connectedScenes.activeAppScene(),
          let sceneDelegate = scene.delegate as? SceneDelegate,
          let termDevice = sceneDelegate.spaceController.currentTerm()?.termDevice
        else {
          throw ValidationError.general(
            message: "Cannot run onboarding without an active terminal session. Keep Blink in foreground and retry."
          )
        }

        let remoteResult = try await TmuxSSHOnboardingService.runRemoteOnboarding(
          hostAlias: prerequisites.alias,
          termDevice: termDevice,
          serviceToken: serviceToken,
          apnsKeyBase64: prerequisites.apnsKeyBase64,
          apnsKeyID: prerequisites.apnsKeyID,
          apnsTeamID: prerequisites.apnsTeamID,
          apnsBundleID: prerequisites.apnsBundleID,
          onProgress: { status in
            self._tmuxOnboardingStatus = status
          }
        )

        let resolvedServiceURL = try await TmuxSSHOnboardingService.resolveReachableServiceBaseURL(
          endpointOverride: prerequisites.endpointOverride,
          fallbackServiceBaseURL: prerequisites.defaultServiceURL,
          discoveredServiceBaseURL: remoteResult.discoveredServiceBaseURL,
          onProgress: { status in
            self._tmuxOnboardingStatus = status
          }
        )

        if prerequisites.endpointOverride.isEmpty {
          _tmuxServiceURL = resolvedServiceURL == prerequisites.defaultServiceURL ? "" : resolvedServiceURL
        } else {
          _tmuxServiceURL = prerequisites.endpointOverride
        }
        _tmuxOnboardingStatus = "Persisting endpoint…"
        _saveHost()
        preservePartialFailureState = true

        let deviceApiToken = try await TmuxSSHOnboardingService.registerDeviceWithRetry(
          serviceBaseURL: resolvedServiceURL,
          serviceToken: serviceToken,
          apnsToken: apnsToken,
          deviceId: deviceId,
          deviceName: deviceName,
          serverName: prerequisites.alias,
          onProgress: { status in
            self._tmuxOnboardingStatus = status
          }
        )

        try await TmuxSSHOnboardingService.sendTestBellNotificationWithRetry(
          serviceBaseURL: resolvedServiceURL,
          serviceToken: serviceToken,
          deviceApiToken: deviceApiToken,
          serverName: prerequisites.alias,
          onProgress: { status in
            self._tmuxOnboardingStatus = status
          }
        )

        _tmuxPushDeviceApiToken = deviceApiToken
        _tmuxPushEnabled = true
        _tmuxOnboardingStatus = "Persisting device token…"
        _saveHost()
        _persistLastRegisteredAPNSToken(apnsToken, forAlias: prerequisites.alias)
        _tmuxOnboardingStatus = "Onboarding completed."
      } catch {
        if !preservePartialFailureState {
          _tmuxServiceURL = originalTmuxState.serviceURL
          _tmuxServiceToken = originalTmuxState.serviceToken
          _tmuxPushDeviceId = originalTmuxState.pushDeviceId
          _tmuxPushDeviceName = originalTmuxState.pushDeviceName
          _tmuxPushDeviceApiToken = originalTmuxState.pushDeviceApiToken
          _tmuxPushEnabled = originalTmuxState.pushEnabled
          _saveHost()
        }
        _tmuxOnboardingStatus = ""
        _errorMessage = error.localizedDescription
      }
    }
  }

  private func _runTmuxAPNSRegistrationOnly() {
    guard !_tmuxOnboardingRunning else {
      return
    }

    Task { @MainActor in
      _tmuxOnboardingRunning = true
      _tmuxOnboardingStatus = "Preparing APNs registration…"
      _errorMessage = ""
      defer {
        _tmuxOnboardingRunning = false
      }

      do {
        let alias = _cleanAlias
        if alias.isEmpty {
          throw ValidationError.general(message: "Alias is required.")
        }

        let cleanHostName = _cleanHostName
        if cleanHostName.isEmpty {
          throw ValidationError.general(message: "HostName is required.")
        }

        let endpointOverrideRaw = _tmuxServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointOverride = try _normalizedTmuxEndpointOverride(endpointOverrideRaw)
        guard let defaultServiceURL = BKHosts.tmuxDefaultBaseURL(forHostName: cleanHostName) else {
          throw ValidationError.general(message: "HostName is invalid for tmux endpoint generation.")
        }

        _tmuxOnboardingStatus = "Checking notification permission…"
        let apnsToken = try await TmuxSSHOnboardingService.requireAPNSToken()
        let serviceToken = _tmuxServiceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if serviceToken.isEmpty {
          throw ValidationError.general(message: "Service token is required before APNs registration.")
        }
        let (deviceId, deviceName) = _resolvedDeviceMetadata(alias: alias)

        let resolvedServiceURL = try await TmuxSSHOnboardingService.resolveReachableServiceBaseURL(
          endpointOverride: endpointOverride,
          fallbackServiceBaseURL: defaultServiceURL,
          discoveredServiceBaseURL: nil,
          onProgress: { status in
            self._tmuxOnboardingStatus = status
          }
        )

        if endpointOverride.isEmpty {
          _tmuxServiceURL = resolvedServiceURL == defaultServiceURL ? "" : resolvedServiceURL
        } else {
          _tmuxServiceURL = endpointOverride
        }

        let deviceApiToken = try await TmuxSSHOnboardingService.registerDeviceWithRetry(
          serviceBaseURL: resolvedServiceURL,
          serviceToken: serviceToken,
          apnsToken: apnsToken,
          deviceId: deviceId,
          deviceName: deviceName,
          serverName: alias,
          onProgress: { status in
            self._tmuxOnboardingStatus = status
          }
        )

        _tmuxPushDeviceId = deviceId
        _tmuxPushDeviceName = deviceName
        _tmuxPushDeviceApiToken = deviceApiToken
        _tmuxPushEnabled = true
        _tmuxOnboardingStatus = "Persisting device token…"
        _saveHost()
        _persistLastRegisteredAPNSToken(apnsToken, forAlias: alias)
        _tmuxOnboardingStatus = "APNs registration completed."
      } catch {
        _tmuxOnboardingStatus = ""
        _errorMessage = error.localizedDescription
      }
    }
  }

  private func _resolvedDeviceMetadata(alias: String) -> (deviceId: String, deviceName: String) {
    let deviceId = _tmuxPushDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? alias
      : _tmuxPushDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
    let deviceName = _tmuxPushDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? UIDevice.current.name
      : _tmuxPushDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    return (deviceId, deviceName)
  }

  private func _persistLastRegisteredAPNSToken(_ apnsToken: String, forAlias alias: String) {
    guard let host = BKHosts.withHost(alias), !apnsToken.isEmpty else {
      return
    }
    host.tmuxLastRegisteredAPNSToken = apnsToken
    _ = BKHosts.save()
  }

  private func _validatedTmuxOnboardingPrerequisites() throws -> TmuxOnboardingPrerequisites {
    let alias = _cleanAlias
    if alias.isEmpty {
      throw ValidationError.general(message: "Alias is required.")
    }

    let cleanHostName = _cleanHostName
    if cleanHostName.isEmpty {
      throw ValidationError.general(message: "HostName is required.")
    }

    let endpointOverrideRaw = _tmuxServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let endpointOverride = try _normalizedTmuxEndpointOverride(endpointOverrideRaw)

    guard let defaultServiceURL = BKHosts.tmuxDefaultBaseURL(forHostName: cleanHostName) else {
      throw ValidationError.general(message: "HostName is invalid for tmux endpoint generation.")
    }

    let apnsKeyID = _tmuxAPNSKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
    let apnsTeamID = _tmuxAPNSTeamID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !apnsKeyID.isEmpty, !apnsTeamID.isEmpty else {
      throw ValidationError.general(message: "APNS Key ID / Team ID are required.")
    }

    let apnsBundleID = _autoAPNSBundleID
    guard !apnsBundleID.isEmpty else {
      throw ValidationError.general(message: "Cannot resolve app Bundle ID for APNS topic.")
    }

    guard let apnsKeyBase64 = TmuxSSHOnboardingService.normalizeAPNSKeyBase64(_tmuxAPNSPrivateKey) else {
      throw ValidationError.general(message: "APNS private key is invalid. Paste .p8 content or base64.")
    }

    return TmuxOnboardingPrerequisites(
      alias: alias,
      defaultServiceURL: defaultServiceURL,
      endpointOverride: endpointOverride,
      apnsKeyBase64: apnsKeyBase64,
      apnsKeyID: apnsKeyID,
      apnsTeamID: apnsTeamID,
      apnsBundleID: apnsBundleID
    )
  }

  private func _refreshDomainsList() {
    _domainsListVersion += 1
  }
}

fileprivate enum ValidationError: Error, LocalizedError {
  case general(message: String, field: String? = nil)
  case connection(message: String)

  var errorDescription: String? {
    switch self {
    case .general(message: let message, field: _): return message
    case .connection(message: let message): return message
    }
  }
}

fileprivate struct TmuxOnboardingPrerequisites {
  let alias: String
  let defaultServiceURL: String
  let endpointOverride: String
  let apnsKeyBase64: String
  let apnsKeyID: String
  let apnsTeamID: String
  let apnsBundleID: String
}

enum TmuxSSHOnboardingService {
  private struct RegisterDeviceResponse: Decodable {
    let deviceApiToken: String

    enum CodingKeys: String, CodingKey {
      case deviceApiToken = "device_api_token"
    }
  }

  private struct IngestEventResponse: Decodable {
    let attempted: UInt64
    let muted: UInt64
    let delivered: UInt64
    let failed: UInt64
  }

  private enum PushSelfTestStatus: String, Decodable {
    case delivered
    case apnsUnconfigured = "apns_unconfigured"
    case badDeviceToken = "bad_device_token"
    case dispatchFailed = "dispatch_failed"
  }

  private struct PushSelfTestResponse: Decodable {
    let attempted: UInt64
    let delivered: UInt64
    let failed: UInt64
    let status: PushSelfTestStatus
    let detail: String
  }

  private struct TmuxBellHookVerifyResponse: Decodable {
    let persistentConfigOK: Bool
    let runtimeServerPresent: Bool
    let runtimeHookOK: Bool
    let runtimeOptionsOK: Bool
    let runtimeProbePerformed: Bool
    let runtimeProbeHookOK: Bool
    let runtimeProbeRawBelOK: Bool
    let runtimeProbeCompatible: Bool
    let minimumTmuxVersion: String?
    let detectedTmuxVersion: String?
    let requiredCapabilities: [String]
    let missingCapabilities: [String]
    let runtimeProbeReasonCodes: [String]
    let overallOK: Bool
    let reasons: [String]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
      case persistentConfigOK = "persistent_config_ok"
      case runtimeServerPresent = "runtime_server_present"
      case runtimeHookOK = "runtime_hook_ok"
      case runtimeOptionsOK = "runtime_options_ok"
      case runtimeProbePerformed = "runtime_probe_performed"
      case runtimeProbeHookOK = "runtime_probe_hook_ok"
      case runtimeProbeRawBelOK = "runtime_probe_raw_bel_ok"
      case runtimeProbeCompatible = "runtime_probe_compatible"
      case minimumTmuxVersion = "minimum_tmux_version"
      case detectedTmuxVersion = "detected_tmux_version"
      case requiredCapabilities = "required_capabilities"
      case missingCapabilities = "missing_capabilities"
      case runtimeProbeReasonCodes = "runtime_probe_reason_codes"
      case overallOK = "overall_ok"
      case reasons
      case warnings
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      persistentConfigOK = try container.decode(Bool.self, forKey: .persistentConfigOK)
      runtimeServerPresent = try container.decode(Bool.self, forKey: .runtimeServerPresent)
      runtimeHookOK = try container.decode(Bool.self, forKey: .runtimeHookOK)
      runtimeOptionsOK = try container.decodeIfPresent(Bool.self, forKey: .runtimeOptionsOK) ?? runtimeHookOK
      runtimeProbePerformed = try container.decodeIfPresent(Bool.self, forKey: .runtimeProbePerformed) ?? false
      runtimeProbeHookOK = try container.decodeIfPresent(Bool.self, forKey: .runtimeProbeHookOK) ?? true
      runtimeProbeRawBelOK = try container.decodeIfPresent(Bool.self, forKey: .runtimeProbeRawBelOK) ?? true
      runtimeProbeCompatible = try container.decodeIfPresent(Bool.self, forKey: .runtimeProbeCompatible) ?? true
      minimumTmuxVersion = try container.decodeIfPresent(String.self, forKey: .minimumTmuxVersion)
      detectedTmuxVersion = try container.decodeIfPresent(String.self, forKey: .detectedTmuxVersion)
      requiredCapabilities = try container.decodeIfPresent([String].self, forKey: .requiredCapabilities) ?? []
      missingCapabilities = try container.decodeIfPresent([String].self, forKey: .missingCapabilities) ?? []
      runtimeProbeReasonCodes = try container.decodeIfPresent([String].self, forKey: .runtimeProbeReasonCodes) ?? []
      overallOK = try container.decode(Bool.self, forKey: .overallOK)
      reasons = try container.decodeIfPresent([String].self, forKey: .reasons) ?? []
      warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
  }

  private struct RemoteExecResult {
    let command: String
    let stdout: String
    let stderr: String
    let exitStatus: Int32
  }

  private struct RemotePlatform {
    let os: String
    let arch: String
    let candidates: [String]
  }

  private struct ServeProxyRoute {
    let httpsURL: String
    let proxyTarget: String
  }

  private struct ManagedTmuxdRuntime {
    let localPort: Int
    let proxyTarget: String
    let logPath: String
  }

  fileprivate struct RemoteOnboardingResult {
    let discoveredServiceBaseURL: String?
  }

  private struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
      if lhs.major != rhs.major {
        return lhs.major < rhs.major
      }
      if lhs.minor != rhs.minor {
        return lhs.minor < rhs.minor
      }
      return lhs.patch < rhs.patch
    }
  }

  private static let maxCommandOutputBytes = 8 * 1024 * 1024
  private static let maxBackoffNanos: UInt64 = 12_000_000_000
  private static let minimumSupportedTailscaleVersion = SemanticVersion(major: 1, minor: 52, patch: 0)
  private static let tmuxdLocalPortCandidates = [8787, 8790, 8791]
  private static let tmuxdLocalProxyTarget = "http://127.0.0.1:8787"
  private static let tailscaleHTTPSFallbackPorts = [8787, 8443, 9443]
  private static let tmuxdStateLogPath = "$HOME/.local/state/tmuxd/tmuxd.log"
  private static let tmuxVerifyReasonRuntimeServerNotRunning = "runtime_server_not_running"
  private static let tmuxVerifyReasonRuntimeHookEmpty = "runtime_hook_empty"
  private static let tmuxVerifyReasonRuntimeHookNotRouted = "runtime_hook_not_routed"
  private static let tmuxVerifyReasonRuntimeMonitorBellOff = "runtime_monitor_bell_off"
  private static let tmuxVerifyReasonRuntimeBellActionNone = "runtime_bell_action_none"
  private static let tmuxVerifyReasonRuntimeProbeTriggerHookFailed = "runtime_probe_trigger_hook_failed"
  private static let tmuxVerifyReasonRuntimeProbeTriggerHookNotObserved = "runtime_probe_trigger_hook_not_observed"
  private static let tmuxVerifyReasonRuntimeProbeRawBelNotObserved = "runtime_probe_raw_bel_not_observed"
  private static let tmuxVerifyReasonRuntimeProbeRestoreHookFailed = "runtime_probe_restore_hook_failed"
  private static let tmuxVerifyReasonRuntimeProbeTmuxVersionUnsupported = "runtime_probe_tmux_version_unsupported"
  private static let tmuxVerifyReasonRuntimeProbeTmuxVersionUnavailable = "runtime_probe_tmux_version_unavailable"
  private static let tmuxVerifyReasonRuntimeProbeCapabilityQueryFailed = "runtime_probe_capability_query_failed"
  private static let tmuxVerifyReasonRuntimeProbeMissingRunHook = "runtime_probe_missing_run_hook"
  private static let networkSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 20
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
  }()

  static func generateServiceToken() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  static func normalizeServiceBaseURL(_ raw: String) -> String? {
    BKHosts.tmuxNormalizeBaseURL(raw)
  }

  static func normalizeAPNSKeyBase64(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    if trimmed.contains("-----BEGIN") {
      guard let data = trimmed.data(using: .utf8) else {
        return nil
      }
      return data.base64EncodedString()
    }

    let normalized = trimmed.replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: "\r", with: "")
    guard Data(base64Encoded: normalized) != nil else {
      return nil
    }
    return normalized
  }

  static func tailscaleVersionMeetsMinimum(_ raw: String) -> Bool {
    guard let version = parseSemanticVersion(raw) else {
      return false
    }
    return version >= minimumSupportedTailscaleVersion
  }

  static func classifyTailscaleServeFailureMessage(_ raw: String) -> String? {
    let lower = raw.lowercased()

    if lower.contains("invalid argument format") {
      return "Remote tailscale serve syntax mismatch was detected. Refresh Blink to a build with the updated serve command and rerun onboarding."
    }

    if lower.contains("unknown flag") || lower.contains("unknown command") || lower.contains("serve is not available") {
      return "Remote Tailscale CLI is too old for secure tmux onboarding. Upgrade Tailscale to 1.52.0 or newer and retry."
    }

    if lower.contains("operator") || lower.contains("permission denied") || lower.contains("not allowed") {
      return "Tailscale serve permission is denied on the host. Re-run 'tailscale up --operator=$USER' (or equivalent admin policy) and retry."
    }

    if (lower.contains("certificate") || lower.contains("cert")) &&
      (lower.contains("enable") || lower.contains("visit") || lower.contains("consent") || lower.contains("https")) {
      return "Tailnet HTTPS certificates are not ready yet. Complete HTTPS certificate setup/consent in Tailscale admin, then retry onboarding."
    }

    if lower.contains("foreground listener already exists") ||
      lower.contains("address already in use") ||
      lower.contains("already in use") {
      return "Tailscale HTTPS serve listener conflicts with existing bindings on the host. Blink tried fallback ports (8787/8443/9443); free one of them or remove conflicting listeners, then retry."
    }

    return nil
  }

  static func classifyTmuxdStartupFailureMessage(_ raw: String) -> String? {
    let lower = raw.lowercased()
    if isTmuxdPortConflictOutput(raw) {
      return "Local tmuxd listen port is already in use on the host. Blink will automatically try fallback ports (8787/8790/8791)."
    }

    if lower.contains("invalid") && (lower.contains("apns") || lower.contains("key_base64") || lower.contains("config")) {
      return "tmuxd rejected the generated config (APNs credentials/config format). Verify APNs key, key ID, team ID, and retry onboarding."
    }

    if lower.contains("permission denied") {
      return "tmuxd startup failed due to filesystem or execution permission. Ensure ~/.local/bin/tmuxd and ~/.config/tmuxd are writable and executable."
    }

    if lower.contains("no such file or directory") && lower.contains("tmuxd") {
      return "tmuxd binary is missing on the host. Re-run onboarding to reinstall tmuxd."
    }

    return nil
  }

  static func classifyTmuxBellHookFailureMessage(_ raw: String) -> String? {
    let lower = raw.lowercased()

    if lower.contains("no such file or directory") && lower.contains("tmuxd") {
      return "tmuxd binary is missing on the host. Re-run onboarding to reinstall tmuxd."
    }

    if lower.contains("unrecognized subcommand") && lower.contains("verify") {
      return "Installed tmuxd is outdated and does not support structured bell hook verification. Re-run onboarding to install the latest tmuxd release."
    }

    if lower.contains("set-hook") && lower.contains("syntax error") {
      return "tmux rejected the generated alert-bell hook command due to syntax/escaping mismatch. Re-run onboarding to install the latest tmuxd release; if the host tmux version is very old, upgrade tmux and retry."
    }

    if lower.contains("unknown command: run-hook") ||
      lower.contains(tmuxVerifyReasonRuntimeProbeMissingRunHook) ||
      lower.contains(tmuxVerifyReasonRuntimeProbeTmuxVersionUnsupported) ||
      lower.contains(tmuxVerifyReasonRuntimeProbeTmuxVersionUnavailable) ||
      lower.contains(tmuxVerifyReasonRuntimeProbeCapabilityQueryFailed) {
      return "Installed tmuxd is using a deprecated runtime bell probe path. Re-run onboarding to install the latest tmuxd release, then retry."
    }

    if lower.contains("runtime tmux server is not running") ||
      lower.contains(tmuxVerifyReasonRuntimeServerNotRunning) {
      return "tmux runtime verification requires an active tmux server. Start tmux on the host first (for example, `tmux new -s onboarding`), then rerun onboarding."
    }

    if lower.contains(tmuxVerifyReasonRuntimeMonitorBellOff) ||
      lower.contains(tmuxVerifyReasonRuntimeBellActionNone) ||
      (lower.contains("monitor-bell") && lower.contains("bell-action")) {
      return "tmux runtime bell options are disabled on active sessions/windows (monitor-bell/bell-action). Re-run onboarding after starting tmux so tmuxd can re-apply runtime bell options."
    }

    if lower.contains(tmuxVerifyReasonRuntimeProbeTriggerHookFailed) ||
      lower.contains(tmuxVerifyReasonRuntimeProbeTriggerHookNotObserved) {
      return "tmux alert-bell runtime hook exists but cannot be triggered reliably. Re-run onboarding to re-install runtime hook; if issue persists, restart tmux server and retry."
    }

    if lower.contains(tmuxVerifyReasonRuntimeProbeRawBelNotObserved) {
      return "tmux accepted hook installation but raw BEL (`printf '\\a'`) in tmux pane did not trigger `alert-bell`. Re-run onboarding with an active tmux session and retry the tmux-pane BEL test."
    }

    if lower.contains("runtime alert-bell hook is empty") ||
      lower.contains("runtime tmux bell hook verification failed") ||
      (lower.contains("alert-bell") && lower.contains("stdout:")) {
      return "tmux runtime alert-bell hook is empty or not routed to tmuxd notify. Start a tmux session on the host and rerun onboarding so runtime hook can be applied."
    }

    if lower.contains("permission denied") && lower.contains(".tmux.conf") {
      return "Unable to update ~/.tmux.conf while installing bell hook. Ensure ~/.tmux.conf is writable, then retry onboarding."
    }

    if lower.contains("permission denied") {
      return "tmux bell hook installation failed due to permission issues. Ensure ~/.local/bin/tmuxd is executable and ~/.tmux.conf is writable, then retry onboarding."
    }

    if lower.contains("command not found") && lower.contains("tmux") {
      return "tmux is missing on the host. Install tmux first, then retry onboarding."
    }

    return nil
  }

  private static func tmuxBellHookVerificationFailureMessage(report: TmuxBellHookVerifyResponse) -> String {
    let reasonCodes = Set(report.runtimeProbeReasonCodes.map { $0.lowercased() })
    let missingCapabilities = Set(report.missingCapabilities.map { $0.lowercased() })
    let reasons = report.reasons.isEmpty ? "unknown reason" : report.reasons.joined(separator: "; ")

    if !report.persistentConfigOK {
      return "tmux persistent bell hook configuration is incomplete: \(reasons)"
    }

    if !report.runtimeServerPresent || reasonCodes.contains(tmuxVerifyReasonRuntimeServerNotRunning) {
      return "tmux runtime verification requires an active tmux server. Start tmux on the host first (for example, `tmux new -s onboarding`), then rerun onboarding."
    }

    if !report.runtimeHookOK ||
      reasonCodes.contains(tmuxVerifyReasonRuntimeHookEmpty) ||
      reasonCodes.contains(tmuxVerifyReasonRuntimeHookNotRouted) {
      return "tmux runtime alert-bell hook is empty or not routed to tmuxd notify: \(reasons)"
    }

    if !report.runtimeOptionsOK ||
      reasonCodes.contains(tmuxVerifyReasonRuntimeMonitorBellOff) ||
      reasonCodes.contains(tmuxVerifyReasonRuntimeBellActionNone) {
      return "tmux runtime bell options are disabled on active sessions/windows (monitor-bell/bell-action): \(reasons)"
    }

    if !report.runtimeProbeCompatible ||
      reasonCodes.contains(tmuxVerifyReasonRuntimeProbeTmuxVersionUnsupported) ||
      reasonCodes.contains(tmuxVerifyReasonRuntimeProbeTmuxVersionUnavailable) ||
      reasonCodes.contains(tmuxVerifyReasonRuntimeProbeMissingRunHook) ||
      missingCapabilities.contains("run-hook") {
      return "Installed tmuxd reported a deprecated runtime probe compatibility failure. Re-run onboarding to install the latest tmuxd release, then retry."
    }

    if report.runtimeProbePerformed && !report.runtimeProbeHookOK {
      return "tmux runtime hook probe failed (`set-hook -R alert-bell` path is unhealthy): \(reasons)"
    }

    if report.runtimeProbePerformed && !report.runtimeProbeRawBelOK {
      return "tmux pane raw BEL probe failed (`printf '\\a'` did not trigger alert-bell): \(reasons)"
    }

    if reasonCodes.contains(tmuxVerifyReasonRuntimeProbeRestoreHookFailed) {
      return "tmux runtime probe completed but failed to restore `alert-bell` hook cleanly: \(reasons)"
    }

    return "tmux bell hook verification failed: \(reasons)"
  }

  private static func decodeTmuxBellHookVerifyResponse(_ raw: String) -> TmuxBellHookVerifyResponse? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    guard let data = trimmed.data(using: .utf8) else {
      return nil
    }
    return try? JSONDecoder().decode(TmuxBellHookVerifyResponse.self, from: data)
  }

  static func tailscaleServeConfigScriptForTesting() -> String {
    tailscaleHTTPSFallbackPorts
      .map { tailscaleServeApplyCommand(port: $0, target: tmuxdLocalProxyTarget) }
      .joined(separator: "\n")
  }

  static func tmuxBellHookInstallScriptForTesting() -> String {
    installTmuxBellHookScript()
  }

  static func tmuxBellHookVerifyScriptForTesting() -> String {
    verifyTmuxBellHookScript()
  }

  static func parseTmuxBellHookVerifyJSONForTesting(_ raw: String) -> Bool {
    decodeTmuxBellHookVerifyResponse(raw) != nil
  }

  static func tmuxBellHookVerificationFailureMessageForTesting(_ raw: String) -> String? {
    guard let report = decodeTmuxBellHookVerifyResponse(raw) else {
      return nil
    }
    return tmuxBellHookVerificationFailureMessage(report: report)
  }

  static func tmuxdLocalPortCandidatesForTesting() -> [Int] {
    tmuxdLocalPortCandidates
  }

  static func localHealthzScriptForTesting(port: Int) -> String {
    waitForLocalHealthzScript(localPort: port)
  }

  static func preferredTailscaleHTTPSRouteForTesting(
    statusOutput: String,
    target: String = "http://127.0.0.1:8787"
  ) -> String? {
    preferredHTTPSRoute(fromServeStatus: statusOutput, target: target)
  }

  static func formatExecFailureForTesting(
    exitStatus: Int32,
    stdout: String,
    stderr: String,
    command: String = "tailscale serve"
  ) -> String {
    formatExecFailure(RemoteExecResult(command: command, stdout: stdout, stderr: stderr, exitStatus: exitStatus))
  }

  static func classifySelfTestFailureForTesting(
    statusRaw: String,
    attempted: UInt64,
    delivered: UInt64,
    failed: UInt64,
    detail: String
  ) -> (message: String, retryable: Bool, score: Int)? {
    guard let status = PushSelfTestStatus(rawValue: statusRaw) else {
      return nil
    }
    return classifySelfTestFailure(
      response: PushSelfTestResponse(
        attempted: attempted,
        delivered: delivered,
        failed: failed,
        status: status,
        detail: detail
      )
    )
  }

  static func requireAPNSToken(timeoutNanos: UInt64 = 12_000_000_000) async throws -> String {
    let center = UNUserNotificationCenter.current()
    let settings = await withCheckedContinuation { continuation in
      center.getNotificationSettings { notificationSettings in
        continuation.resume(returning: notificationSettings)
      }
    }

    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      break
    case .notDetermined:
      let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          continuation.resume(returning: granted)
        }
      }
      guard granted else {
        throw ValidationError.general(message: "Push notification permission is required before onboarding.")
      }
    case .denied:
      throw ValidationError.general(message: "Push notifications are disabled. Enable them in iOS Settings before onboarding.")
    @unknown default:
      throw ValidationError.general(message: "Unable to determine push notification permission state.")
    }

    AppDelegate.requestRemoteNotificationsRegistrationIfNeeded()
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
    while DispatchTime.now().uptimeNanoseconds < deadline {
      let token = (AppDelegate.currentAPNSToken() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !token.isEmpty {
        return token
      }
      try await Task.sleep(nanoseconds: 300_000_000)
    }

    throw ValidationError.general(
      message: "APNs token is not available yet. Wait for notification registration to complete, then retry onboarding."
    )
  }

  fileprivate static func runRemoteOnboarding(
    hostAlias: String,
    termDevice: TermDevice,
    serviceToken: String,
    apnsKeyBase64: String,
    apnsKeyID: String,
    apnsTeamID: String,
    apnsBundleID: String,
    onProgress: @escaping (String) -> Void
  ) async throws -> RemoteOnboardingResult {
    await MainActor.run { onProgress("Connecting to remote host…") }
    let client = try await connect(hostAlias: hostAlias, termDevice: termDevice)
    defer {
      SSHPool.deregister(allTunnelsForConnection: client)
    }

    await MainActor.run { onProgress("Detecting remote platform…") }
    let platform = try await resolveRemotePlatform(on: client)

    await MainActor.run { onProgress("Resolving tmuxd release tag…") }
    let releaseTag = try await resolveTmuxdReleaseTag(on: client)

    await MainActor.run { onProgress("Installing tmuxd…") }
    try await installTmuxd(on: client, releaseTag: releaseTag, platform: platform)

    await MainActor.run { onProgress("Checking tailscale state…") }
    try await runChecked(script: ensureTailscaleReadyScript(), on: client)

    await MainActor.run { onProgress("Validating tailscale version…") }
    try await ensureMinimumTailscaleVersion(on: client)

    await MainActor.run { onProgress("Checking tailscale serve permissions…") }
    try await runChecked(script: ensureTailscaleServeStatusReadableScript(), on: client)

    await MainActor.run { onProgress("Starting tmuxd service…") }
    let runtime = try await startTmuxdServiceWithFallback(
      on: client,
      serviceToken: serviceToken,
      apnsKeyBase64: apnsKeyBase64,
      apnsKeyID: apnsKeyID,
      apnsTeamID: apnsTeamID,
      apnsBundleID: apnsBundleID
    )

    await MainActor.run { onProgress("Configuring tailscale HTTPS routing…") }
    try await configureTailscaleHTTPSRouting(on: client, target: runtime.proxyTarget)

    await MainActor.run { onProgress("Validating local tmuxd health…") }
    try await runChecked(script: waitForLocalHealthzScript(localPort: runtime.localPort), on: client)

    await MainActor.run { onProgress("Ensuring tmux server is running…") }
    try await runChecked(script: requireActiveTmuxServerScript(), on: client)

    await MainActor.run { onProgress("Installing tmux bell hook…") }
    try await installTmuxBellHook(on: client)

    await MainActor.run { onProgress("Discovering tailscale HTTPS endpoint…") }
    let discoveredServiceBaseURL = try await resolveTailscaleHTTPSBaseURL(on: client, target: runtime.proxyTarget)
    return RemoteOnboardingResult(discoveredServiceBaseURL: discoveredServiceBaseURL)
  }

  static func resolveReachableServiceBaseURL(
    endpointOverride: String,
    fallbackServiceBaseURL: String,
    discoveredServiceBaseURL: String?,
    onProgress: @escaping (String) -> Void
  ) async throws -> String {
    let candidates: [String]
    if !endpointOverride.isEmpty {
      candidates = uniqueServiceBaseURLs([endpointOverride])
    } else {
      candidates = uniqueServiceBaseURLs([discoveredServiceBaseURL, fallbackServiceBaseURL])
    }

    guard !candidates.isEmpty else {
      throw ValidationError.general(message: "No valid tmux endpoint candidate is available.")
    }

    var failures: [String] = []
    for candidate in candidates {
      do {
        try await waitForServiceHealthWithRetry(
          serviceBaseURL: candidate,
          attempts: 8,
          baseDelayNanos: 600_000_000,
          onProgress: { attempt, total in
            onProgress("Validating service health (\(attempt)/\(total))…")
          }
        )
        return candidate
      } catch {
        failures.append("\(candidate): \(error.localizedDescription)")
      }
    }

    throw ValidationError.general(
      message: "Unable to reach tmux endpoint candidates:\n\(failures.joined(separator: "\n"))"
    )
  }

  static func registerDeviceWithRetry(
    serviceBaseURL: String,
    serviceToken: String,
    apnsToken: String,
    deviceId: String,
    deviceName: String,
    serverName: String,
    attempts: Int = 6,
    baseDelayNanos: UInt64 = 800_000_000,
    onProgress: ((String) -> Void)? = nil
  ) async throws -> String {
    let totalAttempts = max(attempts, 1)
    var lastError: Error?
    for attempt in 1...totalAttempts {
      onProgress?("Registering APNs device (\(attempt)/\(totalAttempts))…")
      do {
        return try await registerDevice(
          serviceBaseURL: serviceBaseURL,
          serviceToken: serviceToken,
          apnsToken: apnsToken,
          deviceId: deviceId,
          deviceName: deviceName,
          serverName: serverName
        )
      } catch {
        lastError = error
        if attempt < totalAttempts {
          let delay = retryDelayNanos(baseDelayNanos: baseDelayNanos, attempt: attempt)
          try await Task.sleep(nanoseconds: delay)
        }
      }
    }

    throw ValidationError.general(
      message: "tmuxd is running, but APNs registration failed: \(lastError?.localizedDescription ?? "unknown error")."
    )
  }

  static func sendTestBellNotificationWithRetry(
    serviceBaseURL: String,
    serviceToken: String,
    deviceApiToken: String,
    serverName: String,
    attempts: Int = 3,
    baseDelayNanos: UInt64 = 700_000_000,
    onProgress: ((String) -> Void)? = nil
  ) async throws {
    let totalAttempts = max(attempts, 1)
    var bestError: (score: Int, error: Error)?
    for attempt in 1...totalAttempts {
      onProgress?("Sending test bell notification (\(attempt)/\(totalAttempts))…")
      var shouldRetry = true
      do {
        let response = try await sendDeviceScopedSelfTestBellNotification(
          serviceBaseURL: serviceBaseURL,
          deviceApiToken: deviceApiToken,
          serviceToken: serviceToken,
          serverName: serverName
        )
        if response.delivered > 0, response.status == .delivered {
          return
        }

        let failure = classifySelfTestFailure(response: response)
        let error = ValidationError.general(message: failure.message)
        bestError = keepHigherPriorityFailure(existing: bestError, candidate: (failure.score, error))
        shouldRetry = failure.retryable
      } catch {
        let message = error.localizedDescription
        let retryable = isRetryableBellVerificationError(message)
        let score = retryable ? 35 : 85
        let wrapped = ValidationError.general(message: message)
        bestError = keepHigherPriorityFailure(existing: bestError, candidate: (score, wrapped))
        shouldRetry = retryable
      }

      if !shouldRetry {
        break
      }

      if attempt < totalAttempts, shouldRetry {
        let delay = retryDelayNanos(baseDelayNanos: baseDelayNanos, attempt: attempt)
        try await Task.sleep(nanoseconds: delay)
      }
    }

    throw ValidationError.general(
      message: "Onboarding verification failed: test bell notification could not be delivered (\(bestError?.error.localizedDescription ?? "unknown error"))."
    )
  }

  static func waitForServiceHealthWithRetry(
    serviceBaseURL: String,
    attempts: Int = 8,
    baseDelayNanos: UInt64 = 600_000_000,
    onProgress: ((Int, Int) -> Void)? = nil
  ) async throws {
    let totalAttempts = max(attempts, 1)
    var lastError: Error?
    for attempt in 1...totalAttempts {
      onProgress?(attempt, totalAttempts)
      do {
        try await checkServiceHealth(serviceBaseURL: serviceBaseURL)
        return
      } catch {
        lastError = error
        if attempt < totalAttempts {
          let delay = retryDelayNanos(baseDelayNanos: baseDelayNanos, attempt: attempt)
          try await Task.sleep(nanoseconds: delay)
        }
      }
    }

    throw ValidationError.general(
      message: "HTTPS health check failed for tmux endpoint: \(lastError?.localizedDescription ?? "unknown error")."
    )
  }

  static func registerDevice(
    serviceBaseURL: String,
    serviceToken: String,
    apnsToken: String,
    deviceId: String,
    deviceName: String,
    serverName: String
  ) async throws -> String {
    guard let baseURL = normalizeServiceBaseURL(serviceBaseURL),
          let registerURL = URL(string: "\(baseURL)/v1/push/devices/register")
    else {
      throw ValidationError.general(message: "Tmux endpoint is invalid.")
    }

    var registerRequest = URLRequest(url: registerURL)
    registerRequest.httpMethod = "POST"
    registerRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    registerRequest.setValue("Bearer \(serviceToken)", forHTTPHeaderField: "Authorization")
    registerRequest.timeoutInterval = 8

    let sandbox = AppDelegate.isAPNSSandboxEnvironment()

    registerRequest.httpBody = try JSONSerialization.data(withJSONObject: [
      "token": apnsToken,
      "sandbox": sandbox,
      "device_id": deviceId,
      "device_name": deviceName,
      "server_name": serverName
    ])

    let registerData: Data
    let registerResponse: URLResponse
    do {
      (registerData, registerResponse) = try await networkSession.data(for: registerRequest)
    } catch {
      throw ValidationError.general(message: "APNs device registration transport error: \(transportErrorMessage(error)).")
    }

    let registerHTTP = registerResponse as? HTTPURLResponse
    guard let registerHTTP, (200...299).contains(registerHTTP.statusCode) else {
      throw ValidationError.general(message: "APNs device registration failed (HTTP \(registerHTTP?.statusCode ?? -1)).")
    }

    let registerResult = try JSONDecoder().decode(RegisterDeviceResponse.self, from: registerData)
    guard !registerResult.deviceApiToken.isEmpty else {
      throw ValidationError.general(message: "Service response is missing device API token.")
    }
    return registerResult.deviceApiToken
  }

  private static func sendTestBellNotification(
    serviceBaseURL: String,
    serviceToken: String,
    serverName: String
  ) async throws -> IngestEventResponse {
    guard let baseURL = normalizeServiceBaseURL(serviceBaseURL),
          let notifyURL = URL(string: "\(baseURL)/v1/push/events/bell")
    else {
      throw ValidationError.general(message: "Tmux endpoint is invalid.")
    }

    var notifyRequest = URLRequest(url: notifyURL)
    notifyRequest.httpMethod = "POST"
    notifyRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    notifyRequest.setValue("Bearer \(serviceToken)", forHTTPHeaderField: "Authorization")
    notifyRequest.timeoutInterval = 8

    let testToken = String(UUID().uuidString.prefix(8))
    notifyRequest.httpBody = try JSONSerialization.data(withJSONObject: [
      "title": "tmux bell",
      "body": "\(serverName) onboarding bell test \(testToken)"
    ])

    let notifyData: Data
    let notifyResponse: URLResponse
    do {
      (notifyData, notifyResponse) = try await networkSession.data(for: notifyRequest)
    } catch {
      throw ValidationError.general(message: "Test bell transport error: \(transportErrorMessage(error)).")
    }

    let notifyHTTP = notifyResponse as? HTTPURLResponse
    guard let notifyHTTP, (200...299).contains(notifyHTTP.statusCode) else {
      throw ValidationError.general(message: "Test bell request failed (HTTP \(notifyHTTP?.statusCode ?? -1)).")
    }

    do {
      return try JSONDecoder().decode(IngestEventResponse.self, from: notifyData)
    } catch {
      throw ValidationError.general(message: "Test bell response decode failed: \(error.localizedDescription)")
    }
  }

  private static func sendDeviceSelfTest(
    serviceBaseURL: String,
    deviceApiToken: String,
    serverName: String
  ) async throws -> PushSelfTestResponse {
    guard let baseURL = normalizeServiceBaseURL(serviceBaseURL),
          let selfTestURL = URL(string: "\(baseURL)/v1/push/self-test")
    else {
      throw ValidationError.general(message: "Tmux endpoint is invalid.")
    }

    var request = URLRequest(url: selfTestURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(deviceApiToken)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 8

    let testToken = String(UUID().uuidString.prefix(8))
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "title": "tmux bell",
      "body": "\(serverName) onboarding bell test \(testToken)"
    ])

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await networkSession.data(for: request)
    } catch {
      throw ValidationError.general(message: "Device self-test transport error: \(transportErrorMessage(error)).")
    }

    let http = response as? HTTPURLResponse
    guard let http else {
      throw ValidationError.general(message: "Device self-test returned non-HTTP response.")
    }

    guard (200...299).contains(http.statusCode) else {
      throw ValidationError.general(message: "Device self-test request failed (HTTP \(http.statusCode)).")
    }

    do {
      return try JSONDecoder().decode(PushSelfTestResponse.self, from: data)
    } catch {
      throw ValidationError.general(message: "Device self-test response decode failed: \(error.localizedDescription)")
    }
  }

  private static func sendDeviceScopedSelfTestBellNotification(
    serviceBaseURL: String,
    deviceApiToken: String,
    serviceToken: String,
    serverName: String
  ) async throws -> PushSelfTestResponse {
    do {
      return try await sendDeviceSelfTest(
        serviceBaseURL: serviceBaseURL,
        deviceApiToken: deviceApiToken,
        serverName: serverName
      )
    } catch {
      let message = error.localizedDescription.lowercased()
      if message.contains("http 404") || message.contains("http 405") {
        let legacy = try await sendTestBellNotification(
          serviceBaseURL: serviceBaseURL,
          serviceToken: serviceToken,
          serverName: serverName
        )
        if legacy.delivered > 0 {
          return PushSelfTestResponse(
            attempted: legacy.attempted,
            delivered: legacy.delivered,
            failed: legacy.failed,
            status: .delivered,
            detail: "Legacy bell ingest endpoint delivered the test notification."
          )
        }

        if legacy.attempted == 0 && legacy.muted == 0 {
          return PushSelfTestResponse(
            attempted: legacy.attempted,
            delivered: legacy.delivered,
            failed: legacy.failed,
            status: .dispatchFailed,
            detail: "Legacy endpoint reports zero active recipients (attempted=0, muted=0). This usually indicates endpoint mismatch or revoked/absent device registration."
          )
        }

        if legacy.failed > 0 {
          return PushSelfTestResponse(
            attempted: legacy.attempted,
            delivered: legacy.delivered,
            failed: legacy.failed,
            status: .dispatchFailed,
            detail: "Legacy endpoint failed APNs dispatch for the registered recipients."
          )
        }

        return PushSelfTestResponse(
          attempted: legacy.attempted,
          delivered: legacy.delivered,
          failed: legacy.failed,
          status: .dispatchFailed,
          detail: "Legacy endpoint accepted bell event but did not deliver."
        )
      }
      throw error
    }
  }

  private static func classifySelfTestFailure(response: PushSelfTestResponse) -> (message: String, retryable: Bool, score: Int) {
    let summary = "attempted=\(response.attempted), delivered=\(response.delivered), failed=\(response.failed), status=\(response.status.rawValue)"
    switch response.status {
    case .delivered:
      return ("Bell verification succeeded.", false, 0)
    case .apnsUnconfigured:
      return ("tmuxd APNs is not configured, so notifications cannot be delivered (\(summary)). \(response.detail)", false, 100)
    case .badDeviceToken:
      return ("APNs rejected this device token (\(summary)). This usually means APNs environment/profile mismatch or a stale token. \(response.detail)", false, 95)
    case .dispatchFailed:
      if response.attempted == 0 {
        return ("Test bell notification had no active recipients (\(summary)). This indicates endpoint mismatch or missing device registration. \(response.detail)", false, 90)
      }
      return ("Test bell notification dispatch failed (\(summary)). \(response.detail)", true, 70)
    }
  }

  private static func keepHigherPriorityFailure(
    existing: (score: Int, error: Error)?,
    candidate: (score: Int, error: Error)
  ) -> (score: Int, error: Error) {
    guard let existing else {
      return candidate
    }
    return candidate.score >= existing.score ? candidate : existing
  }

  private static func isRetryableBellVerificationError(_ message: String) -> Bool {
    let lower = message.lowercased()
    if lower.contains("transport error") ||
      lower.contains("timed out") ||
      lower.contains("timeout") ||
      lower.contains("network connection was lost") ||
      lower.contains("temporarily unavailable") ||
      lower.contains("http 502") ||
      lower.contains("http 503") ||
      lower.contains("http 504") {
      return true
    }
    return false
  }

  private static func checkServiceHealth(serviceBaseURL: String) async throws {
    guard let baseURL = normalizeServiceBaseURL(serviceBaseURL),
          let healthURL = URL(string: "\(baseURL)/v1/healthz")
    else {
      throw ValidationError.general(message: "Tmux endpoint is invalid.")
    }

    var request = URLRequest(url: healthURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 4

    let response: URLResponse
    do {
      (_, response) = try await networkSession.data(for: request)
    } catch {
      throw ValidationError.general(message: "Health check transport error: \(transportErrorMessage(error)).")
    }

    let http = response as? HTTPURLResponse
    guard let http, (200...299).contains(http.statusCode) else {
      throw ValidationError.general(message: "tmux endpoint health check failed (HTTP \(http?.statusCode ?? -1)).")
    }
  }

  private static func resolveTailscaleHTTPSBaseURL(
    on client: SSH.SSHClient,
    target: String
  ) async throws -> String? {
    var serveStatusError: Error?
    do {
      let status = try await readTailscaleServeStatus(on: client)
      if let route = preferredHTTPSRoute(fromServeStatus: status, target: target) {
        return normalizeServiceBaseURL(route)
      }
    } catch {
      serveStatusError = error
    }

    if let dnsName = try await resolveTailnetDNSName(on: client) {
      return normalizeServiceBaseURL("https://\(dnsName)")
    }

    if let serveStatusError {
      throw serveStatusError
    }

    return nil
  }

  private static func uniqueServiceBaseURLs(_ candidates: [String?]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for candidate in candidates {
      guard let candidate, let normalized = normalizeServiceBaseURL(candidate), !normalized.isEmpty else {
        continue
      }
      if seen.insert(normalized).inserted {
        result.append(normalized)
      }
    }
    return result
  }

  private static func retryDelayNanos(baseDelayNanos: UInt64, attempt: Int) -> UInt64 {
    let exponent = max(0, min(attempt - 1, 5))
    let multiplier = UInt64(1 << exponent)
    let product = baseDelayNanos.multipliedReportingOverflow(by: multiplier)
    let base = min(product.overflow ? UInt64.max : product.partialValue, maxBackoffNanos)
    let jitterRangeUpper = max(base / 3, 1)
    let jitter = UInt64.random(in: 0...jitterRangeUpper)
    return min(base + jitter, maxBackoffNanos)
  }

  private static func parseSemanticVersion(_ raw: String) -> SemanticVersion? {
    guard let range = raw.range(of: #"([0-9]+)\.([0-9]+)(?:\.([0-9]+))?"#, options: .regularExpression) else {
      return nil
    }
    let parts = raw[range].split(separator: ".")
    guard parts.count >= 2 else {
      return nil
    }
    guard let major = Int(parts[0]), let minor = Int(parts[1]) else {
      return nil
    }
    let patch = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
    return SemanticVersion(major: major, minor: minor, patch: patch)
  }

  private static func semanticVersionString(_ version: SemanticVersion) -> String {
    "\(version.major).\(version.minor).\(version.patch)"
  }

  private static func transportErrorMessage(_ error: Error) -> String {
    guard let urlError = error as? URLError else {
      return error.localizedDescription
    }
    switch urlError.code {
    case .cannotFindHost, .dnsLookupFailed:
      return "DNS lookup failed (\(urlError.localizedDescription))"
    case .cannotConnectToHost:
      return "TCP connection failed (\(urlError.localizedDescription))"
    case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
         .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
      return "TLS handshake failed (\(urlError.localizedDescription))"
    case .timedOut:
      return "request timed out (\(urlError.localizedDescription))"
    default:
      return urlError.localizedDescription
    }
  }

  private static func connect(hostAlias: String, termDevice: TermDevice) async throws -> SSH.SSHClient {
    let host = try BKConfig().bkSSHHost(hostAlias)
    let hostName = host.hostName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? host.hostName!
      : hostAlias
    let config = try SSHClientConfigProvider.config(host: host, using: termDevice)
    return try await awaitFirst(SSHPool.dial(hostName, with: config, withControlMaster: .no))
  }

  private static func resolveRemotePlatform(on client: SSH.SSHClient) async throws -> RemotePlatform {
    let result = try await runChecked(
      script: """
      set -eu
      uname -s
      uname -m
      """,
      on: client
    )
    let lines = trimmedNonEmptyLines(result.stdout)
    guard lines.count >= 2 else {
      throw ValidationError.general(message: "Unable to detect remote OS/architecture.")
    }

    let os = lines[0].lowercased()
    let arch = lines[1].lowercased()
    guard let candidates = tmuxdCandidates(os: os, arch: arch) else {
      throw ValidationError.general(message: "Unsupported tmuxd platform: \(os)-\(arch).")
    }
    return RemotePlatform(os: os, arch: arch, candidates: candidates)
  }

  private static func resolveTmuxdReleaseTag(on client: SSH.SSHClient) async throws -> String {
    let result = try await runChecked(script: resolveTmuxdReleaseTagScript(), on: client)
    guard let tag = trimmedNonEmptyLines(result.stdout).first else {
      throw ValidationError.general(message: "Unable to resolve tmuxd release tag.")
    }
    return tag
  }

  private static func ensureMinimumTailscaleVersion(on client: SSH.SSHClient) async throws {
    let result = try await runChecked(script: resolveTailscaleVersionScript(), on: client)
    let output = trimmedNonEmptyLines(result.stdout).joined(separator: "\n")
    guard let version = parseSemanticVersion(output) else {
      throw ValidationError.general(
        message: "Unable to parse remote tailscale version from output:\n\(output.isEmpty ? "<empty>" : output)"
      )
    }
    guard version >= minimumSupportedTailscaleVersion else {
      throw ValidationError.general(
        message: "Remote tailscale version \(semanticVersionString(version)) is unsupported. Upgrade to 1.52.0 or newer, then retry onboarding."
      )
    }
  }

  private static func installTmuxd(
    on client: SSH.SSHClient,
    releaseTag: String,
    platform: RemotePlatform
  ) async throws {
    var failures: [String] = []
    for candidate in platform.candidates {
      let downloadURL = "https://github.com/allenneverland/t-shell/releases/download/\(releaseTag)/tmuxd-\(candidate).tar.gz"
      do {
        try await runChecked(script: installTmuxdScript(downloadURL: downloadURL), on: client)
        return
      } catch {
        failures.append("\(candidate): \(error.localizedDescription)")
      }
    }

    let failureMessage = failures.joined(separator: "\n")
    throw ValidationError.general(
      message: "Unable to install tmuxd for \(platform.os)-\(platform.arch):\n\(failureMessage)"
    )
  }

  private static func installTmuxBellHook(on client: SSH.SSHClient) async throws {
    do {
      try await runChecked(script: installTmuxBellHookScript(), on: client)
      let validation = try await runExec(
        command: "sh -lc \(shellQuote(verifyTmuxBellHookScript()))",
        on: client
      )
      guard let report = decodeTmuxBellHookVerifyResponse(validation.stdout) else {
        if validation.exitStatus == 0 {
          throw ValidationError.general(
            message: "tmuxd hooks verify returned invalid JSON output."
          )
        }
        throw ValidationError.general(message: formatExecFailure(validation))
      }

      if !report.overallOK || validation.exitStatus != 0 {
        throw ValidationError.general(
          message: tmuxBellHookVerificationFailureMessage(report: report)
        )
      }
    } catch {
      let raw = error.localizedDescription
      var message = "Failed to install tmux bell hook."
      if let guidance = classifyTmuxBellHookFailureMessage(raw) {
        message += "\n\(guidance)"
      } else {
        message += "\nEnsure ~/.local/bin/tmuxd is executable and ~/.tmux.conf is writable, then retry onboarding."
      }
      if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        message += "\n\(raw)"
      }
      throw ValidationError.general(message: message)
    }
  }

  private static func runChecked(
    script: String,
    on client: SSH.SSHClient
  ) async throws -> RemoteExecResult {
    let command = "sh -lc \(shellQuote(script))"
    let result = try await runExec(command: command, on: client)
    guard result.exitStatus == 0 else {
      throw ValidationError.general(message: formatExecFailure(result))
    }
    return result
  }

  private static func runCheckedCommand(
    command: String,
    on client: SSH.SSHClient
  ) async throws -> RemoteExecResult {
    let result = try await runExec(command: command, on: client)
    guard result.exitStatus == 0 else {
      throw ValidationError.general(message: formatExecFailure(result))
    }
    return result
  }

  private static func runExec(
    command: String,
    on client: SSH.SSHClient
  ) async throws -> RemoteExecResult {
    let stream = try await awaitFirst(client.requestExec(command: command))
    do {
      async let outData = awaitFirst(stream.read(max: maxCommandOutputBytes))
      async let errData = awaitFirst(stream.read_err(max: maxCommandOutputBytes))
      let (stdoutDispatchData, stderrDispatchData) = try await (outData, errData)
      let stdout = decode(dispatchData: stdoutDispatchData)
      let stderr = decode(dispatchData: stderrDispatchData)
      let exitStatus = stream.exitStatus
      stream.cancel()
      return RemoteExecResult(command: command, stdout: stdout, stderr: stderr, exitStatus: exitStatus)
    } catch {
      stream.cancel()
      throw error
    }
  }

  private static func awaitFirst<T>(_ publisher: AnyPublisher<T, Error>) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      var completed = false
      var cancellable: AnyCancellable?
      cancellable = publisher.sink(
        receiveCompletion: { completion in
          guard !completed else { return }
          switch completion {
          case .finished:
            completed = true
            continuation.resume(throwing: ValidationError.general(message: "Remote command returned no output."))
          case .failure(let error):
            completed = true
            continuation.resume(throwing: error)
          }
          cancellable?.cancel()
          cancellable = nil
        },
        receiveValue: { value in
          guard !completed else { return }
          completed = true
          continuation.resume(returning: value)
          cancellable?.cancel()
          cancellable = nil
        }
      )
    }
  }

  private static func decode(dispatchData: DispatchData) -> String {
    let data = Data(dispatchData)
    return String(decoding: data, as: UTF8.self)
  }

  private static func formatExecFailure(_ result: RemoteExecResult) -> String {
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if stderr.isEmpty && stdout.isEmpty {
      return "Remote command failed with exit status \(result.exitStatus)."
    }

    var sections: [String] = []
    if !stderr.isEmpty {
      let snippet = trimmedNonEmptyLines(stderr).prefix(8).joined(separator: "\n")
      sections.append("stderr:\n\(snippet)")
    }
    if !stdout.isEmpty {
      let snippet = trimmedNonEmptyLines(stdout).prefix(8).joined(separator: "\n")
      sections.append("stdout:\n\(snippet)")
    }

    let combined = [stderr, stdout]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    var prefix = "Remote command failed with exit status \(result.exitStatus)."
    if let guidance = classifiedRemoteFailureMessage(command: result.command, output: combined) {
      prefix += "\n\(guidance)"
    }
    return "\(prefix)\n\(sections.joined(separator: "\n"))"
  }

  private static func classifiedRemoteFailureMessage(command: String, output: String) -> String? {
    let lower = output.lowercased()
    if command.contains("tailscale") || lower.contains("tailscale") {
      return classifyTailscaleServeFailureMessage(output)
    }
    if command.contains("tmuxd") || lower.contains("tmuxd") {
      return classifyTmuxdStartupFailureMessage(output)
    }
    return nil
  }

  private static func trimmedNonEmptyLines(_ value: String) -> [String] {
    value
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func tmuxdCandidates(os: String, arch: String) -> [String]? {
    switch "\(os)-\(arch)" {
    case "linux-x86_64":
      return ["linux-x86_64-gnu", "linux-x86_64-musl", "linux-x86_64", "linux-amd64"]
    case "linux-aarch64", "linux-arm64":
      return ["linux-aarch64-gnu", "linux-aarch64-musl", "linux-aarch64", "linux-arm64"]
    case "darwin-arm64", "darwin-aarch64":
      return ["darwin-aarch64", "darwin-arm64"]
    case "darwin-x86_64":
      return ["darwin-x86_64", "darwin-amd64"]
    default:
      return nil
    }
  }

  private static func resolveTmuxdReleaseTagScript() -> String {
    """
    set -eu
    api="https://api.github.com/repos/allenneverland/t-shell/releases?per_page=100"
    if command -v curl >/dev/null 2>&1; then
      json="$(curl -fsSL "$api")"
    elif command -v wget >/dev/null 2>&1; then
      json="$(wget -qO- "$api")"
    else
      echo "curl or wget is required" >&2
      exit 1
    fi

    tag="$(printf '%s\n' "$json" | awk -F'"' '/"tag_name":[[:space:]]*"tmuxd-v/ { print $4; exit }')"
    if [ -z "$tag" ]; then
      tag="$(printf '%s\n' "$json" | awk -F'"' '/"tag_name":[[:space:]]*"/ { print $4; exit }')"
    fi
    [ -n "$tag" ] || { echo "Unable to resolve tmuxd release tag" >&2; exit 1; }
    printf '%s\n' "$tag"
    """
  }

  private static func installTmuxdScript(downloadURL: String) -> String {
    let quotedURL = shellQuote(downloadURL)
    return """
    set -eu
    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT

    if command -v curl >/dev/null 2>&1; then
      curl -fsSL \(quotedURL) -o "$TMPDIR/tmuxd.tgz"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$TMPDIR/tmuxd.tgz" \(quotedURL)
    else
      echo "curl or wget is required" >&2
      exit 1
    fi

    tar -xzf "$TMPDIR/tmuxd.tgz" -C "$TMPDIR"
    bin="$(find "$TMPDIR" -type f -name tmuxd | head -n 1)"
    [ -n "$bin" ] || { echo "tmuxd binary missing in archive" >&2; exit 1; }
    mkdir -p "$HOME/.local/bin"
    install -m 755 "$bin" "$HOME/.local/bin/tmuxd"
    """
  }

  private static func installTmuxBellHookScript() -> String {
    """
    set -eu
    "$HOME/.local/bin/tmuxd" hooks install
    """
  }

  private static func requireActiveTmuxServerScript() -> String {
    """
    set -eu
    if ! command -v tmux >/dev/null 2>&1; then
      echo "tmux is required on host before bell onboarding." >&2
      exit 1
    fi
    if ! tmux list-sessions >/dev/null 2>&1; then
      echo "runtime tmux server is not running; start tmux and retry onboarding." >&2
      exit 1
    fi
    """
  }

  private static func verifyTmuxBellHookScript() -> String {
    """
    set -eu
    "$HOME/.local/bin/tmuxd" hooks verify --json --strict --probe-runtime
    """
  }

  private static func writeConfigScript(
    serviceToken: String,
    apnsKeyBase64: String,
    apnsKeyID: String,
    apnsTeamID: String,
    apnsBundleID: String,
    localPort: Int
  ) -> String {
    let bindAddrToml = tomlStringLiteral("127.0.0.1")
    let serviceTokenToml = tomlStringLiteral(serviceToken)
    let apnsKeyBase64Toml = tomlStringLiteral(apnsKeyBase64)
    let apnsKeyIDToml = tomlStringLiteral(apnsKeyID)
    let apnsTeamIDToml = tomlStringLiteral(apnsTeamID)
    let apnsBundleIDToml = tomlStringLiteral(apnsBundleID)
    return """
    set -eu
    mkdir -p "$HOME/.config/tmuxd"
    umask 077
    cat > "$HOME/.config/tmuxd/config.toml" <<'EOF'
    bind_addr = \(bindAddrToml)
    port = \(localPort)
    service_token = \(serviceTokenToml)

    [apns]
    key_base64 = \(apnsKeyBase64Toml)
    key_id = \(apnsKeyIDToml)
    team_id = \(apnsTeamIDToml)
    bundle_id = \(apnsBundleIDToml)
    EOF
    """
  }

  private static func ensureTailscaleReadyScript() -> String {
    """
    set -eu
    if ! command -v tailscale >/dev/null 2>&1; then
      echo "tailscale is required. Install and login first, then rerun onboarding." >&2
      exit 1
    fi
    if ! tailscale ip -4 >/dev/null 2>&1 && ! tailscale ip -6 >/dev/null 2>&1; then
      echo "tailscale is installed but not connected. Run 'tailscale up' on host first." >&2
      exit 1
    fi
    """
  }

  private static func resolveTailscaleVersionScript() -> String {
    """
    set -eu
    tailscale version
    """
  }

  private static func ensureTailscaleServeStatusReadableScript() -> String {
    """
    set -eu
    if tailscale serve status --json >/dev/null 2>&1; then
      exit 0
    fi
    if tailscale serve status >/tmp/tmuxd-serve-status.out 2>/tmp/tmuxd-serve-status.err; then
      exit 0
    fi
    cat /tmp/tmuxd-serve-status.err >&2 || true
    cat /tmp/tmuxd-serve-status.out || true
    echo "Unable to query tailscale serve status for this user. Check tailscale operator permission and retry." >&2
    exit 1
    """
  }

  private static func startTmuxdServiceWithFallback(
    on client: SSH.SSHClient,
    serviceToken: String,
    apnsKeyBase64: String,
    apnsKeyID: String,
    apnsTeamID: String,
    apnsBundleID: String
  ) async throws -> ManagedTmuxdRuntime {
    var conflictFailures: [String] = []
    for localPort in tmuxdLocalPortCandidates {
      do {
        try await runChecked(
          script: writeConfigScript(
            serviceToken: serviceToken,
            apnsKeyBase64: apnsKeyBase64,
            apnsKeyID: apnsKeyID,
            apnsTeamID: apnsTeamID,
            apnsBundleID: apnsBundleID,
            localPort: localPort
          ),
          on: client
        )
        try await runChecked(script: startTmuxdScript(localPort: localPort), on: client)
        try await runChecked(script: waitForLocalHealthzScript(localPort: localPort), on: client)
        return ManagedTmuxdRuntime(
          localPort: localPort,
          proxyTarget: tmuxdProxyTarget(localPort: localPort),
          logPath: tmuxdStateLogPath
        )
      } catch {
        let diagnostics = (try? await runChecked(script: tmuxdDiagnosticsScript(localPort: localPort), on: client).stdout) ?? ""
        let combined = [error.localizedDescription, diagnostics]
          .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
          .joined(separator: "\n")
        if isTmuxdPortConflictOutput(combined) {
          let detail = firstNonEmptyLine(in: [combined]) ?? "listener conflict"
          conflictFailures.append("port \(localPort): listener conflict (\(detail))")
          continue
        }

        var message = "Failed to start tmuxd service on local port \(localPort)."
        if let guidance = classifyTmuxdStartupFailureMessage(combined) {
          message += "\n\(guidance)"
        }
        if !combined.isEmpty {
          message += "\n\(combined)"
        }
        throw ValidationError.general(message: message)
      }
    }

    var lines = conflictFailures
    if lines.isEmpty {
      lines.append("All tmuxd startup attempts failed before binding a local port.")
    }
    lines.append("Failed to start tmuxd on all managed local ports (8787/8790/8791).")
    throw ValidationError.general(message: lines.joined(separator: "\n"))
  }

  private static func startTmuxdScript(localPort: Int) -> String {
    """
    set -eu
    state_dir="$HOME/.local/state/tmuxd"
    log_file="$state_dir/tmuxd.log"
    pid_file="$state_dir/tmuxd.pid"
    mkdir -p "$state_dir"
    if pgrep -x tmuxd >/dev/null 2>&1; then
      pkill -x tmuxd || true
      sleep 1
    fi
    : > "$log_file"
    nohup "$HOME/.local/bin/tmuxd" serve --config "$HOME/.config/tmuxd/config.toml" > "$log_file" 2>&1 &
    pid="$!"
    printf '%s\\n' "$pid" > "$pid_file"
    sleep 1
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      tail -n 80 "$log_file" >&2 || true
      echo "tmuxd exited immediately after launch on 127.0.0.1:\(localPort)." >&2
      exit 1
    fi
    printf '%s\\n' "$pid"
    """
  }

  private static func tmuxdDiagnosticsScript(localPort: Int) -> String {
    """
    set -eu
    log_file="$HOME/.local/state/tmuxd/tmuxd.log"
    pid_file="$HOME/.local/state/tmuxd/tmuxd.pid"
    pid=""
    if [ -r "$pid_file" ]; then
      pid="$(cat "$pid_file" 2>/dev/null || true)"
    fi
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      echo "tmuxd pid: $pid (running)"
    elif [ -n "$pid" ]; then
      echo "tmuxd pid: $pid (not running)"
    else
      echo "tmuxd pid: <missing>"
    fi
    echo "expected local listen: 127.0.0.1:\(localPort)"
    echo "log path: $log_file"
    if [ -r "$log_file" ]; then
      echo "--- tmuxd.log (tail) ---"
      tail -n 80 "$log_file" || true
    else
      echo "tmuxd log missing"
    fi
    """
  }

  private static func tmuxdProxyTarget(localPort: Int) -> String {
    "http://127.0.0.1:\(localPort)"
  }

  private static func configureTailscaleHTTPSRouting(
    on client: SSH.SSHClient,
    target: String
  ) async throws {
    var conflictFailures: [String] = []
    for port in tailscaleHTTPSFallbackPorts {
      let command = tailscaleServeApplyCommand(port: port, target: target)
      let applyResult = try await runExec(command: command, on: client)
      if applyResult.exitStatus == 0 {
        let status = try await readTailscaleServeStatus(on: client)
        if hasRoute(forPort: port, target: target, inServeStatus: status) {
          return
        }

        let detail = firstNonEmptyLine(in: [applyResult.stderr, applyResult.stdout])
          ?? "apply succeeded but route verification failed"
        conflictFailures.append("port \(port): apply succeeded but route verification failed (\(detail))")
        continue
      }

      let combined = [applyResult.stderr, applyResult.stdout].joined(separator: "\n")
      if isTailscaleServePortConflict(combined) {
        let detail = firstNonEmptyLine(in: [applyResult.stderr, applyResult.stdout]) ?? "listener conflict"
        conflictFailures.append("port \(port): listener conflict (\(detail))")
        continue
      }

      var message = formatExecFailure(applyResult)
      if let status = try? await readTailscaleServeStatus(on: client) {
        let statusSnippet = trimmedNonEmptyLines(status).prefix(8).joined(separator: "\n")
        if !statusSnippet.isEmpty {
          message += "\nserve status:\n\(statusSnippet)"
        }
      }
      message += "\nFailed to configure tailscale serve HTTPS routing to tmuxd."
      throw ValidationError.general(message: message)
    }

    var lines = conflictFailures
    if let status = try? await readTailscaleServeStatus(on: client) {
      let statusSnippet = trimmedNonEmptyLines(status).prefix(8)
      if !statusSnippet.isEmpty {
        lines.append("serve status:")
        lines.append(contentsOf: statusSnippet)
      }
    }
    lines.append("Failed to configure tailscale serve HTTPS routing to tmuxd: no available HTTPS port in 8787/8443/9443.")
    throw ValidationError.general(message: lines.joined(separator: "\n"))
  }

  private static func tailscaleServeApplyCommand(port: Int, target: String) -> String {
    "tailscale serve --yes --bg --https=\(port) --set-path=/ \(target)"
  }

  private static func readTailscaleServeStatus(on client: SSH.SSHClient) async throws -> String {
    let result = try await runCheckedCommand(command: "tailscale serve status", on: client)
    return result.stdout
  }

  private static func hasRoute(
    forPort port: Int,
    target: String,
    inServeStatus statusOutput: String
  ) -> Bool {
    let normalizedTarget = normalizedProxyTarget(target)
    return serveProxyRoutes(from: statusOutput).contains { route in
      normalizedProxyTarget(route.proxyTarget) == normalizedTarget &&
      httpsPort(from: route.httpsURL) == port
    }
  }

  private static func preferredHTTPSRoute(fromServeStatus statusOutput: String, target: String) -> String? {
    let normalizedTarget = normalizedProxyTarget(target)
    let routes = serveProxyRoutes(from: statusOutput).filter {
      normalizedProxyTarget($0.proxyTarget) == normalizedTarget
    }

    guard !routes.isEmpty else {
      return nil
    }

    for port in tailscaleHTTPSFallbackPorts {
      if let route = routes.first(where: { httpsPort(from: $0.httpsURL) == port }) {
        return route.httpsURL
      }
    }
    return routes.first?.httpsURL
  }

  private static func serveProxyRoutes(from statusOutput: String) -> [ServeProxyRoute] {
    var routes: [ServeProxyRoute] = []
    var currentHTTPSURL: String?

    for line in trimmedNonEmptyLines(statusOutput) {
      if line.hasPrefix("https://") {
        currentHTTPSURL = line.split(separator: " ").first.map(String.init)
        continue
      }

      guard let currentHTTPSURL, let proxyTarget = proxyTarget(fromServeStatusLine: line) else {
        continue
      }
      routes.append(ServeProxyRoute(httpsURL: currentHTTPSURL, proxyTarget: proxyTarget))
    }
    return routes
  }

  private static func proxyTarget(fromServeStatusLine line: String) -> String? {
    let parts = line.split(separator: " ").map(String.init)
    guard let proxyIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("proxy") == .orderedSame }),
          proxyIndex + 1 < parts.count
    else {
      return nil
    }
    return parts[proxyIndex + 1]
  }

  private static func normalizedProxyTarget(_ value: String) -> String {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }

  private static func httpsPort(from httpsURL: String) -> Int? {
    guard let components = URLComponents(string: httpsURL) else {
      return nil
    }
    if let port = components.port {
      return port
    }
    return components.scheme?.lowercased() == "https" ? 443 : nil
  }

  private static func isTailscaleServePortConflict(_ output: String) -> Bool {
    let lower = output.lowercased()
    return lower.contains("foreground listener already exists") ||
      lower.contains("address already in use") ||
      lower.contains("already in use") ||
      lower.contains("already exists for port")
  }

  private static func isTmuxdPortConflictOutput(_ output: String) -> Bool {
    let lower = output.lowercased()
    return lower.contains("address already in use") ||
      lower.contains("bind: address already in use") ||
      lower.contains("already in use") ||
      lower.contains("listen tcp") && lower.contains("127.0.0.1")
  }

  private static func firstNonEmptyLine(in outputs: [String]) -> String? {
    for output in outputs {
      if let line = trimmedNonEmptyLines(output).first {
        return line
      }
    }
    return nil
  }

  private static func resolveTailnetDNSName(on client: SSH.SSHClient) async throws -> String? {
    let result = try await runExec(command: "tailscale status --json", on: client)
    guard result.exitStatus == 0 else {
      let output = [result.stderr, result.stdout]
        .flatMap { trimmedNonEmptyLines($0) }
        .joined(separator: "\n")
      if output.isEmpty {
        return nil
      }
      throw ValidationError.general(message: formatExecFailure(result))
    }

    guard let data = result.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data),
          let dnsName = firstTailnetDNSName(fromStatusJSON: json)
    else {
      return nil
    }
    return dnsName
  }

  private static func firstTailnetDNSName(fromStatusJSON json: Any) -> String? {
    if let object = json as? [String: Any] {
      if let selfObject = object["Self"] as? [String: Any],
         let selfDNS = sanitizedDNSName(selfObject["DNSName"] as? String) {
        return selfDNS
      }

      if let directDNS = sanitizedDNSName(object["DNSName"] as? String) {
        return directDNS
      }
    }

    return firstDNSNameRecursive(json).flatMap(sanitizedDNSName)
  }

  private static func firstDNSNameRecursive(_ value: Any) -> String? {
    if let object = value as? [String: Any] {
      if let dnsName = object["DNSName"] as? String {
        return dnsName
      }
      for nested in object.values {
        if let dnsName = firstDNSNameRecursive(nested) {
          return dnsName
        }
      }
      return nil
    }

    if let array = value as? [Any] {
      for nested in array {
        if let dnsName = firstDNSNameRecursive(nested) {
          return dnsName
        }
      }
    }
    return nil
  }

  private static func sanitizedDNSName(_ raw: String?) -> String? {
    guard let raw else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
  }

  private static func waitForLocalHealthzScript(localPort: Int) -> String {
    """
    set -eu
    port="\(localPort)"
    pid_file="$HOME/.local/state/tmuxd/tmuxd.pid"
    log_file="$HOME/.local/state/tmuxd/tmuxd.log"
    i=0
    while [ "$i" -lt 30 ]; do
      pid=""
      if [ -r "$pid_file" ]; then
        pid="$(cat "$pid_file" 2>/dev/null || true)"
      fi
      if [ -n "$pid" ] && ! kill -0 "$pid" >/dev/null 2>&1; then
        tail -n 80 "$log_file" >&2 || true
        echo "tmuxd process exited before health check succeeded on 127.0.0.1:$port." >&2
        exit 1
      fi

      if command -v curl >/dev/null 2>&1; then
        if curl -fsS --connect-timeout 2 --max-time 3 "http://127.0.0.1:$port/v1/healthz" >/dev/null 2>&1; then
          exit 0
        fi
      elif command -v wget >/dev/null 2>&1; then
        if wget -qO- --timeout=3 "http://127.0.0.1:$port/v1/healthz" >/dev/null 2>&1; then
          exit 0
        fi
      elif command -v python3 >/dev/null 2>&1; then
        if python3 -c "import sys,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/v1/healthz' % sys.argv[1], timeout=3).read()" "$port" >/dev/null 2>&1
        then
          exit 0
        fi
      elif command -v python >/dev/null 2>&1; then
        if python -c "import sys; req=__import__('urllib2' if sys.version_info[0] == 2 else 'urllib.request', fromlist=['urlopen']); req.urlopen('http://127.0.0.1:%s/v1/healthz' % sys.argv[1], timeout=3)" "$port" >/dev/null 2>&1
        then
          exit 0
        fi
      else
        if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
          exit 0
        fi
      fi

      i=$((i + 1))
      sleep 1
    done

    tail -n 80 "$log_file" >&2 || true
    echo "tmuxd local health check failed on 127.0.0.1:$port." >&2
    exit 1
    """
  }

  private static func tomlStringLiteral(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\\\", with: "\\\\\\\\")
      .replacingOccurrences(of: "\"", with: "\\\\\"")
    return "\"\(escaped)\""
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }
}
