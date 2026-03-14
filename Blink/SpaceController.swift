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
@objc protocol CommandsHUDViewDelegate: NSObjectProtocol {
  func currentTerm() -> TermController?
  func spaceController() -> SpaceController?
}


import MBProgressHUD
import SwiftUI


// MARK: UIViewController
class SpaceController: UIViewController {
  
  struct UIState: UserActivityCodable {
    var keys: [UUID] = []
    var currentKey: UUID? = nil
    var bgColor: CodableColor? = nil
    
    static var activityType: String { "space.ctrl.ui.state" }
  }

  final private lazy var _viewportsController = UIPageViewController(
    transitionStyle: .scroll,
    navigationOrientation: .horizontal
  )
  
  var sceneRole: UISceneSession.Role = UISceneSession.Role.windowApplication
  
  private var _viewportsKeys = [UUID]()
  private var _currentKey: UUID? = nil
  
  private var _hud: MBProgressHUD? = nil
  
  private var _overlay = UIView()
  private var _spaceControllerAnimating: Bool = false
  private weak var _termViewToFocus: TermView? = nil
  var stuckKeyCode: KeyCode? = nil
  
  private var _kbObserver = KBObserver()
  private var _snippetsVC: SnippetsViewController? = nil
  private var _blinkMenu: BlinkMenu? = nil
  private var _bottomTapAreaView = UIView()
  private var _didPresentInitialTmuxPaneInbox: Bool = false
  private static var _pendingTmuxRequest: TmuxNotificationRequest? = nil
  
  var safeFrame: CGRect {
    _overlay.frame
  }
  
  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    
    guard let window = view.window
    else {
      return
    }
    
    let bottomInset = _kbObserver.bottomInset ?? 0
    var insets = UIEdgeInsets.zero
    insets.bottom = bottomInset
    _overlay.frame = view.bounds.inset(by: insets)
    _snippetsVC?.view.frame = _overlay.frame
    
    if let menu = _blinkMenu {
      let size = _overlay.frame.size;
      let menuSize = menu.layout(for: size)
      
      menu.frame = CGRect(
        x: size.width * 0.5 - menuSize.width * 0.5,
        y: _overlay.frame.size.height - menuSize.height - 20,
        width: menuSize.width,
        height: menuSize.height
      )
      self.view.bringSubviewToFront(menu)
    }
        
    FaceCamManager.update(in: self)
    PipFaceCamManager.update(in: self)
   
    DispatchQueue.main.async {
      self.forEachActive { t in
        if t.viewIsLoaded && t.view?.superview == nil {
          _ = t.removeFromContainer()
        }
      }
    }
    let windowBounds = window.bounds
    let height: CGFloat = 22
    _bottomTapAreaView.frame = CGRect(x: windowBounds.width * 0.5 - 250, y: windowBounds.height - height, width: 250 * 2, height: height)
//    _bottomTapAreaView.backgroundColor = UIColor.red
    self.view.bringSubviewToFront(_bottomTapAreaView);
    
  }
  
  private func forEachActive(block:(TermController) -> ()) {
    for key in _viewportsKeys {
      if let ctrl: TermController = SessionRegistry.shared.sessionFromIndexWith(key: key) {
        block(ctrl)
      }
    }
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    
    #if targetEnvironment(macCatalyst)
    guard let appBundleUrl = Bundle.main.builtInPlugInsURL else {
      return
    }
    
    let helperBundleUrl = appBundleUrl.appendingPathComponent("AppKitBridge.bundle")
    
    guard let bundle = Bundle(url: helperBundleUrl) else {
      return
    }
    
    bundle.load()
    
    guard let object = NSClassFromString("AppBridge") as? NSObjectProtocol else {
      return
    }
    
    let selector = NSSelectorFromString("tuneStyle")
    object.perform(selector)
    #endif

    _presentInitialTmuxPaneInboxIfNeeded()
  }
  
  @objc func _relayout() {
    guard
      let window = view.window,
      window.screen === UIScreen.main
    else {
      return
    }
    
    view.setNeedsLayout()
  }
  
  @objc public func bottomInset() -> CGFloat {
    _kbObserver.bottomInset ?? 0
  }
  
  @objc private func _setupAppearance() {
    self.view.tintColor = .cyan
    switch BLKDefaults.keyboardStyle() {
    case .light:
      overrideUserInterfaceStyle = .light
    case .dark:
      overrideUserInterfaceStyle = .dark
    default:
      overrideUserInterfaceStyle = .unspecified
    }
  }
  
  public override func viewDidLoad() {
    super.viewDidLoad()
    
    _setupAppearance()
    
    view.isOpaque = true
    
    _viewportsController.view.isOpaque = true
    _viewportsController.dataSource = self
    _viewportsController.delegate = self
    
    
    addChild(_viewportsController)
    
    if let v = _viewportsController.view {
      v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      v.layoutMargins = .zero
      v.frame = view.bounds
      view.addSubview(v)
    }
    
    _viewportsController.didMove(toParent: self)
    
    _overlay.isUserInteractionEnabled = false
    view.addSubview(_overlay)
    
    _registerForNotifications()
    
    if let key = _currentKey ?? _viewportsKeys.first {
      let term: TermController = SessionRegistry.shared[key]
      term.delegate = self
      term.bgColor = view.backgroundColor ?? .black
      _currentKey = key
      _viewportsController.setViewControllers([term], direction: .forward, animated: false)
    }
    
    self.view.addInteraction(_kbObserver)
    
    self.view.addSubview(_bottomTapAreaView)
    
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleQuickActionsAction))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.numberOfTouchesRequired = 1
    _bottomTapAreaView.addGestureRecognizer(doubleTap)
    
    NotificationCenter.default.addObserver(self, selector: #selector(_geoTrackStateChanged), name: NSNotification.Name.BLGeoTrackStateChange, object: nil)
    
//    view.addSubview(_faceCam)
//    addChild(_faceCam.controller)
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { self.alertSubscriptionGroupViolation() }
  }
  
  func alertSubscriptionGroupViolation() {
    // NOTE: Added just in case, as I have seen in RevCat some users ending up in both groups (bc
    // things can still be selected outside the App).
    let msg = """
You may be in two different subscription groups and hence, you may end up overpaying for Blink.
Please go to your subscriptions and cancel one of them!
"""
    
    if EntitlementsManager.shared.groupsCheckViolation() {
      let ctrl = UIAlertController(title: "Important!", message: msg, preferredStyle: .alert)
      ctrl.addAction(UIAlertAction(title: "Ok", style: .default))
      self.present(ctrl, animated: true)
    }
  }
  
  func showAlert(msg: String) {
    let ctrl = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
    ctrl.addAction(UIAlertAction(title: "Ok", style: .default))
    self.present(ctrl, animated: true)
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  func _registerForNotifications() {
    let nc = NotificationCenter.default
    
    nc.addObserver(self,
                   selector: #selector(_didBecomeKeyWindow),
                   name: UIWindow.didBecomeKeyNotification,
                   object: nil)
    
    nc.addObserver(self, selector:#selector(_didBecomeKeyWindow), name: UIApplication.didBecomeActiveNotification, object: nil)
    
    nc.addObserver(self, selector: #selector(_relayout),
                   name: NSNotification.Name(rawValue: LayoutManagerBottomInsetDidUpdate),
                   object: nil)
    
    nc.addObserver(self, selector: #selector(_setupAppearance),
                   name: NSNotification.Name(rawValue: BKAppearanceChanged),
                   object: nil)
    
    
    nc.addObserver(self, selector: #selector(_termViewIsReady(n:)), name: NSNotification.Name(TermViewReadyNotificationKey), object: nil)
    nc.addObserver(self, selector: #selector(_termViewBrowserIsReady(n:)), name: NSNotification.Name(TermViewBrowserReadyNotificationKey), object: nil)
    
    
    
    nc.addObserver(self, selector: #selector(_UISceneDidEnterBackgroundNotification(_:)),
                   name: UIScene.didEnterBackgroundNotification, object: nil)
    
    nc.addObserver(self, selector: #selector(_UISceneWillEnterForegroundNotification(_:)),
                   name: UIScene.willEnterForegroundNotification, object: nil)

    nc.addObserver(self, selector: #selector(_openTmuxPaneFromNotification(_:)),
                   name: .BLKOpenTmuxPane, object: nil)

    _drainPendingTmuxNotificationIfNeeded()
    
  }
                   
  @objc func _UISceneDidEnterBackgroundNotification(_ n: Notification) {
    guard let scene = n.object as? UIWindowScene,
          view.window?.windowScene === scene
    else {
      return
    }
    
    let currentTerm = currentTerm()
    
    forEachActive { ctrl in
      if ctrl.viewIsLoaded && ctrl !== currentTerm {
        _ = ctrl.removeFromContainer()
      }
    }
  }
  
  @objc func _UISceneWillEnterForegroundNotification(_ n: Notification) {
    guard let scene = n.object as? UIWindowScene
    else {
      return
    }
    
    #if targetEnvironment(macCatalyst)
    
    if scene.session.persistentIdentifier.hasPrefix("NSMenuBarScene") {
      KBTracker.shared.input?.reportStateWithSelection()
      return
    }
    
    #endif
    
    if scene.session.role == .windowExternalDisplayNonInteractive,
      let sharedWindow = ShadowWindow.shared,
       sharedWindow === view.window,
       let ctrl = sharedWindow.spaceController.currentTerm() {
      
      ctrl.resumeIfNeeded()
    }
    
    guard view.window?.windowScene === scene
    else {
      return
    }
    
    forEachActive { ctrl in
      if ctrl.viewIsLoaded {
        ctrl.placeToContainer()
      }
    }
   
    currentTerm()?.resumeIfNeeded()
   
    #if targetEnvironment(macCatalyst)
    #else
    if view.window === KBTracker.shared.input?.window {
      KBTracker.shared.input?.reportStateWithSelection()
    }
    #endif
  }
    
  @objc func _didBecomeKeyWindow() {
    guard
      presentedViewController == nil,
      let window = view.window,
      window.isKeyWindow
    else {
      currentDevice?.blur()
      return
    }
    
    _focusOnShell()
  }
  
  func _createShell(
    userActivity: NSUserActivity?,
    animated: Bool,
    completion: ((Bool) -> Void)? = nil)
  {
    let term = TermController(sceneRole: sceneRole)
    term.delegate = self
    term.userActivity = userActivity
    term.bgColor = view.backgroundColor ?? .black
    
    if let currentKey = _currentKey,
      let idx = _viewportsKeys.firstIndex(of: currentKey)?.advanced(by: 1) {
      _viewportsKeys.insert(term.meta.key, at: idx)
    } else {
      _viewportsKeys.insert(term.meta.key, at: _viewportsKeys.count)
    }
    
    SessionRegistry.shared.track(session: term)
    
    _currentKey = term.meta.key
    
    _viewportsController.setViewControllers([term], direction: .forward, animated: animated) { (didComplete) in
      self._displayHUD()
      self._attachInputToCurrentTerm()
      completion?(didComplete)
    }
  }
  
  func _closeCurrentSpace() {
    currentTerm()?.terminate()
    _removeCurrentSpace()
  }
  
  private func _removeCurrentSpace(attachInput: Bool = true) {
    guard
      let currentKey = _currentKey,
      let idx = _viewportsKeys.firstIndex(of: currentKey)
    else {
      return
    }
    currentTerm()?.delegate = nil
    SessionRegistry.shared.remove(forKey: currentKey)
    _viewportsKeys.remove(at: idx)
    if _viewportsKeys.isEmpty {
      _createShell(userActivity: nil, animated: true)
      return
    }

    let direction: UIPageViewController.NavigationDirection
    let term: TermController
    
    if idx < _viewportsKeys.endIndex {
      direction = .forward
      term = SessionRegistry.shared[_viewportsKeys[idx]]
    } else {
      direction = .reverse
      term = SessionRegistry.shared[_viewportsKeys[idx - 1]]
    }
    term.bgColor = view.backgroundColor ?? .black
    
    self._currentKey = term.meta.key
    
    _spaceControllerAnimating = true
    _viewportsController.setViewControllers([term], direction: direction, animated: true) { (didComplete) in
      self._displayHUD()
      if attachInput {
        self._attachInputToCurrentTerm()
      }
      self._spaceControllerAnimating = false
    }
  }
  
  @objc func _focusOnShell() {
    _attachInputToCurrentTerm()
  }

  private func _presentInitialTmuxPaneInboxIfNeeded() {
    guard
      sceneRole == .windowApplication,
      !_didPresentInitialTmuxPaneInbox,
      presentedViewController == nil
    else {
      return
    }
    _didPresentInitialTmuxPaneInbox = true
    _presentTmuxPaneInbox(animated: false)
  }

  private func _presentTmuxPaneInbox(animated: Bool) {
    guard !_isPresentingTmuxPaneInbox else {
      return
    }

    let inbox = TmuxPaneInboxViewController(
      onPaneSelected: { [weak self] request in
        guard let self else {
          return
        }
        self._dismissTmuxPaneInboxIfNeeded {
          self._openTmuxPane(
            hostAlias: request.hostAlias,
            sessionName: request.sessionName,
            paneTarget: request.paneTarget
          )
        }
      },
      onCreateTerminal: { [weak self] in
        guard let self else {
          return
        }
        self._dismissTmuxPaneInboxIfNeeded {
          self._createShell(userActivity: nil, animated: true)
          self._focusOnShell()
        }
      },
      onUpgradeHost: { [weak self] hostAlias in
        guard let self else {
          return
        }
        self._dismissTmuxPaneInboxIfNeeded {
          self._upgradeTmuxHost(hostAlias: hostAlias)
        }
      },
      onFixRuntimeHost: { [weak self] hostAlias in
        guard let self else {
          return
        }
        self._dismissTmuxPaneInboxIfNeeded {
          self._presentTmuxRuntimeFixGuide(hostAlias: hostAlias, issue: nil)
        }
      }
    )
    let nav = UINavigationController(rootViewController: inbox)
    nav.modalPresentationStyle = .fullScreen
    present(nav, animated: animated)
  }

  private var _isPresentingTmuxPaneInbox: Bool {
    guard let nav = presentedViewController as? UINavigationController else {
      return false
    }
    return nav.viewControllers.first is TmuxPaneInboxViewController
  }

  private func _dismissTmuxPaneInboxIfNeeded(completion: @escaping () -> Void) {
    guard _isPresentingTmuxPaneInbox else {
      completion()
      return
    }
    dismiss(animated: true, completion: completion)
  }
  
  @objc private func _termViewIsReady(n: Notification) {
    
    guard let term = _termViewToFocus,
          term == (n.object as? TermView)
    else {
      return
    }
    
    _termViewToFocus = nil
    _attachInputToCurrentTerm()
  }
  
  @objc private func _termViewBrowserIsReady(n: Notification) {
    _attachInputToCurrentTerm();
  }
  
  private func _attachInputToCurrentTerm() {
    guard
      let device = currentDevice,
      let deviceView = device.view
    else {
      return
    }
    
    _termViewToFocus = nil
    
    guard deviceView.isReady else {
      _termViewToFocus = deviceView
      return
    }
    
    let input = KBTracker.shared.input
    
    if deviceView.browserView != nil {
      KBTracker.shared.attach(input: deviceView.browserView)
      device.attachInput(deviceView.browserView)
      _ = deviceView.browserView.becomeFirstResponder()
      if input != KBTracker.shared.input {
        input?.reportFocus(false)
      }
      return
    }

    
    KBTracker.shared.attach(input: deviceView.webView)
    device.attachInput(deviceView.webView)
    deviceView.webView.reportFocus(true)
    device.focus()
//    _attachHUD()
    if input != KBTracker.shared.input {
      input?.reportFocus(false)
    }
  }
  
  var currentDevice: TermDevice? {
    currentTerm()?.termDevice
  }
  
  private func _displayHUD() {
    _hud?.hide(animated: false)
    
    guard let term = currentTerm() else {
      return
    }
    
    let params = term.sessionParams
    
    if let bgColor = term.view.backgroundColor, bgColor != .clear {
      view.backgroundColor = bgColor
      _viewportsController.view.backgroundColor = bgColor
      view.window?.backgroundColor = bgColor
    }
    
    let hud = MBProgressHUD.showAdded(to: _overlay, animated: _hud == nil)
    
    hud.mode = .customView
    hud.bezelView.color = .darkGray
    hud.contentColor = .white
    hud.isUserInteractionEnabled = false
    hud.alpha = 0.6
    
    let pages = UIPageControl()
    pages.currentPageIndicatorTintColor = .blinkHudDot
    pages.numberOfPages = _viewportsKeys.count
    let pageNum = _viewportsKeys.firstIndex(of: term.meta.key)
    pages.currentPage = pageNum ?? NSNotFound
    
    hud.customView = pages
    
    let title = term.title?.isEmpty == true ? nil : term.title
    
    var sceneTitle = "[\(pageNum == nil ? 1 : pageNum! + 1) of \(_viewportsKeys.count)] \(title ?? "blink")"
    
    if params.rows == 0 && params.cols == 0 {
      hud.label.numberOfLines = 1
      hud.label.text = title ?? "blink"
    } else {
      let geometry = "\(params.cols)×\(params.rows)"
      hud.label.numberOfLines = 2
      hud.label.text = "\(title ?? "blink")\n\(geometry)"
      
      sceneTitle += " | " + geometry
    }
    
    _hud = hud
    hud.hide(animated: true, afterDelay: 1)
    
    view.window?.windowScene?.title = sceneTitle
    self.view.setNeedsLayout()
  }
  
}

// MARK: UIStateRestorable
extension SpaceController: UIStateRestorable {
  func restore(withState state: UIState) {
    _viewportsKeys = state.keys
    _currentKey = state.currentKey
    if let bgColor = UIColor(codableColor: state.bgColor) {
      view.backgroundColor = bgColor
    }
  }
  
  func dumpUIState() -> UIState {
    return UIState(keys: _viewportsKeys,
            currentKey: _currentKey,
            bgColor: CodableColor(uiColor: view.backgroundColor)
    )
  }
  
  @objc static func onDidDiscardSceneSessions(_ sessions: Set<UISceneSession>) {
    let registry = SessionRegistry.shared
    sessions.forEach { session in
      guard
        let uiState = UIState(userActivity: session.stateRestorationActivity)
      else {
        return
      }
      
      uiState.keys.forEach { registry.remove(forKey: $0) }
    }
  }

  @objc static func handleTmuxRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard let request = _tmuxNotificationRequest(from: userInfo) else {
      return false
    }

    if
      let scene = UIApplication.shared.connectedScenes.activeAppScene(),
      let sceneDelegate = scene.delegate as? SceneDelegate
    {
      DispatchQueue.main.async {
        sceneDelegate.spaceController.openTmuxPane(
          hostAlias: request.hostAlias,
          sessionName: request.sessionName,
          paneTarget: request.paneTarget
        )
      }
      return true
    }

    _pendingTmuxRequest = request

    NotificationCenter.default.post(
      name: .BLKOpenTmuxPane,
      object: nil,
      userInfo: [
        "hostAlias": request.hostAlias,
        "sessionName": request.sessionName ?? "",
        "paneTarget": request.paneTarget
      ]
    )
    return true
  }

  fileprivate static func _tmuxNotificationRequest(from userInfo: [AnyHashable: Any]) -> TmuxNotificationRequest? {
    TmuxNotificationPayloadResolver.resolve(userInfo)
  }
}

// MARK: UIPageViewControllerDelegate
extension SpaceController: UIPageViewControllerDelegate {
  public func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool) {
    guard completed else {
      return
    }
    
    guard let termController = pageViewController.viewControllers?.first as? TermController
    else {
      return
    }
    termController.resumeIfNeeded()
    _currentKey = termController.meta.key
    _displayHUD()
    _attachInputToCurrentTerm()
    
  }
}

// MARK: UIPageViewControllerDataSource
extension SpaceController: UIPageViewControllerDataSource {
  private func _controller(controller: UIViewController, advancedBy: Int) -> UIViewController? {
    guard let ctrl = controller as? TermController else {
      return nil
    }
    let key = ctrl.meta.key
    guard
      let idx = _viewportsKeys.firstIndex(of: key)?.advanced(by: advancedBy),
      _viewportsKeys.indices.contains(idx)
    else {
      return nil
    }
    
    let newKey = _viewportsKeys[idx]
    let newCtrl: TermController = SessionRegistry.shared[newKey]
    newCtrl.delegate = self
    newCtrl.bgColor = view.backgroundColor ?? .black
    return newCtrl
  }
  
  public func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
    _controller(controller: viewController, advancedBy: -1)
  }
  
  public func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
    _controller(controller: viewController, advancedBy: 1)
  }
  
}

