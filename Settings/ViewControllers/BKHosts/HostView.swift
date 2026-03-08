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

import BlinkFileProvider

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
  @State private var _tmuxAPNSBundleID: String = ""
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
        Field("Service URL", $_tmuxServiceURL, next: "Service Token", placeholder: "https://tmuxd.example.com", enabled: _enabled, kbType: .URL)
        Field("Service Token", $_tmuxServiceToken, next: "Push Device ID", placeholder: "Optional bearer token", secureTextEntry: true, enabled: _enabled)
        Field("Push Device ID", $_tmuxPushDeviceId, next: "Push Device Name", placeholder: "Optional device id for registration", enabled: _enabled)
        Field("Push Device Name", $_tmuxPushDeviceName, next: "Push Device API Token", placeholder: "Optional display name", enabled: _enabled)
        Field("Push Device API Token", $_tmuxPushDeviceApiToken, next: "Alias", placeholder: "Optional token", secureTextEntry: true, enabled: _enabled)
        Field("APNS Key ID", $_tmuxAPNSKeyID, next: "APNS Team ID", placeholder: "ABC123DEFG", enabled: _enabled)
        Field("APNS Team ID", $_tmuxAPNSTeamID, next: "APNS Bundle ID", placeholder: "TEAM123ABC", enabled: _enabled)
        Field("APNS Bundle ID", $_tmuxAPNSBundleID, next: "Alias", placeholder: "sh.blink.shell", enabled: _enabled)
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
              _tmuxOnboardingRunning ? "正在執行一鍵 SSH Onboarding…" : "一鍵 SSH Onboarding（安裝 tmuxd + APNs）",
              systemImage: "bolt.horizontal.circle"
            )
          }
        )
        .disabled(!_enabled || _tmuxOnboardingRunning)
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
          let data = try Data(contentsOf: url)
          if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
             !text.isEmpty
          {
            _tmuxAPNSPrivateKey = text
          } else {
            _errorMessage = "APNS .p8 file is empty or invalid UTF-8."
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
    _tmuxAPNSBundleID = host.tmuxAPNSBundleID ?? ""
    _tmuxAPNSPrivateKey = AppDelegate.tmuxAPNsPrivateKey(forHostAlias: _alias) ?? ""
    _enabled = !( _conflictedICloudHost != nil || _iCloudVersion)

    if _duplicatedHost == nil {
      _domains = FileProviderDomain.listFrom(jsonString: host.fpDomainsJSON)
    }
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

      let cleanHostName = _hostName.trimmingCharacters(in: .whitespacesAndNewlines)
      if let _ = cleanHostName.rangeOfCharacter(from: .whitespacesAndNewlines) {
        throw ValidationError.general(message: "Spaces are not permitted in the host name.")
      }

      if cleanHostName.isEmpty {
        throw ValidationError.general(
          message: "HostName is required."
        )
      }
    } catch {
      _errorMessage = error.localizedDescription
      return
    }
  }

  private func _saveHost() {
    let previousAlias = _host?.host.trimmingCharacters(in: .whitespacesAndNewlines)
    let newAlias = _cleanAlias
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
      tmuxServiceURL: _tmuxServiceURL.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxServiceToken: _tmuxServiceToken.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxPushDeviceId: _tmuxPushDeviceId.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxPushDeviceName: _tmuxPushDeviceName.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxPushDeviceApiToken: _tmuxPushDeviceApiToken.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxPushEnabled: NSNumber(value: _tmuxPushEnabled),
      tmuxAPNSKeyID: _tmuxAPNSKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxAPNSTeamID: _tmuxAPNSTeamID.trimmingCharacters(in: .whitespacesAndNewlines),
      tmuxAPNSBundleID: _tmuxAPNSBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
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
      tmuxAPNSBundleID: host.tmuxAPNSBundleID
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
      defer {
        _tmuxOnboardingRunning = false
      }

      do {
        let alias = _cleanAlias
        if alias.isEmpty {
          throw ValidationError.general(message: "Alias is required.")
        }

        let cleanHostName = _hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHostName.isEmpty {
          throw ValidationError.general(message: "HostName is required.")
        }

        let serviceURL = _tmuxServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceURL.isEmpty else {
          throw ValidationError.general(message: "Service URL is required for SSH onboarding.")
        }

        guard let normalizedServiceURL = TmuxSSHOnboardingService.normalizeServiceBaseURL(serviceURL) else {
          throw ValidationError.general(message: "Service URL is invalid. Use http:// or https:// with a host.")
        }

        let apnsKeyID = _tmuxAPNSKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let apnsTeamID = _tmuxAPNSTeamID.trimmingCharacters(in: .whitespacesAndNewlines)
        let apnsBundleID = _tmuxAPNSBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apnsKeyID.isEmpty, !apnsTeamID.isEmpty, !apnsBundleID.isEmpty else {
          throw ValidationError.general(message: "APNS Key ID / Team ID / Bundle ID are required.")
        }

        guard let apnsKeyBase64 = TmuxSSHOnboardingService.normalizeAPNSKeyBase64(_tmuxAPNSPrivateKey) else {
          throw ValidationError.general(message: "APNS private key is invalid. Paste .p8 content or base64.")
        }

        let apnsToken = (AppDelegate.currentAPNSToken() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if apnsToken.isEmpty {
          AppDelegate.requestRemoteNotificationsRegistrationIfNeeded()
        }

        let deviceId = _tmuxPushDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? alias
          : _tmuxPushDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = _tmuxPushDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? UIDevice.current.name
          : _tmuxPushDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceToken = _tmuxServiceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? TmuxSSHOnboardingService.generateServiceToken()
          : _tmuxServiceToken.trimmingCharacters(in: .whitespacesAndNewlines)

        _tmuxServiceURL = normalizedServiceURL
        _tmuxServiceToken = serviceToken
        _tmuxPushDeviceId = deviceId
        _tmuxPushDeviceName = deviceName
        _tmuxPushDeviceApiToken = ""
        _tmuxPushEnabled = true
        _tmuxOnboardingStatus = "Saving host settings…"
        _saveHost()

        guard
          let scene = UIApplication.shared.connectedScenes.activeAppScene(),
          let sceneDelegate = scene.delegate as? SceneDelegate
        else {
          throw ValidationError.general(message: "Cannot open shell right now. Keep Blink in foreground and retry.")
        }

        let command = TmuxSSHOnboardingService.buildSSHOnboardingCommand(
          hostAlias: alias,
          serviceBaseURL: normalizedServiceURL,
          serviceToken: serviceToken,
          apnsKeyBase64: apnsKeyBase64,
          apnsKeyID: apnsKeyID,
          apnsTeamID: apnsTeamID,
          apnsBundleID: apnsBundleID
        )
        _tmuxOnboardingStatus = "Opening shell and running onboarding script…"
        sceneDelegate.spaceController.openShellAndRunCommand(command)

        if !apnsToken.isEmpty {
          _tmuxOnboardingStatus = "Waiting for tmuxd startup…"
          let deviceApiToken = try await TmuxSSHOnboardingService.registerDeviceWithRetry(
            serviceBaseURL: normalizedServiceURL,
            serviceToken: serviceToken,
            apnsToken: apnsToken,
            deviceId: deviceId,
            deviceName: deviceName,
            serverName: alias
          )
          _tmuxPushDeviceApiToken = deviceApiToken
          _tmuxOnboardingStatus = "Persisting device token…"
          _saveHost()
          _tmuxOnboardingStatus = "Onboarding completed."
        } else {
          _tmuxOnboardingStatus = "Onboarding started in a new shell tab. Allow notifications to complete device registration."
        }
      } catch {
        _tmuxOnboardingStatus = ""
        _errorMessage = error.localizedDescription
      }
    }
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

fileprivate enum TmuxSSHOnboardingService {
  private struct RegisterDeviceResponse: Decodable {
    let deviceApiToken: String

    enum CodingKeys: String, CodingKey {
      case deviceApiToken = "device_api_token"
    }
  }

  static func generateServiceToken() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  static func normalizeServiceBaseURL(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty,
          var components = URLComponents(string: value),
          let host = components.host,
          !host.isEmpty
    else {
      return nil
    }

    let scheme = components.scheme?.lowercased()
    guard scheme == "http" || scheme == "https" else {
      return nil
    }

    components.scheme = scheme
    components.query = nil
    components.fragment = nil
    components.user = nil
    components.password = nil
    let path = components.percentEncodedPath.lowercased()
    if path == "/" || path == "/healthz" || path == "/healthz/" || path == "/v1/healthz" || path == "/v1/healthz/" {
      components.percentEncodedPath = ""
    }

    guard let normalized = components.string else {
      return nil
    }
    return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
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

  static func registerDeviceWithRetry(
    serviceBaseURL: String,
    serviceToken: String,
    apnsToken: String,
    deviceId: String,
    deviceName: String,
    serverName: String,
    attempts: Int = 25,
    delayNanos: UInt64 = 1_000_000_000
  ) async throws -> String {
    var lastError: Error?
    for attempt in 1...max(attempts, 1) {
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
        if attempt < attempts {
          try await Task.sleep(nanoseconds: delayNanos)
        }
      }
    }

    throw ValidationError.general(
      message: "tmuxd started but APNs registration failed: \(lastError?.localizedDescription ?? "unknown error")."
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
      throw ValidationError.general(message: "Service URL is invalid.")
    }

    var registerRequest = URLRequest(url: registerURL)
    registerRequest.httpMethod = "POST"
    registerRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    registerRequest.setValue("Bearer \(serviceToken)", forHTTPHeaderField: "Authorization")

    #if DEBUG
    let sandbox = true
    #else
    let sandbox = false
    #endif

    registerRequest.httpBody = try JSONSerialization.data(withJSONObject: [
      "token": apnsToken,
      "sandbox": sandbox,
      "device_id": deviceId,
      "device_name": deviceName,
      "server_name": serverName
    ])

    let (registerData, registerResponse) = try await URLSession.shared.data(for: registerRequest)
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

  static func buildSSHOnboardingCommand(
    hostAlias: String,
    serviceBaseURL: String,
    serviceToken: String,
    apnsKeyBase64: String,
    apnsKeyID: String,
    apnsTeamID: String,
    apnsBundleID: String
  ) -> String {
    let bindAddr = "0.0.0.0"
    let serviceTokenToml = tomlStringLiteral(serviceToken)
    let apnsKeyBase64Toml = tomlStringLiteral(apnsKeyBase64)
    let apnsKeyIDToml = tomlStringLiteral(apnsKeyID)
    let apnsTeamIDToml = tomlStringLiteral(apnsTeamID)
    let apnsBundleIDToml = tomlStringLiteral(apnsBundleID)
    let bindAddrToml = tomlStringLiteral(bindAddr)
    let serviceURL = shellQuote(serviceBaseURL)
    let script = """
    set -eu
    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT

    download() {
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
        return $?
      fi
      if command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
        return $?
      fi
      return 1
    }

    resolve_tmuxd_release_tag() {
      api="https://api.github.com/repos/allenneverland/t-shell/releases?per_page=100"
      json=""
      if command -v curl >/dev/null 2>&1; then
        json="$(curl -fsSL "$api" || true)"
      elif command -v wget >/dev/null 2>&1; then
        json="$(wget -qO- "$api" || true)"
      else
        echo "curl or wget is required" >&2
        exit 1
      fi

      tag="$(printf '%s\n' "$json" | awk -F'"' '/"tag_name":[[:space:]]*"tmuxd-v/ { print $4; exit }')"
      if [ -z "$tag" ]; then
        tag="$(printf '%s\n' "$json" | awk -F'"' '/"tag_name":[[:space:]]*"/ { print $4; exit }')"
      fi

      if [ -z "$tag" ]; then
        echo "Unable to resolve tmuxd release tag" >&2
        exit 1
      fi

      printf '%s\n' "$tag"
    }

    install_tmuxd() {
      os="$(uname -s | tr '[:upper:]' '[:lower:]')"
      arch="$(uname -m | tr '[:upper:]' '[:lower:]')"
      case "$os-$arch" in
        linux-x86_64) candidates="linux-x86_64-gnu linux-x86_64-musl linux-x86_64 linux-amd64" ;;
        linux-aarch64|linux-arm64) candidates="linux-aarch64-gnu linux-aarch64-musl linux-aarch64 linux-arm64" ;;
        darwin-arm64|darwin-aarch64) candidates="darwin-aarch64 darwin-arm64" ;;
        darwin-x86_64) candidates="darwin-x86_64 darwin-amd64" ;;
        *) echo "Unsupported tmuxd platform: $os-$arch" >&2; exit 1 ;;
      esac

      release_tag="$(resolve_tmuxd_release_tag)"
      selected=""
      for platform in $candidates; do
        url="https://github.com/allenneverland/t-shell/releases/download/$release_tag/tmuxd-$platform.tar.gz"
        if download "$url" "$TMPDIR/tmuxd.tgz"; then
          selected="$url"
          break
        fi
      done

      if [ -z "$selected" ]; then
        echo "Unable to download tmuxd release asset for $os-$arch" >&2
        exit 1
      fi

      tar -xzf "$TMPDIR/tmuxd.tgz" -C "$TMPDIR"
      bin="$(find "$TMPDIR" -type f -name tmuxd | head -n 1)"
      [ -n "$bin" ] || { echo "tmuxd binary missing in archive" >&2; exit 1; }
      mkdir -p "$HOME/.local/bin"
      install -m 755 "$bin" "$HOME/.local/bin/tmuxd"
    }

    write_config_file() {
      mkdir -p "$HOME/.config/tmuxd"
      umask 077
      cat > "$HOME/.config/tmuxd/config.toml" <<'EOF'
      bind_addr = \(bindAddrToml)
      port = 8787
      service_token = \(serviceTokenToml)

      [apns]
      key_base64 = \(apnsKeyBase64Toml)
      key_id = \(apnsKeyIDToml)
      team_id = \(apnsTeamIDToml)
      bundle_id = \(apnsBundleIDToml)
      EOF
    }

    ensure_tmuxd_running() {
      mkdir -p "$HOME/.local/state/tmuxd"
      if pgrep -x tmuxd >/dev/null 2>&1; then
        pkill -x tmuxd || true
        sleep 1
      fi
      nohup "$HOME/.local/bin/tmuxd" serve --config "$HOME/.config/tmuxd/config.toml" > "$HOME/.local/state/tmuxd/tmuxd.log" 2>&1 &
    }

    print_summary() {
      echo "tmuxd started"
      echo "Service URL (configured in app): \(serviceURL)"
    }

    install_tmuxd
    write_config_file
    ensure_tmuxd_running
    print_summary
    """

    return "ssh \(shellQuote(hostAlias)) -t \(shellQuote(script))"
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