// MARK: TermControlDelegate
extension SpaceController: TermControlDelegate {
  
  func terminalHangup(control: TermController) {
    if currentTerm() == control {
      _closeCurrentSpace()
    }
  }
  
  func terminalDidResize(control: TermController) {
    if currentTerm() == control {
      _displayHUD()
    }
  }
}

// MARK: General tunning

extension SpaceController {
  public override var prefersStatusBarHidden: Bool { true }
  public override var prefersHomeIndicatorAutoHidden: Bool { true }
}


// MARK: Commands

extension SpaceController {
  
  var foregroundActive: Bool {
    view.window?.windowScene?.activationState == UIScene.ActivationState.foregroundActive
  }
  
  public override var keyCommands: [UIKeyCommand]? {
    guard
      let input = KBTracker.shared.input,
      foregroundActive
    else {
      return nil
    }
    
    if let keyCode = stuckKeyCode {
      return [UIKeyCommand(input: "", modifierFlags: keyCode.modifierFlags, action: #selector(onStuckOpCommand))]
    }
    
    return input.blinkKeyCommands
  }
  
  @objc func onStuckOpCommand() {
    stuckKeyCode = nil
    presentedViewController?.dismiss(animated: true)
    _focusOnShell()
  }
  
  @objc func _onBlinkCommand(_ cmd: BlinkCommand) {
    guard foregroundActive,
          let input = currentDevice?.view?.browserView ?? currentDevice?.view?.webView else {
      return
    }
    
//    input.reportStateReset()
    switch cmd.bindingAction {
    case .hex(let hex, stringInput: _, comment: _):
      input.reportHex(hex)
    case .press(let keyCode, mods: let mods):
      input.reportPress(UIKeyModifierFlags(rawValue: mods), keyId: keyCode.id)
    case .command(let c):
      _onCommand(c)
    default:
      break;
    }
  }
  
  @objc func _onShortcut(_ event: UICommand) {
    guard
      let propertyList = event.propertyList as? [String:String],
      let cmd = Command(rawValue: propertyList["Command"]!)
    else {
      return
    }
    _onCommand(cmd)
  }
  
  func _onCommand(_ cmd: Command) {
    guard foregroundActive else {
      return
    }

    switch cmd {
    case .configShow: showConfigAction()
    case .snippetsShow: showSnippetsAction()
    case .toggleQuickActions: toggleQuickActionsAction()
    case .toggleGeoTrack: toggleGeoTrack()
    case .tab1: _moveToShell(idx: 0)
    case .tab2: _moveToShell(idx: 1)
    case .tab3: _moveToShell(idx: 2)
    case .tab4: _moveToShell(idx: 3)
    case .tab5: _moveToShell(idx: 4)
    case .tab6: _moveToShell(idx: 5)
    case .tab7: _moveToShell(idx: 6)
    case .tab8: _moveToShell(idx: 7)
    case .tab9: _moveToShell(idx: 8)
    case .tab10: _moveToShell(idx: 9)
    case .tab11: _moveToShell(idx: 10)
    case .tab12: _moveToShell(idx: 11)
    case .tabClose: _closeCurrentSpace()
    case .tabMoveToOtherWindow: _moveToOtherWindowAction()
    case .toggleKeyCast: _toggleKeyCast()
    case .tabNew: newShellAction()
    case .tabNext: _advanceShell(by: 1)
    case .tabPrev: _advanceShell(by: -1)
    case .tabNextCycling: _advanceShellCycling(by: 1)
    case .tabPrevCycling: _advanceShellCycling(by: -1)
    case .tabLast: _moveToLastShell()
    case .windowClose: _closeWindowAction()
    case .windowFocusOther: _focusOtherWindowAction()
    case .windowNew: _newWindowAction()
    case .clipboardCopy: KBTracker.shared.input?.copy(self)
    case .clipboardPaste: KBTracker.shared.input?.paste(self)
    case .selectionGoogle: KBTracker.shared.input?.googleSelection(self)
    case .selectionStackOverflow: KBTracker.shared.input?.soSelection(self)
    case .selectionShare: KBTracker.shared.input?.shareSelection(self)
    case .zoomIn: currentTerm()?.termDevice.view?.increaseFontSize()
    case .zoomOut: currentTerm()?.termDevice.view?.decreaseFontSize()
    case .zoomReset: currentTerm()?.termDevice.view?.resetFontSize()
    
    }
  }
  
  @objc func focusOnShellAction() {
    KBTracker.shared.input?.reset()
    _focusOnShell()
  }
  
  @objc public func scaleWithPich(_ pinch: UIPinchGestureRecognizer) {
    currentTerm()?.scaleWithPich(pinch)
  }
  
  @objc func newShellAction() {
    _dismissTmuxPaneInboxIfNeeded { [weak self] in
      self?._createShell(userActivity: nil, animated: true)
    }
  }
  
  @objc func closeShellAction() {
    _closeCurrentSpace()
  }

  private func _focusOtherWindowAction() {
    
    var sessions = _activeSessions()
    
    guard
      sessions.count > 1,
      let session = view.window?.windowScene?.session,
      let idx = sessions.firstIndex(of: session)?.advanced(by: 1)
    else  {
      if currentTerm()?.termDevice.view?.isFocused() == true {
        _ = currentTerm()?.termDevice.view?.webView?.resignFirstResponder()
      } else {
        _focusOnShell()
      }
      return
    }

    if
      let shadowWindow = ShadowWindow.shared,
      let shadowScene = shadowWindow.windowScene,
      let window = self.view.window,
      shadowScene == window.windowScene,
      shadowWindow !== window {
      shadowWindow.makeKeyAndVisible()
      shadowWindow.spaceController._focusOnShell()
      return
    }
          
    sessions = sessions.filter { $0.role != .windowExternalDisplayNonInteractive }
    
    let nextSession: UISceneSession
    if idx < sessions.endIndex {
      nextSession = sessions[idx]
    } else {
      nextSession = sessions[0]
    }
    
    if
      let scene = nextSession.scene as? UIWindowScene,
      let delegate = scene.delegate as? SceneDelegate,
      let window = delegate.window,
      let spaceCtrl = window.rootViewController as? SpaceController {

      if window.isKeyWindow {
        spaceCtrl._focusOnShell()
      } else {
        window.makeKeyAndVisible()
      }
    } else {
      UIApplication.shared.requestSceneSessionActivation(nextSession, userActivity: nil, options: nil, errorHandler: nil)
    }
  }
  
  private func _moveToOtherWindowAction() {
    var sessions = _activeSessions()
    
    guard
      sessions.count > 1,
      let session = view.window?.windowScene?.session,
      let idx = sessions.firstIndex(of: session)?.advanced(by: 1),
      let term = currentTerm(),
      _spaceControllerAnimating == false
    else  {
        return
    }
    
    if
      let shadowWindow = ShadowWindow.shared,
      let shadowScene = shadowWindow.windowScene,
      let window = self.view.window,
      shadowScene == window.windowScene,
      shadowWindow !== window {
      
      _removeCurrentSpace(attachInput: false)
      shadowWindow.makeKey()
      shadowWindow.spaceController._addTerm(term: term)
      return
    }
          
    sessions = sessions.filter { $0.role != .windowExternalDisplayNonInteractive }
    
    let nextSession: UISceneSession
    if idx < sessions.endIndex {
      nextSession = sessions[idx]
    } else {
      nextSession = sessions[0]
    }
    
    guard
      let nextScene = nextSession.scene as? UIWindowScene,
      let delegate = nextScene.delegate as? SceneDelegate,
      let nextWindow = delegate.window,
      let nextSpaceCtrl = nextWindow.rootViewController as? SpaceController,
      nextSpaceCtrl._spaceControllerAnimating == false
    else {
      return
    }
    

    _removeCurrentSpace(attachInput: false)
    nextSpaceCtrl._addTerm(term: term)
    nextWindow.makeKey()
  }
  
  func _toggleKeyCast() {
    BLKDefaults.setKeycasts(!BLKDefaults.isKeyCastsOn())
    BLKDefaults.save()
  }
  
  func _activeSessions() -> [UISceneSession] {
    Array(UIApplication.shared.openSessions)
      .filter({ $0.scene?.activationState == .foregroundActive || $0.scene?.activationState == .foregroundInactive })
      .sorted(by: { $0.persistentIdentifier < $1.persistentIdentifier })
  }
  
  @objc func _newWindowAction() {
    let options = UIWindowScene.ActivationRequestOptions()
    options.requestingScene = self.view.window?.windowScene
    
    UIApplication
      .shared
      .requestSceneSessionActivation(nil,
                                     userActivity: nil,
                                     options: options,
                                     errorHandler: nil)
  }
  
  @objc func _closeWindowAction() {
    guard
      let session = view.window?.windowScene?.session,
      session.role == .windowApplication // Can't close windows on external monitor
    else {
      return
    }
    
    // try to focus on other session before closing
    _focusOtherWindowAction()
    
    UIApplication
      .shared
      .requestSceneSessionDestruction(session,
                                      options: nil,
                                      errorHandler: nil)
  }
  
  @objc func showConfigAction() {
    if let shadowWindow = ShadowWindow.shared,
      view.window == shadowWindow {
      
      _ = currentDevice?.view?.webView.resignFirstResponder()
      
      let spCtrl = shadowWindow.windowScene?.windows.first?.rootViewController as? SpaceController
      spCtrl?.showConfigAction()
      
      return
    }
    
    DispatchQueue.main.async {
      _ = KBTracker.shared.input?.resignFirstResponder()
      let navCtrl = UINavigationController()
      navCtrl.navigationBar.prefersLargeTitles = true
      let s = SettingsHostingController.createSettings(nav: navCtrl, onDismiss: {
        [weak self] in self?._focusOnShell()
      })
      navCtrl.setViewControllers([s], animated: false)
      self.present(navCtrl, animated: true, completion: nil)
    }
  }
  
//  @objc func showWalkthroughAction() {
//    if self.view.window == ShadowWindow.shared {
//      return
//    }
//    DispatchQueue.main.async {
//      _ = KBTracker.shared.input?.resignFirstResponder()
//      let ctrl = UIHostingController(rootView: WalkthroughView(urlHandler: blink_openurl,
//                                                               dismissHandler: { self.dismiss(animated: true) })
//      )
//      ctrl.modalPresentationStyle = .formSheet
//      self.present(ctrl, animated: false)
//    }
//  }
  
  @objc func showSnippetsAction() {
    if let _ = _snippetsVC {
      return
    }
    self.presentSnippetsController()
    if let _ = self._interactiveSpaceController()._blinkMenu {
      self.toggleQuickActionsAction()
    }
  }
  
  private func _toggleQuickActionActionWith(receiver: SpaceController) {
    if let menu = _blinkMenu {
      _blinkMenu = nil
      UIView.animate(withDuration: 0.15) {
        menu.alpha = 0
      } completion: { _ in
        menu.removeFromSuperview()
      }
    } else {
      let menu = BlinkMenu()
      self.view.addSubview(menu.tapToCloseView)
      
      var ids: [BlinkActionID] = []
      ids.append(contentsOf:  [.snippets, .tabClose, .tabCreate, .tmux])
      
      if DeviceInfo.shared().hasCorners {
        ids.append(contentsOf:  [.layoutMenu])
      }
      ids.append(contentsOf:  [.toggleLayoutLock, .toggleGeoTrack])
      menu.delegate = receiver;
      menu.build(withIDs: ids, andAppearance: [:])
      _blinkMenu = menu
      self.view.addSubview(menu)
      let size = self.view.frame.size;
      let menuSize = menu.layout(for: size)
      
      let finalMenuFrame = CGRect(x: size.width * 0.5 - menuSize.width * 0.5, y: _overlay.frame.maxY - menuSize.height - 20, width: menuSize.width, height: menuSize.height)
      
      menu.frame = CGRect(origin: CGPoint(x: finalMenuFrame.minX, y: _overlay.frame.maxY + 10), size: finalMenuFrame.size);
      
      UIView.animate(withDuration: 0.25) {
        menu.frame = finalMenuFrame
      }
    }
  }
  
  func _interactiveSpaceController() -> SpaceController {
    if let shadowWin = ShadowWindow.shared,
       self.view.window == shadowWin,
       let mainScreenSession = _activeSessions()
          .first(where: {$0.role == .windowApplication }),
       let delegate = mainScreenSession.scene?.delegate as? SceneDelegate
    {
      return delegate.spaceController
    }
    return self
  }
  
  @objc func toggleQuickActionsAction() {
    _interactiveSpaceController()
      ._toggleQuickActionActionWith(receiver: self)
  }

  @objc func showTmuxModeAction() {
    let receiver = _interactiveSpaceController()
    if receiver._blinkMenu != nil {
      receiver.toggleQuickActionsAction()
    }
    receiver._presentTmuxHostPicker()
  }

  private func _presentTmuxHostPicker() {
    let allHosts = BKHosts.allHosts() ?? []
    let hosts = allHosts.filter { host in
      guard let resolved = BKHosts.tmuxResolvedBaseURL(for: host)?.blink_trimmed else {
        return false
      }
      return !resolved.isEmpty
    }.sorted { ($0.host ?? "") < ($1.host ?? "") }

    guard !hosts.isEmpty else {
      if allHosts.contains(where: { BKHosts.tmuxEndpointOverrideRequiresHTTPS(for: $0) }) {
        showAlert(msg: "One or more tmux hosts still use insecure endpoint overrides (http://). Edit host settings and migrate to HTTPS.")
        return
      }
      if allHosts.contains(where: { BKHosts.tmuxEndpointOverrideIsInvalid(for: $0) }) {
        showAlert(msg: "One or more tmux hosts have invalid endpoint overrides. Edit host settings and use a valid https:// endpoint.")
        return
      }
      showAlert(msg: "No host has a valid tmux endpoint. Edit a host in Settings > Hosts > SSH first.")
      return
    }

    let alert = UIAlertController(title: "Tmux Mode", message: "Select host", preferredStyle: .actionSheet)
    for host in hosts {
      let alias = host.host ?? "(unknown)"
      let title = "\(alias)  (\(host.hostName ?? alias))"
      alert.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
        self?._presentTmuxSessionPicker(for: host)
      }))
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    _presentSheetAlert(alert)
  }

  private func _presentTmuxSessionPicker(for host: BKHosts) {
    guard let hostAlias = host.host, !hostAlias.blink_trimmed.isEmpty else {
      showAlert(msg: "This host has an empty alias.")
      return
    }

    let hud = MBProgressHUD.showAdded(to: view, animated: true)
    hud.label.text = "Loading tmux sessions…"
    Task { [weak self] in
      defer {
        DispatchQueue.main.async {
          hud.hide(animated: true)
        }
      }

      do {
        let sessions = try await TmuxControlPlaneClient.listSessions(for: host)
        await MainActor.run {
          self?._showTmuxSessionPicker(hostAlias: hostAlias, sessions: sessions)
        }
      } catch let controlError as TmuxControlError {
        await MainActor.run {
          self?.showAlert(msg: controlError.localizedDescription)
        }
      } catch {
        await MainActor.run {
          self?.showAlert(msg: error.localizedDescription)
        }
      }
    }
  }

  private func _showTmuxSessionPicker(hostAlias: String, sessions: [TmuxControlSession]) {
    guard !sessions.isEmpty else {
      showAlert(msg: "No tmux sessions found on \(hostAlias).")
      return
    }

    let alert = UIAlertController(title: "Tmux Sessions", message: "Select session", preferredStyle: .actionSheet)
    let showAttachedIndicator = BLKDefaults.isTmuxSessionAttachedVisible()
    for session in sessions.sorted(by: { $0.name < $1.name }) {
      let title = tmuxSessionPickerTitle(
        name: session.name,
        attached: session.attached,
        showAttachedIndicator: showAttachedIndicator
      )
      alert.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
        self?._showTmuxPanePicker(hostAlias: hostAlias, session: session)
      }))
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    _presentSheetAlert(alert)
  }

  private func _showTmuxPanePicker(hostAlias: String, session: TmuxControlSession) {
    let panes = session.windows
      .sorted(by: { $0.index < $1.index })
      .flatMap { window in
        window.panes.sorted(by: { $0.index < $1.index }).map { pane in
          (window: window, pane: pane)
        }
      }

    guard !panes.isEmpty else {
      showAlert(msg: "Session '\(session.name)' has no panes.")
      return
    }

    let alert = UIAlertController(title: "Session: \(session.name)", message: "Tap a pane to enter", preferredStyle: .actionSheet)
    let showPaneStar = BLKDefaults.isTmuxPaneStarVisible()
    for entry in panes {
      let title = tmuxPanePickerTitle(
        windowName: entry.window.name,
        paneIndex: entry.pane.index,
        currentPath: entry.pane.currentPath,
        active: entry.pane.active,
        showActiveStar: showPaneStar
      )
      alert.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
        self?._openTmuxPane(hostAlias: hostAlias, sessionName: session.name, paneTarget: entry.pane.target)
      }))
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    _presentSheetAlert(alert)
  }

  private func _presentSheetAlert(_ alert: UIAlertController) {
    if let popover = alert.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    present(alert, animated: true)
  }

  @objc func openTmuxPane(hostAlias: String, sessionName: String?, paneTarget: String) {
    _interactiveSpaceController()._openTmuxPane(hostAlias: hostAlias, sessionName: sessionName, paneTarget: paneTarget)
  }

  @objc func openShellAndRunCommand(_ command: String) {
    _interactiveSpaceController()._openShellAndRunCommand(command, skipHistoryRecord: false)
  }

  private func _openTmuxPane(hostAlias: String, sessionName: String?, paneTarget: String) {
    let cleanHost = hostAlias.blink_trimmed
    guard !cleanHost.isEmpty else {
      showAlert(msg: "Missing host alias in tmux notification.")
      return
    }

    let cleanPane = paneTarget.blink_trimmed
    guard !cleanPane.isEmpty else {
      showAlert(msg: "Missing pane target.")
      return
    }

    let inferredSession = cleanPane.components(separatedBy: ":").first
    let cleanSession = sessionName?.blink_trimmed.isEmpty == false ? sessionName!.blink_trimmed : (inferredSession ?? "")
    guard !cleanSession.isEmpty else {
      showAlert(msg: "Missing session name for pane target \(cleanPane).")
      return
    }

    _markTmuxPaneReadIfPossible(hostAlias: cleanHost, paneTarget: cleanPane)

    let request = TmuxNotificationRequest(hostAlias: cleanHost, sessionName: cleanSession, paneTarget: cleanPane)
    let requestID = TmuxPaneLaunchRequestStore.shared.register(request: request)
    _openShellAndRunCommand("tmux-pane-bridge --request-id \(requestID)", skipHistoryRecord: true)
  }

  private func _markTmuxPaneReadIfPossible(hostAlias: String, paneTarget: String) {
    let cleanHostAlias = hostAlias.blink_trimmed
    let cleanPaneTarget = paneTarget.blink_trimmed
    guard !cleanHostAlias.isEmpty, !cleanPaneTarget.isEmpty else {
      return
    }

    guard let host = (BKHosts.allHosts() ?? []).first(where: {
      (($0.host ?? "").blink_trimmed).caseInsensitiveCompare(cleanHostAlias) == .orderedSame
    }) else {
      return
    }

    Task {
      do {
        try await TmuxControlPlaneClient.markPaneRead(for: host, target: cleanPaneTarget)
      } catch {
        debugPrint("Failed to mark tmux pane as read:", error.localizedDescription)
      }
    }
  }

  private func _tmuxHost(for alias: String) -> BKHosts? {
    let cleanAlias = alias.blink_trimmed
    guard !cleanAlias.isEmpty else {
      return nil
    }

    return (BKHosts.allHosts() ?? []).first(where: {
      (($0.host ?? "").blink_trimmed).caseInsensitiveCompare(cleanAlias) == .orderedSame
        || (($0.hostName ?? "").blink_trimmed).caseInsensitiveCompare(cleanAlias) == .orderedSame
    })
  }

  private func _presentUpgradeFailureAlert(_ message: String) {
    let alert = UIAlertController(title: "Upgrade Failed", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak self] _ in
      self?._presentTmuxPaneInbox(animated: true)
    }))
    present(alert, animated: true)
  }

  private func _presentUpgradeCompletedButPaneInboxNotReadyAlert(hostAlias: String, issue: String) {
    let cleanAlias = hostAlias.blink_trimmed
    let issueText = issue.blink_trimmed
    let message = tmuxUpgradeCompletedButPaneInboxNotReadyMessage(
      hostAlias: cleanAlias,
      issue: issueText
    )

    let alert = UIAlertController(
      title: "Upgrade Completed",
      message: message,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Fix Runtime", style: .default, handler: { [weak self] _ in
      self?._presentTmuxRuntimeFixGuide(hostAlias: cleanAlias, issue: issueText)
    }))
    alert.addAction(UIAlertAction(title: "Back to Chats", style: .cancel, handler: { [weak self] _ in
      self?._presentTmuxPaneInbox(animated: true)
    }))
    present(alert, animated: true)
  }

  private func _presentTmuxRuntimeFixGuide(hostAlias: String, issue: String?) {
    let cleanAlias = hostAlias.blink_trimmed
    var message = "Host '\(cleanAlias)' requires tmux runtime upgrade for pane inbox.\n\nSuggested checks:\n- tmux -V\n- tmux list-panes -a -F '#{pane_activity}|#{pane_current_command}'\n\nAfter upgrading tmux:\n1. Restart tmux server.\n2. Retry from Chats."
    if let issue, !issue.blink_trimmed.isEmpty {
      message += "\n\nCurrent issue:\n\(issue.blink_trimmed)"
    }

    let alert = UIAlertController(title: "Fix tmux Runtime", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Open Terminal", style: .default, handler: { [weak self] _ in
      self?._openShellAndRunCommand("ssh \(cleanAlias)", skipHistoryRecord: true)
    }))
    alert.addAction(UIAlertAction(title: "Back to Chats", style: .cancel, handler: { [weak self] _ in
      self?._presentTmuxPaneInbox(animated: true)
    }))
    present(alert, animated: true)
  }

  private func _upgradeTmuxHost(hostAlias: String) {
    let cleanAlias = hostAlias.blink_trimmed
    guard !cleanAlias.isEmpty else {
      showAlert(msg: "Missing host alias for upgrade.")
      _presentTmuxPaneInbox(animated: true)
      return
    }
    guard let host = _tmuxHost(for: cleanAlias) else {
      showAlert(msg: "Host '\(cleanAlias)' was not found. Check Settings > Hosts > SSH.")
      _presentTmuxPaneInbox(animated: true)
      return
    }

    func runUpgrade(using termDevice: TermDevice) {
      let hud = MBProgressHUD.showAdded(to: view, animated: true)
      hud.mode = .indeterminate
      hud.label.text = "Upgrading tmuxd…"
      hud.detailsLabel.text = "Preparing remote upgrade for \(cleanAlias)"
      hud.detailsLabel.numberOfLines = 0

      Task { @MainActor [weak self] in
        guard let self else {
          return
        }

        defer {
          hud.hide(animated: true)
        }

        do {
          try await TmuxSSHOnboardingService.upgradeTmuxdOnly(
            hostAlias: cleanAlias,
            termDevice: termDevice,
            onProgress: { status in
              Task { @MainActor in
                hud.detailsLabel.text = status
              }
            }
          )
        } catch {
          self._presentUpgradeFailureAlert(error.localizedDescription)
          return
        }

        do {
          _ = try await TmuxControlPlaneClient.listSessions(for: host)
          self._presentTmuxPaneInbox(animated: true)
        } catch {
          self._presentUpgradeCompletedButPaneInboxNotReadyAlert(
            hostAlias: cleanAlias,
            issue: error.localizedDescription
          )
        }
      }
    }

    if let termDevice = currentTerm()?.termDevice {
      runUpgrade(using: termDevice)
      return
    }

    _createShell(userActivity: nil, animated: true) { [weak self] _ in
      guard let self else {
        return
      }
      self._focusOnShell()
      guard let termDevice = self.currentTerm()?.termDevice else {
        self._presentUpgradeFailureAlert("Cannot create terminal context required for SSH upgrade. Open a terminal and retry.")
        return
      }
      runUpgrade(using: termDevice)
    }
  }

  private func _presentTmuxPaneDetail(host: BKHosts, request: TmuxNotificationRequest) {
    let paneController = TmuxPaneDetailViewController(host: host, request: request)
    let nav = UINavigationController(rootViewController: paneController)
    if #available(iOS 15.0, *) {
      nav.modalPresentationStyle = .formSheet
    } else {
      nav.modalPresentationStyle = .fullScreen
    }
    present(nav, animated: true)
  }

  private func _openShellAndRunCommand(_ command: String, skipHistoryRecord: Bool) {
    let cleanCommand = command.blink_trimmed
    guard !cleanCommand.isEmpty else {
      showAlert(msg: "Command is empty.")
      return
    }

    _dismissTmuxPaneInboxIfNeeded { [weak self] in
      guard let self else {
        return
      }
      self._createShell(userActivity: nil, animated: true) { [weak self] _ in
        guard let self,
              let term = self.currentTerm()
        else {
          return
        }
        term.enqueueProgrammaticCommand(cleanCommand, skipHistoryRecord: skipHistoryRecord)
      }
    }
  }

  @objc private func _openTmuxPaneFromNotification(_ n: Notification) {
    guard
      let userInfo = n.userInfo,
      let request = Self._tmuxNotificationRequest(from: userInfo)
    else {
      return
    }
    _openTmuxPane(hostAlias: request.hostAlias, sessionName: request.sessionName, paneTarget: request.paneTarget)
  }

  private func _drainPendingTmuxNotificationIfNeeded() {
    guard let request = Self._pendingTmuxRequest else {
      return
    }
    Self._pendingTmuxRequest = nil
    _openTmuxPane(hostAlias: request.hostAlias, sessionName: request.sessionName, paneTarget: request.paneTarget)
  }
  
  @objc func toggleGeoTrack() {
    if GeoManager.shared().traking {
      GeoManager.shared().stop()
      return
    }

    let manager = CLLocationManager()
    let status = manager.authorizationStatus
    
    switch status  {
    case .authorizedAlways, .authorizedWhenInUse: break
    case .restricted:
      showAlert(msg: "Geo services are restricted on this device.")
      return
    case .denied:
      showAlert(msg: "Please allow Blink.app to use geo in Settings.app.")
      return
    case .notDetermined:
      GeoManager.shared().authorize()
      return
    @unknown default:
      return
    }
    
    GeoManager.shared().start()
  }
  
  @objc func _geoTrackStateChanged() {
    self.view.setNeedsLayout()
  }
  
  @objc func showWhatsNewAction() {
    if let shadowWindow = ShadowWindow.shared,
      view.window == shadowWindow {
      
      _ = currentDevice?.view?.webView.resignFirstResponder()
      
      let spCtrl = shadowWindow.windowScene?.windows.first?.rootViewController as? SpaceController
      spCtrl?.showWhatsNewAction()
      
      return
    }
    
    DispatchQueue.main.async {
      _ = KBTracker.shared.input?.resignFirstResponder();
      
      // Reset version when opening.
      WhatsNewInfo.setNewVersion()
      let root = UIHostingController(rootView: GridView(rowsProvider: RowsViewModel(baseURL: XCConfig.infoPlistWhatsNewURL())))
      self.present(root, animated: true, completion: nil)
      
    }
  }
  
  private func _addTerm(term: TermController, animated: Bool = true) {
    SessionRegistry.shared.track(session: term)
    term.delegate = self
    _viewportsKeys.append(term.meta.key)
    _moveToShell(key: term.meta.key, animated: animated)
  }
  
  private func _moveToShell(idx: Int, animated: Bool = true) {
    guard _viewportsKeys.indices.contains(idx) else {
      return
    }

    let key = _viewportsKeys[idx]
    
    _moveToShell(key: key, animated: animated)
  }
  
  private func _moveToLastShell(animated: Bool = true) {
    _moveToShell(idx: _viewportsKeys.count - 1)
  }
  
  @objc func moveToShell(key: String?) {
    guard
      let key = key,
      let uuidKey = UUID(uuidString: key)
    else {
      return
    }
    _moveToShell(key: uuidKey, animated: true)
  }
  
  private func _moveToShell(key: UUID, animated: Bool = true) {
    guard
      let currentKey = _currentKey,
      let currentIdx = _viewportsKeys.firstIndex(of: currentKey),
      let idx = _viewportsKeys.firstIndex(of: key)
    else {
      return
    }
    
    let term: TermController = SessionRegistry.shared[key]
    let direction: UIPageViewController.NavigationDirection = currentIdx < idx ? .forward : .reverse

    _spaceControllerAnimating = true
    _viewportsController.setViewControllers([term], direction: direction, animated: animated) { (didComplete) in
      term.resumeIfNeeded()
      self._currentKey = term.meta.key
      self._displayHUD()
      self._attachInputToCurrentTerm()
      self._spaceControllerAnimating = false
    }
  }
  
  private func _advanceShell(by: Int, animated: Bool = true) {
    guard
      let currentKey = _currentKey,
      let idx = _viewportsKeys.firstIndex(of: currentKey)?.advanced(by: by)
    else {
      return
    }
        
    _moveToShell(idx: idx, animated: animated)
  }
  
  private func _advanceShellCycling(by: Int, animated: Bool = true) {
    guard
      let currentKey = _currentKey,
      _viewportsKeys.count > 1
    else {
      return
    }
    
    if let idx = _viewportsKeys.firstIndex(of: currentKey)?.advanced(by: by),
      idx >= 0 && idx < _viewportsKeys.count {
      _moveToShell(idx: idx, animated: animated)
      return
    }
    
    _moveToShell(idx: by > 0 ? 0 : _viewportsKeys.count - 1, animated: animated)
  }
  
}

// MARK: CommandsHUDDelegate
extension SpaceController: CommandsHUDDelegate {
  @objc func currentTerm() -> TermController? {
    if let currentKey = _currentKey {
      return SessionRegistry.shared[currentKey]
    }
    return nil
  }
  
  @objc func spaceController() -> SpaceController? { self }
}

// MARK: SnippetContext

extension SpaceController: SnippetContext {
  
  func _presentSnippetsController(receiver: SpaceController) {
    do {
      self.view.window?.makeKeyAndVisible()
      let ctrl = try SnippetsViewController.create(context: receiver, transitionFrame: _blinkMenu?.bounds)
      DispatchQueue.main.async {
        ctrl.view.frame = self.view.bounds
        ctrl.willMove(toParent: self)
        self.view.addSubview(ctrl.view)
        self.addChild(ctrl)
        ctrl.didMove(toParent: self)
        self._snippetsVC = ctrl
      }
    } catch {
      self.showAlert(msg: "Could not display Snips: \(error)")
    }
  }
  
  func presentSnippetsController() {
    _interactiveSpaceController()._presentSnippetsController(receiver: self)
  }
  
  func _dismissSnippetsController(ctrl: SpaceController) {
    ctrl.presentedViewController?.dismiss(animated: true)
    ctrl._snippetsVC?.willMove(toParent: nil)
    ctrl._snippetsVC?.view.removeFromSuperview()
    ctrl._snippetsVC?.removeFromParent()
    ctrl._snippetsVC?.didMove(toParent: nil)
    ctrl._snippetsVC = nil
  }
  
  func dismissSnippetsController() {
    _dismissSnippetsController(ctrl: _interactiveSpaceController())
    self.focusOnShellAction()
  }
  
  func providerSnippetReceiver() -> (any SnippetReceiver)? {
    self.focusOnShellAction()
    return self.currentDevice
  }
  
}

struct TmuxNotificationRequest: Equatable, Codable {
  let hostAlias: String
  let sessionName: String?
  let paneTarget: String
}

enum TmuxNotificationPayloadResolver {
  static func resolve(
    _ userInfo: [AnyHashable: Any],
    hostAliasForDeviceID: ((String) -> String?)? = nil
  ) -> TmuxNotificationRequest? {
    let paneTarget = (userInfo["paneTarget"] as? String)
      ?? (userInfo["pane_target"] as? String)
      ?? (userInfo["paneId"] as? String)
      ?? (userInfo["pane_id"] as? String)
    guard let paneTarget = paneTarget?.blink_trimmed, !paneTarget.isEmpty else {
      return nil
    }

    let sessionName = ((userInfo["sessionName"] as? String)
      ?? (userInfo["session_name"] as? String)
      ?? (userInfo["sessionId"] as? String)
      ?? (userInfo["session_id"] as? String)
      ?? paneTarget.components(separatedBy: ":").first)?.blink_trimmed

    if let alias = ((userInfo["hostAlias"] as? String)
      ?? (userInfo["hostId"] as? String)
      ?? (userInfo["host_id"] as? String)
      ?? (userInfo["serverName"] as? String))?.blink_trimmed,
      !alias.isEmpty
    {
      return TmuxNotificationRequest(hostAlias: alias, sessionName: sessionName, paneTarget: paneTarget)
    }

    if let deviceId = ((userInfo["deviceId"] as? String)
      ?? (userInfo["device_id"] as? String))?.blink_trimmed,
      !deviceId.isEmpty
    {
      let resolveHostAlias = hostAliasForDeviceID ?? { id in
        (BKHosts.allHosts() ?? []).first(where: { ($0.tmuxPushDeviceId ?? "").blink_trimmed == id })?.host
      }
      if let alias = resolveHostAlias(deviceId)?.blink_trimmed, !alias.isEmpty {
        return TmuxNotificationRequest(hostAlias: alias, sessionName: sessionName, paneTarget: paneTarget)
      }
    }

    return nil
  }
}

func tmuxSessionPickerTitle(
  name: String,
  attached: Bool,
  showAttachedIndicator: Bool
) -> String {
  let indicator = (attached && showAttachedIndicator) ? " • attached" : ""
  return "\(name)\(indicator)"
}

func tmuxPanePickerTitle(
  windowName: String,
  paneIndex: Int,
  currentPath: String,
  active: Bool,
  showActiveStar: Bool
) -> String {
  let marker = (active && showActiveStar) ? "★ " : ""
  let path = currentPath.blink_lastPathComponent
  return "\(marker)\(windowName) • pane \(paneIndex) • \(path)"
}

struct TmuxPaneInboxItem: Equatable {
  let hostAlias: String
  let hostName: String
  let sessionName: String
  let sessionAttached: Bool
  let windowIndex: Int
  let windowName: String
  let paneIndex: Int
  let paneTarget: String
  let currentPath: String
  let active: Bool
  let paneActivity: Int64
  let currentCommand: String
  let previewText: String
  let hasUnreadNotification: Bool
}

fileprivate enum TmuxPaneInboxRow: Equatable {
  case pane(TmuxPaneInboxItem)
  case message(String, isError: Bool, action: TmuxPaneInboxRowAction?)
}

fileprivate enum TmuxPaneInboxRowAction: Equatable {
  case upgradeHost(String)
  case fixRuntime(String)

  var subtitle: String {
    switch self {
    case .upgradeHost:
      return "Tap to upgrade this host's tmuxd service."
    case .fixRuntime:
      return "Tap to view tmux runtime upgrade guidance."
    }
  }
}

fileprivate struct TmuxPaneInboxSection: Equatable {
  let title: String
  let rows: [TmuxPaneInboxRow]
}

fileprivate struct TmuxPaneInboxHostDescriptor {
  let host: BKHosts
  let alias: String
  let hostName: String
}

func tmuxPaneInboxHostLabel(alias: String, hostName: String) -> String {
  if hostName.isEmpty || hostName == alias {
    return alias
  }
  return "\(alias) (\(hostName))"
}

func tmuxPaneInboxPreviewText(previewText: String, currentCommand: String, fallbackPath: String) -> String {
  let preview = previewText.blink_trimmed
  if !preview.isEmpty {
    return preview
  }

  let command = currentCommand.blink_trimmed
  if !command.isEmpty {
    return command
  }

  let path = fallbackPath.blink_lastPathComponent
  if !path.isEmpty {
    return path
  }
  return "(no recent output)"
}

func tmuxUpgradeCompletedButPaneInboxNotReadyMessage(hostAlias: String, issue: String) -> String {
  let cleanAlias = hostAlias.blink_trimmed
  let issueText = issue.blink_trimmed
  var message = "tmuxd upgrade completed successfully for host '\(cleanAlias)'.\n\nPane inbox is not ready yet."
  if !issueText.isEmpty {
    message += "\n\(issueText)"
  }
  message += "\n\nNext steps:\n1. Upgrade tmux on the host (minimum 3.1+).\n2. Restart tmux server.\n3. Re-open Chats and retry."
  return message
}

fileprivate func tmuxPaneInboxFlattenPanes(
  hostAlias: String,
  hostName: String,
  sessions: [TmuxControlSession]
) -> [TmuxPaneInboxItem] {
  var panes: [TmuxPaneInboxItem] = []
  panes.reserveCapacity(sessions.reduce(0) { partialResult, session in
    partialResult + session.windows.reduce(0) { $0 + $1.panes.count }
  })

  for session in sessions {
    let normalizedSession = session.name.blink_trimmed.isEmpty ? "(unnamed session)" : session.name.blink_trimmed
    for window in session.windows {
      let normalizedWindowName = window.name.blink_trimmed.isEmpty ? "window \(window.index)" : window.name.blink_trimmed
      for pane in window.panes {
        panes.append(
          TmuxPaneInboxItem(
            hostAlias: hostAlias,
            hostName: hostName,
            sessionName: normalizedSession,
            sessionAttached: session.attached,
            windowIndex: window.index,
            windowName: normalizedWindowName,
            paneIndex: pane.index,
            paneTarget: pane.target,
            currentPath: pane.currentPath,
            active: pane.active,
            paneActivity: pane.paneActivity,
            currentCommand: pane.currentCommand,
            previewText: pane.previewText,
            hasUnreadNotification: pane.hasUnreadNotification
          )
        )
      }
    }
  }

  return panes
}

func tmuxPaneInboxSortPanesByRecentActivity(_ panes: [TmuxPaneInboxItem]) -> [TmuxPaneInboxItem] {
  panes.sorted { lhs, rhs in
    if lhs.paneActivity != rhs.paneActivity {
      return lhs.paneActivity > rhs.paneActivity
    }
    if lhs.hostAlias.caseInsensitiveCompare(rhs.hostAlias) != .orderedSame {
      return lhs.hostAlias.caseInsensitiveCompare(rhs.hostAlias) == .orderedAscending
    }
    if lhs.sessionName.caseInsensitiveCompare(rhs.sessionName) != .orderedSame {
      return lhs.sessionName.caseInsensitiveCompare(rhs.sessionName) == .orderedAscending
    }
    if lhs.windowIndex != rhs.windowIndex {
      return lhs.windowIndex < rhs.windowIndex
    }
    if lhs.paneIndex != rhs.paneIndex {
      return lhs.paneIndex < rhs.paneIndex
    }
    return lhs.paneTarget.caseInsensitiveCompare(rhs.paneTarget) == .orderedAscending
  }
}

@MainActor
fileprivate final class TmuxPaneInboxViewController: UITableViewController {
  private enum Constants {
    static let cellID = "tmux-pane-inbox-cell"
    static let refreshIntervalNanoseconds: UInt64 = 20_000_000_000
  }

  private let onPaneSelected: (TmuxNotificationRequest) -> Void
  private let onCreateTerminal: () -> Void
  private let onUpgradeHost: (String) -> Void
  private let onFixRuntimeHost: (String) -> Void

  private var sections: [TmuxPaneInboxSection] = []
  private var autoRefreshTask: Task<Void, Never>?
  private var refreshInFlight = false
  private var hasLoadedOnce = false

  init(
    onPaneSelected: @escaping (TmuxNotificationRequest) -> Void,
    onCreateTerminal: @escaping () -> Void,
    onUpgradeHost: @escaping (String) -> Void,
    onFixRuntimeHost: @escaping (String) -> Void
  ) {
    self.onPaneSelected = onPaneSelected
    self.onCreateTerminal = onCreateTerminal
    self.onUpgradeHost = onUpgradeHost
    self.onFixRuntimeHost = onFixRuntimeHost
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    autoRefreshTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Tmux Chats"
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellID)
    tableView.keyboardDismissMode = .onDrag

    let refresh = UIRefreshControl()
    refresh.addTarget(self, action: #selector(_pullToRefresh), for: .valueChanged)
    refreshControl = refresh

    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "New Terminal",
      style: .plain,
      target: self,
      action: #selector(_newTerminalTapped)
    )
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    _startAutoRefreshLoopIfNeeded()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    autoRefreshTask?.cancel()
    autoRefreshTask = nil
  }

  @objc private func _newTerminalTapped() {
    onCreateTerminal()
  }

  @objc private func _pullToRefresh() {
    Task { [weak self] in
      await self?._reloadSections(showRefreshControl: false)
    }
  }

  private func _startAutoRefreshLoopIfNeeded() {
    guard autoRefreshTask == nil else {
      return
    }

    autoRefreshTask = Task { [weak self] in
      guard let self else {
        return
      }

      await self._reloadSections(showRefreshControl: !self.hasLoadedOnce)
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: Constants.refreshIntervalNanoseconds)
        if Task.isCancelled {
          return
        }
        await self._reloadSections(showRefreshControl: false)
      }
    }
  }

  private func _eligibleHosts() -> [TmuxPaneInboxHostDescriptor] {
    (BKHosts.allHosts() ?? [])
      .compactMap { host -> TmuxPaneInboxHostDescriptor? in
        guard let resolved = BKHosts.tmuxResolvedBaseURL(for: host)?.blink_trimmed, !resolved.isEmpty else {
          return nil
        }
        let aliasRaw = (host.host ?? "").blink_trimmed
        let hostName = (host.hostName ?? "").blink_trimmed
        let alias = aliasRaw.isEmpty ? (hostName.isEmpty ? "(unknown)" : hostName) : aliasRaw
        return TmuxPaneInboxHostDescriptor(host: host, alias: alias, hostName: hostName)
      }
      .sorted {
        $0.alias.caseInsensitiveCompare($1.alias) == .orderedAscending
      }
  }

  private func _reloadSections(showRefreshControl: Bool) async {
    guard !refreshInFlight else {
      return
    }
    refreshInFlight = true
    defer {
      refreshInFlight = false
      refreshControl?.endRefreshing()
    }

    if showRefreshControl, refreshControl?.isRefreshing == false {
      refreshControl?.beginRefreshing()
      if tableView.contentOffset.y >= 0 {
        tableView.setContentOffset(CGPoint(x: 0, y: -64), animated: true)
      }
    }

    let hosts = _eligibleHosts()
    guard !hosts.isEmpty else {
      sections = []
      hasLoadedOnce = true
      tableView.reloadData()
      _updateBackgroundView()
      return
    }

    var allPanes: [TmuxPaneInboxItem] = []
    var statusRows: [TmuxPaneInboxRow] = []
    allPanes.reserveCapacity(hosts.count * 2)
    statusRows.reserveCapacity(hosts.count)

    for descriptor in hosts {
      let hostLabel = tmuxPaneInboxHostLabel(alias: descriptor.alias, hostName: descriptor.hostName)
      do {
        let sessions = try await TmuxControlPlaneClient.listSessions(for: descriptor.host)
        let panes = tmuxPaneInboxFlattenPanes(
          hostAlias: descriptor.alias,
          hostName: descriptor.hostName,
          sessions: sessions
        )
        if panes.isEmpty {
          statusRows.append(.message("\(hostLabel): No tmux panes found.", isError: false, action: nil))
        } else {
          allPanes.append(contentsOf: panes)
        }
      } catch {
        let action: TmuxPaneInboxRowAction?
        if let controlError = error as? TmuxControlError {
          switch controlError {
          case .incompatibleRuntime:
            action = .fixRuntime(descriptor.alias)
          case .incompatibleCapabilitiesSchema, .incompatibleSessionsSchema:
            action = .upgradeHost(descriptor.alias)
          default:
            action = nil
          }
        } else {
          action = nil
        }
        statusRows.append(.message("\(hostLabel): \(error.localizedDescription)", isError: true, action: action))
      }
    }

    let sortedPanes = tmuxPaneInboxSortPanesByRecentActivity(allPanes)
    var nextSections: [TmuxPaneInboxSection] = []
    if !sortedPanes.isEmpty {
      nextSections.append(
        TmuxPaneInboxSection(
          title: "Chats • \(sortedPanes.count)",
          rows: sortedPanes.map { .pane($0) }
        )
      )
    }
    if !statusRows.isEmpty {
      nextSections.append(
        TmuxPaneInboxSection(
          title: "Host Status",
          rows: statusRows
        )
      )
    }

    sections = nextSections
    hasLoadedOnce = true
    tableView.reloadData()
    _updateBackgroundView()
  }

  private func _updateBackgroundView() {
    guard sections.isEmpty else {
      tableView.backgroundView = nil
      return
    }

    let titleLabel = UILabel()
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 0
    titleLabel.textColor = .secondaryLabel
    titleLabel.font = .preferredFont(forTextStyle: .body)
    titleLabel.text = "No valid tmux hosts found.\nConfigure a host in Settings > Hosts > SSH."

    let button = UIButton(type: .system)
    button.setTitle("New Terminal", for: .normal)
    button.addTarget(self, action: #selector(_newTerminalTapped), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [titleLabel, button])
    stack.axis = .vertical
    stack.spacing = 12
    stack.alignment = .center
    stack.layoutMargins = UIEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
    stack.isLayoutMarginsRelativeArrangement = true

    let container = UIView()
    container.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24)
    ])
    tableView.backgroundView = container
  }

  override func numberOfSections(in tableView: UITableView) -> Int {
    sections.count
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].title
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellID, for: indexPath)
    var content = cell.defaultContentConfiguration()
    switch sections[indexPath.section].rows[indexPath.row] {
    case .pane(let pane):
      let showPaneStar = BLKDefaults.isTmuxPaneStarVisible()
      let star = (showPaneStar && pane.active) ? "★ " : ""
      let attached = (BLKDefaults.isTmuxSessionAttachedVisible() && pane.sessionAttached) ? " • attached" : ""
      let hostLabel = tmuxPaneInboxHostLabel(alias: pane.hostAlias, hostName: pane.hostName)
      let unreadMarker = pane.hasUnreadNotification ? "● " : ""
      let preview = tmuxPaneInboxPreviewText(
        previewText: pane.previewText,
        currentCommand: pane.currentCommand,
        fallbackPath: pane.currentPath
      )
      content.text = "\(unreadMarker)\(star)\(pane.sessionName)\(attached)"
      content.secondaryText = "\(preview) • \(hostLabel) • \(pane.windowName) • pane \(pane.paneIndex)"
      content.textProperties.color = .label
      content.secondaryTextProperties.color = .secondaryLabel
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .message(let message, let isError, let action):
      content.text = message
      content.textProperties.color = isError ? .systemRed : .secondaryLabel
      content.secondaryText = action?.subtitle
      content.secondaryTextProperties.color = .secondaryLabel
      cell.accessoryType = action == nil ? .none : .disclosureIndicator
      cell.selectionStyle = action == nil ? .none : .default
    }
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    defer {
      tableView.deselectRow(at: indexPath, animated: true)
    }

    switch sections[indexPath.section].rows[indexPath.row] {
    case .pane(let pane):
      onPaneSelected(
        TmuxNotificationRequest(
          hostAlias: pane.hostAlias,
          sessionName: pane.sessionName,
          paneTarget: pane.paneTarget
        )
      )
    case .message(_, _, let action):
      guard let action else {
        return
      }
      switch action {
      case .upgradeHost(let hostAlias):
        onUpgradeHost(hostAlias)
      case .fixRuntime(let hostAlias):
        onFixRuntimeHost(hostAlias)
      }
    }
  }
}

fileprivate struct TmuxControlSession: Decodable {
  let name: String
  let attached: Bool
  let windows: [TmuxControlWindow]
}

fileprivate struct TmuxControlWindow: Decodable {
  let index: Int
  let name: String
  let panes: [TmuxControlPane]
}

fileprivate struct TmuxControlPane: Decodable {
  let index: Int
  let active: Bool
  let target: String
  let currentPath: String
  let paneActivity: Int64
  let currentCommand: String
  let previewText: String
  let hasUnreadNotification: Bool

  enum CodingKeys: String, CodingKey {
    case index
    case active
    case target
    case currentPath = "current_path"
    case paneActivity = "pane_activity"
    case currentCommand = "current_command"
    case previewText = "preview_text"
    case hasUnreadNotification = "has_unread_notification"
  }
}

fileprivate struct TmuxControlCapabilitiesResponse: Decodable {
  let capabilitiesSchemaVersion: Int
  let features: TmuxControlCapabilitiesFeatures

  enum CodingKeys: String, CodingKey {
    case capabilitiesSchemaVersion = "capabilities_schema_version"
    case features
  }
}

fileprivate struct TmuxControlCapabilitiesFeatures: Decodable {
  let paneInboxV1: TmuxControlPaneInboxCapability?

  enum CodingKeys: String, CodingKey {
    case paneInboxV1 = "pane_inbox_v1"
  }
}

fileprivate struct TmuxControlPaneInboxCapability: Decodable {
  let enabled: Bool
  let requiredPaneFields: [String]
  let runtimeCompatible: Bool?
  let minimumTmuxVersion: String?
  let detectedTmuxVersion: String?
  let missingCapabilities: [String]

  enum CodingKeys: String, CodingKey {
    case enabled
    case requiredPaneFields = "required_pane_fields"
    case runtimeCompatible = "runtime_compatible"
    case minimumTmuxVersion = "minimum_tmux_version"
    case detectedTmuxVersion = "detected_tmux_version"
    case missingCapabilities = "missing_capabilities"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decode(Bool.self, forKey: .enabled)
    requiredPaneFields = try container.decodeIfPresent([String].self, forKey: .requiredPaneFields) ?? []
    runtimeCompatible = try container.decodeIfPresent(Bool.self, forKey: .runtimeCompatible)
    minimumTmuxVersion = try container.decodeIfPresent(String.self, forKey: .minimumTmuxVersion)
    detectedTmuxVersion = try container.decodeIfPresent(String.self, forKey: .detectedTmuxVersion)
    missingCapabilities = try container.decodeIfPresent([String].self, forKey: .missingCapabilities) ?? []
  }
}

fileprivate struct TmuxControlRequestContext {
  let hostAlias: String
  let baseURL: String
  let bearerToken: String?
}

fileprivate struct TmuxControlHTTPResult {
  let statusCode: Int
  let data: Data
}

fileprivate struct TmuxControlAPIErrorResponse: Decodable {
  let code: String?
  let error: String?
  let missingCapabilities: [String]

  enum CodingKeys: String, CodingKey {
    case code
    case error
    case missingCapabilities = "missing_capabilities"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decodeIfPresent(String.self, forKey: .code)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    missingCapabilities = try container.decodeIfPresent([String].self, forKey: .missingCapabilities) ?? []
  }
}

fileprivate struct TmuxControlPaneOutputResponse: Decodable {
  let output: String
}

fileprivate struct TmuxControlPaneInputRequest: Encodable {
  let text: String
}

fileprivate enum TmuxControlError: LocalizedError {
  case invalidURL(String)
  case unauthorized(Int)
  case badStatusCode(Int, String)
  case incompatibleCapabilitiesSchema(String)
  case incompatibleSessionsSchema(String)
  case incompatibleRuntime(String, [String], String?)
  case missingDeviceAPIToken(String)
  case missingData(String)
  case decoding(String, Error)
  case transport(Error)

  var requiresHostUpgrade: Bool {
    switch self {
    case .incompatibleCapabilitiesSchema, .incompatibleSessionsSchema, .incompatibleRuntime:
      return true
    default:
      return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidURL(let value):
      return "Tmux endpoint is invalid or insecure: \(value). Use a valid https:// endpoint in Settings > Hosts > SSH."
    case .unauthorized:
      return "Tmux endpoint rejected credentials (HTTP 401/403). Verify Service Token in Settings > Hosts > SSH."
    case .badStatusCode(let code, let path):
      return "Tmux control plane returned HTTP \(code) at \(path)."
    case .incompatibleCapabilitiesSchema(let hostAlias):
      return "Host '\(hostAlias)' exposes an outdated tmux capabilities payload (requires capabilities_schema_version >= 7 with pane_inbox_v1). Upgrade tmuxd on this host."
    case .incompatibleSessionsSchema(let hostAlias):
      return "Host '\(hostAlias)' exposes an outdated tmux sessions payload (missing pane_activity/current_command/preview_text/has_unread_notification). Upgrade tmuxd/tmux."
    case .incompatibleRuntime(let hostAlias, let missingCapabilities, let detail):
      let missing = missingCapabilities
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let capabilitiesPart: String
      if missing.isEmpty {
        capabilitiesPart = "pane inbox runtime capabilities"
      } else {
        capabilitiesPart = missing.joined(separator: "/")
      }
      var message = "Host '\(hostAlias)' tmux runtime is incompatible with pane inbox requirements (\(capabilitiesPart)). Upgrade tmux on this host and retry."
      if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedDetail.lowercased().contains("pane inbox requirements") {
          message += "\nDetails: \(normalizedDetail)"
        }
      }
      return message
    case .missingDeviceAPIToken(let hostAlias):
      return "Host '\(hostAlias)' is missing Device API token. Re-register tmux push in Settings > Hosts > SSH."
    case .missingData(let path):
      return "Tmux control plane returned no data at \(path)."
    case .decoding(_, let error):
      return "Failed to decode tmux control response: \(error.localizedDescription)"
    case .transport(let error):
      return "Failed to connect to tmux endpoint: \(error.localizedDescription)"
    }
  }
}

fileprivate enum TmuxControlPlaneClient {
  private static let outputLines = 500
  private static let minimumCapabilitiesSchemaVersion = 7
  private static let capabilitiesPath = "/v1/capabilities"
  private static let sessionsPath = "/v1/tmux/sessions"
  private static let requiredPaneInboxFields: Set<String> = [
    "pane_activity",
    "current_command",
    "preview_text",
    "has_unread_notification"
  ]

  static func listSessions(for host: BKHosts) async throws -> [TmuxControlSession] {
    let context = try _context(for: host)
    try await _validatePaneInboxCapabilities(context: context)

    let path = sessionsPath
    let result = try await _request(context: context, path: path, method: "GET")
    if result.statusCode == 404 {
      throw TmuxControlError.incompatibleCapabilitiesSchema(context.hostAlias)
    }
    try _throwIfNonSuccess(result: result, path: path, hostAlias: context.hostAlias)
    guard !result.data.isEmpty else {
      throw TmuxControlError.missingData(path)
    }
    return try _decodeSessions(
      data: result.data,
      path: path,
      hostAlias: context.hostAlias
    )
  }

  static func markPaneRead(for host: BKHosts, target: String) async throws {
    let context = try _context(for: host)
    let cleanToken = host.tmuxPushDeviceApiToken?.blink_trimmed ?? ""
    guard !cleanToken.isEmpty else {
      throw TmuxControlError.missingDeviceAPIToken(context.hostAlias)
    }

    let encodedTarget = _encodePathComponent(target)
    let path = "/v1/push/panes/\(encodedTarget)/read"
    let deviceContext = TmuxControlRequestContext(
      hostAlias: context.hostAlias,
      baseURL: context.baseURL,
      bearerToken: cleanToken
    )
    let result = try await _request(context: deviceContext, path: path, method: "POST")
    try _throwIfNonSuccess(result: result, path: path, hostAlias: context.hostAlias)
  }

  static func getPaneOutput(for host: BKHosts, target: String, lines: Int = outputLines) async throws -> String {
    let context = try _context(for: host)
    let encodedTarget = _encodePathComponent(target)
    let path = "/v1/tmux/panes/\(encodedTarget)/output?lines=\(max(1, lines))"
    let result = try await _request(context: context, path: path, method: "GET")
    try _throwIfNonSuccess(result: result, path: path, hostAlias: context.hostAlias)
    guard !result.data.isEmpty else {
      throw TmuxControlError.missingData(path)
    }
    if let response = try? _decode(TmuxControlPaneOutputResponse.self, data: result.data, path: path) {
      return response.output
    }
    if let raw = String(data: result.data, encoding: .utf8) {
      return raw
    }
    throw TmuxControlError.decoding(path, DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported output payload.")))
  }

  static func sendInput(for host: BKHosts, target: String, text: String) async throws {
    let context = try _context(for: host)
    let encodedTarget = _encodePathComponent(target)
    let body = try JSONEncoder().encode(TmuxControlPaneInputRequest(text: text))
    let path = "/v1/tmux/panes/\(encodedTarget)/input"
    let result = try await _request(context: context, path: path, method: "POST", body: body)
    try _throwIfNonSuccess(result: result, path: path, hostAlias: context.hostAlias)
  }

  static func sendEscape(for host: BKHosts, target: String) async throws {
    let context = try _context(for: host)
    let encodedTarget = _encodePathComponent(target)
    let path = "/v1/tmux/panes/\(encodedTarget)/escape"
    let result = try await _request(context: context, path: path, method: "POST")
    try _throwIfNonSuccess(result: result, path: path, hostAlias: context.hostAlias)
  }

  private static func _context(for host: BKHosts) throws -> TmuxControlRequestContext {
    let hostAlias = host.host?.blink_trimmed ?? ""
    let rawURL = BKHosts.tmuxResolvedBaseURL(for: host)?.blink_trimmed ?? ""
    guard !rawURL.isEmpty else {
      throw TmuxControlError.invalidURL(host.hostName ?? hostAlias)
    }

    guard let base = BKHosts.tmuxNormalizeBaseURL(rawURL), !base.isEmpty else {
      throw TmuxControlError.invalidURL(rawURL)
    }

    let token = host.tmuxServiceToken?.blink_trimmed
    return TmuxControlRequestContext(
      hostAlias: hostAlias.isEmpty ? (host.hostName ?? "(unknown)") : hostAlias,
      baseURL: base,
      bearerToken: token?.isEmpty == true ? nil : token
    )
  }

  private static func _request(
    context: TmuxControlRequestContext,
    path: String,
    method: String,
    body: Data? = nil
  ) async throws -> TmuxControlHTTPResult {
    guard let url = URL(string: "\(context.baseURL)\(path)") else {
      throw TmuxControlError.invalidURL("\(context.baseURL)\(path)")
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 8
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let token = context.bearerToken, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw TmuxControlError.missingData(path)
      }
      return TmuxControlHTTPResult(statusCode: http.statusCode, data: data)
    } catch let error as TmuxControlError {
      throw error
    } catch {
      throw TmuxControlError.transport(error)
    }
  }

  private static func _throwIfNonSuccess(
    result: TmuxControlHTTPResult,
    path: String,
    hostAlias: String
  ) throws {
    guard !(result.statusCode == 401 || result.statusCode == 403) else {
      throw TmuxControlError.unauthorized(result.statusCode)
    }
    guard !(200...299).contains(result.statusCode) else {
      return
    }

    if path == sessionsPath,
       let classified = _classifySessionsRuntimeIncompatibility(
        statusCode: result.statusCode,
        hostAlias: hostAlias,
        data: result.data
       ) {
      throw classified
    }

    throw TmuxControlError.badStatusCode(result.statusCode, path)
  }

  private static func _decode<T: Decodable>(_ type: T.Type, data: Data, path: String) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw TmuxControlError.decoding(path, error)
    }
  }

  private static func _decodeSessions(
    data: Data,
    path: String,
    hostAlias: String
  ) throws -> [TmuxControlSession] {
    do {
      return try JSONDecoder().decode([TmuxControlSession].self, from: data)
    } catch DecodingError.keyNotFound(let key, _) where _isRequiredSessionsField(key.stringValue) {
      throw TmuxControlError.incompatibleSessionsSchema(hostAlias)
    } catch {
      throw TmuxControlError.decoding(path, error)
    }
  }

  private static func _decodeCapabilities(
    data: Data,
    hostAlias: String
  ) throws -> TmuxControlCapabilitiesResponse {
    do {
      return try JSONDecoder().decode(TmuxControlCapabilitiesResponse.self, from: data)
    } catch {
      throw TmuxControlError.incompatibleCapabilitiesSchema(hostAlias)
    }
  }

  private static func _validatePaneInboxCapabilities(
    context: TmuxControlRequestContext
  ) async throws {
    let result = try await _request(context: context, path: capabilitiesPath, method: "GET")
    if result.statusCode == 404 {
      throw TmuxControlError.incompatibleCapabilitiesSchema(context.hostAlias)
    }
    try _throwIfNonSuccess(result: result, path: capabilitiesPath, hostAlias: context.hostAlias)
    guard !result.data.isEmpty else {
      throw TmuxControlError.missingData(capabilitiesPath)
    }

    let capabilities = try _decodeCapabilities(
      data: result.data,
      hostAlias: context.hostAlias
    )
    guard capabilities.capabilitiesSchemaVersion >= minimumCapabilitiesSchemaVersion else {
      throw TmuxControlError.incompatibleCapabilitiesSchema(context.hostAlias)
    }
    guard let paneInboxV1 = capabilities.features.paneInboxV1 else {
      throw TmuxControlError.incompatibleCapabilitiesSchema(context.hostAlias)
    }

    if paneInboxV1.runtimeCompatible == false || !paneInboxV1.missingCapabilities.isEmpty {
      throw TmuxControlError.incompatibleRuntime(
        context.hostAlias,
        paneInboxV1.missingCapabilities,
        nil
      )
    }

    guard paneInboxV1.enabled else {
      throw TmuxControlError.incompatibleCapabilitiesSchema(context.hostAlias)
    }

    let normalized = Set(paneInboxV1.requiredPaneFields.map { $0.lowercased() })
    guard requiredPaneInboxFields.isSubset(of: normalized) else {
      throw TmuxControlError.incompatibleCapabilitiesSchema(context.hostAlias)
    }
  }

  private static func _decodeAPIErrorResponse(from data: Data) -> TmuxControlAPIErrorResponse? {
    guard !data.isEmpty else {
      return nil
    }
    return try? JSONDecoder().decode(TmuxControlAPIErrorResponse.self, from: data)
  }

  private static func _classifySessionsRuntimeIncompatibility(
    statusCode: Int,
    hostAlias: String,
    data: Data
  ) -> TmuxControlError? {
    let payload = _decodeAPIErrorResponse(from: data)
    let code = payload?.code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let detail = payload?.error?.trimmingCharacters(in: .whitespacesAndNewlines)
    let missing = payload?.missingCapabilities ?? []
    let detailLower = detail?.lowercased() ?? ""

    let knownCodes: Set<String> = [
      "incompatible_tmux_runtime",
      "incompatible_pane_inbox_runtime",
      "pane_inbox_runtime_incompatible"
    ]
    if knownCodes.contains(code) {
      return .incompatibleRuntime(hostAlias, missing, detail)
    }

    let nonRuntimeCodes: Set<String> = [
      "sessions_payload_parse_error",
      "tmux_error",
      "tmux_io_error",
      "db_error"
    ]
    if nonRuntimeCodes.contains(code) {
      return nil
    }

    if statusCode == 422,
       !detailLower.isEmpty,
       (detailLower.contains("pane_activity") ||
        detailLower.contains("pane_current_command") ||
        detailLower.contains("incompatible tmux runtime"))
    {
      return .incompatibleRuntime(hostAlias, missing, detail)
    }

    if statusCode >= 500,
       !detailLower.isEmpty,
       (detailLower.contains("pane_activity") ||
        detailLower.contains("pane_current_command") ||
        detailLower.contains("incompatible tmux runtime"))
    {
      return .incompatibleRuntime(hostAlias, missing, detail)
    }

    return nil
  }

  private static func _isRequiredSessionsField(_ key: String) -> Bool {
    switch key {
    case "pane_activity", "current_command", "preview_text", "has_unread_notification":
      return true
    default:
      return false
    }
  }

  static func _encodePathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  static func _sessionsErrorMessageForTesting(
    statusCode: Int,
    hostAlias: String,
    payload: String
  ) -> String? {
    let data = payload.data(using: .utf8) ?? Data()
    let result = TmuxControlHTTPResult(statusCode: statusCode, data: data)
    do {
      try _throwIfNonSuccess(result: result, path: sessionsPath, hostAlias: hostAlias)
      return nil
    } catch {
      return error.localizedDescription
    }
  }
}

func tmuxControlEncodePathComponent(_ value: String) -> String {
  TmuxControlPlaneClient._encodePathComponent(value)
}

func tmuxControlSessionsPathForTesting() -> String {
  "/v1/tmux/sessions"
}

func tmuxControlPaneOutputPathForTesting(target: String, lines: Int) -> String {
  "/v1/tmux/panes/\(target)/output?lines=\(max(1, lines))"
}

func tmuxControlPaneInputPathForTesting(target: String) -> String {
  "/v1/tmux/panes/\(target)/input"
}

func tmuxControlPaneEscapePathForTesting(target: String) -> String {
  "/v1/tmux/panes/\(target)/escape"
}

func tmuxControlSessionsErrorMessageForTesting(
  statusCode: Int,
  hostAlias: String,
  payload: String
) -> String? {
  TmuxControlPlaneClient._sessionsErrorMessageForTesting(
    statusCode: statusCode,
    hostAlias: hostAlias,
    payload: payload
  )
}

@MainActor
fileprivate final class TmuxPaneDetailViewController: UIViewController, UITextFieldDelegate {
  private let host: BKHosts
  private let request: TmuxNotificationRequest

  private let statusLabel = UILabel()
  private let outputTextView = UITextView()
  private let inputField = UITextField()
  private let sendButton = UIButton(type: .system)
  private let escapeButton = UIButton(type: .system)

  private var pollingTask: Task<Void, Never>?
  private var refreshInFlight = false
  private var lastOutput = ""
  private var hasLoadedOnce = false

  init(host: BKHosts, request: TmuxNotificationRequest) {
    self.host = host
    self.request = request
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    pollingTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = request.paneTarget
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(_closeTapped))
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(_refreshTapped))
    _configureLayout()
    _setStatus("Loading pane output…", isError: false)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    _startPollingIfNeeded()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true {
      pollingTask?.cancel()
      pollingTask = nil
    }
  }

  @objc private func _closeTapped() {
    dismiss(animated: true)
  }

  @objc private func _refreshTapped() {
    Task { [weak self] in
      await self?._refreshOutput(showLoading: true)
    }
  }

  @objc private func _sendTapped() {
    Task { [weak self] in
      await self?._sendCurrentInput()
    }
  }

  @objc private func _escapeTapped() {
    Task { [weak self] in
      await self?._sendEscape()
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    _sendTapped()
    return false
  }

  private func _configureLayout() {
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.numberOfLines = 2
    statusLabel.font = .preferredFont(forTextStyle: .footnote)
    statusLabel.textColor = .secondaryLabel

    outputTextView.translatesAutoresizingMaskIntoConstraints = false
    outputTextView.isEditable = false
    outputTextView.alwaysBounceVertical = true
    outputTextView.backgroundColor = .secondarySystemBackground
    outputTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    outputTextView.textColor = .label
    outputTextView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    outputTextView.layer.cornerRadius = 10

    inputField.translatesAutoresizingMaskIntoConstraints = false
    inputField.placeholder = "Send input to \(request.paneTarget)"
    inputField.borderStyle = .roundedRect
    inputField.returnKeyType = .send
    inputField.delegate = self

    sendButton.translatesAutoresizingMaskIntoConstraints = false
    sendButton.setTitle("Send", for: .normal)
    sendButton.addTarget(self, action: #selector(_sendTapped), for: .touchUpInside)

    escapeButton.translatesAutoresizingMaskIntoConstraints = false
    escapeButton.setTitle("Esc", for: .normal)
    escapeButton.addTarget(self, action: #selector(_escapeTapped), for: .touchUpInside)

    let inputStack = UIStackView(arrangedSubviews: [inputField, sendButton, escapeButton])
    inputStack.translatesAutoresizingMaskIntoConstraints = false
    inputStack.axis = .horizontal
    inputStack.spacing = 8
    inputStack.alignment = .center

    view.addSubview(statusLabel)
    view.addSubview(outputTextView)
    view.addSubview(inputStack)

    NSLayoutConstraint.activate([
      statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

      outputTextView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
      outputTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      outputTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

      inputStack.topAnchor.constraint(equalTo: outputTextView.bottomAnchor, constant: 8),
      inputStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      inputStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      inputStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

      inputField.heightAnchor.constraint(equalToConstant: 36),
      sendButton.widthAnchor.constraint(equalToConstant: 56),
      escapeButton.widthAnchor.constraint(equalToConstant: 52)
    ])
  }

  private func _startPollingIfNeeded() {
    guard pollingTask == nil else { return }
    pollingTask = Task { [weak self] in
      guard let self else { return }
      await self._refreshOutput(showLoading: true)
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if Task.isCancelled { return }
        await self._refreshOutput(showLoading: false)
      }
    }
  }

  private func _refreshOutput(showLoading: Bool) async {
    guard !refreshInFlight else { return }
    refreshInFlight = true
    defer { refreshInFlight = false }

    if showLoading {
      _setStatus("Refreshing \(request.paneTarget)…", isError: false)
    }

    do {
      let output = try await TmuxControlPlaneClient.getPaneOutput(for: host, target: request.paneTarget)
      if output != lastOutput {
        lastOutput = output
        outputTextView.text = output
        if !output.isEmpty {
          let bottom = NSRange(location: max(0, output.utf16.count - 1), length: 1)
          outputTextView.scrollRangeToVisible(bottom)
        }
      }
      hasLoadedOnce = true
      _setStatus("Connected to \(request.hostAlias) • pane \(request.paneTarget)", isError: false)
    } catch {
      if !hasLoadedOnce {
        outputTextView.text = ""
      }
      _setStatus(error.localizedDescription, isError: true)
    }
  }

  private func _sendCurrentInput() async {
    let text = inputField.text?.blink_trimmed ?? ""
    guard !text.isEmpty else {
      return
    }
    inputField.text = ""
    _setStatus("Sending input…", isError: false)
    do {
      try await TmuxControlPlaneClient.sendInput(for: host, target: request.paneTarget, text: text)
      await _refreshOutput(showLoading: false)
    } catch {
      _setStatus(error.localizedDescription, isError: true)
    }
  }

  private func _sendEscape() async {
    _setStatus("Sending Esc…", isError: false)
    do {
      try await TmuxControlPlaneClient.sendEscape(for: host, target: request.paneTarget)
      await _refreshOutput(showLoading: false)
    } catch {
      _setStatus(error.localizedDescription, isError: true)
    }
  }

  private func _setStatus(_ message: String, isError: Bool) {
    statusLabel.text = message
    statusLabel.textColor = isError ? .systemRed : .secondaryLabel
  }
}

fileprivate extension Notification.Name {
  static let BLKOpenTmuxPane = Notification.Name("BLKOpenTmuxPaneNotification")
}

fileprivate extension String {
  var blink_trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var blink_lastPathComponent: String {
    let component = (self as NSString).lastPathComponent
    if component.isEmpty || component == "/" || component == "." {
      return self
    }
    return component
  }
}
