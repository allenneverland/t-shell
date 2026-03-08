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
    
    if _viewportsKeys.isEmpty {
      _createShell(userActivity: nil, animated: false)
    } else if let key = _currentKey {
      let term: TermController = SessionRegistry.shared[key]
      term.delegate = self
      term.bgColor = view.backgroundColor ?? .black
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
    _createShell(userActivity: nil, animated: true)
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
    let hosts = (BKHosts.allHosts() ?? []).filter { host in
      !(host.tmuxServiceURL?.blink_trimmed.isEmpty ?? true)
    }.sorted { ($0.host ?? "") < ($1.host ?? "") }

    guard !hosts.isEmpty else {
      showAlert(msg: "No host has Service URL configured. Edit a host in Settings > Hosts > TMUX first.")
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
    for session in sessions.sorted(by: { $0.name < $1.name }) {
      let indicator = session.attached ? " • attached" : ""
      alert.addAction(UIAlertAction(title: "\(session.name)\(indicator)", style: .default, handler: { [weak self] _ in
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
    for entry in panes {
      let marker = entry.pane.active ? "★ " : ""
      let path = entry.pane.currentPath.blink_lastPathComponent
      let title = "\(marker)\(entry.window.name) • pane \(entry.pane.index) • \(path)"
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
    _interactiveSpaceController()._openShellAndRunCommand(command)
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

    let remoteCommand = "tmux attach-session -t \(cleanSession.blink_shellQuoted) \\; select-pane -t \(cleanPane.blink_shellQuoted)"
    let command = "ssh \(cleanHost.blink_shellQuoted) -t \(remoteCommand.blink_shellQuoted)"
    _openShellAndRunCommand(command)
  }

  private func _openShellAndRunCommand(_ command: String) {
    let cleanCommand = command.blink_trimmed
    guard !cleanCommand.isEmpty else {
      showAlert(msg: "Command is empty.")
      return
    }

    _createShell(userActivity: nil, animated: true) { [weak self] _ in
      guard let self,
            let term = self.currentTerm()
      else {
        return
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        term.termDevice.write(cleanCommand)
        term.termDevice.write("\n")
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

struct TmuxNotificationRequest: Equatable {
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

  enum CodingKeys: String, CodingKey {
    case index
    case active
    case target
    case currentPath = "current_path"
  }
}

fileprivate enum TmuxControlError: LocalizedError {
  case missingControlURL(String)
  case invalidURL(String)
  case badStatusCode(Int)
  case missingData
  case decoding(Error)

  var errorDescription: String? {
    switch self {
    case .missingControlURL(let hostAlias):
      return "Host '\(hostAlias)' is missing Service URL."
    case .invalidURL(let value):
      return "Service URL is invalid: \(value)"
    case .badStatusCode(let code):
      return "Tmux control plane returned HTTP \(code)."
    case .missingData:
      return "Tmux control plane returned no data."
    case .decoding(let error):
      return "Failed to decode tmux sessions: \(error.localizedDescription)"
    }
  }
}

fileprivate enum TmuxControlPlaneClient {
  static func listSessions(for host: BKHosts) async throws -> [TmuxControlSession] {
    let alias = host.host ?? "(unknown)"
    guard let rawURL = host.tmuxServiceURL?.blink_trimmed, !rawURL.isEmpty else {
      throw TmuxControlError.missingControlURL(alias)
    }

    guard let base = _normalizeBaseURL(rawURL), let url = URL(string: "\(base)/v1/tmux/sessions") else {
      throw TmuxControlError.invalidURL(rawURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token = host.tmuxServiceToken?.blink_trimmed, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TmuxControlError.missingData
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw TmuxControlError.badStatusCode(httpResponse.statusCode)
    }
    guard !data.isEmpty else {
      throw TmuxControlError.missingData
    }

    do {
      return try JSONDecoder().decode([TmuxControlSession].self, from: data)
    } catch {
      throw TmuxControlError.decoding(error)
    }
  }

  private static func _normalizeBaseURL(_ raw: String) -> String? {
    guard
      var components = URLComponents(string: raw),
      let host = components.host,
      let scheme = components.scheme?.lowercased(),
      !host.isEmpty,
      ["http", "https"].contains(scheme)
    else {
      return nil
    }

    components.scheme = scheme
    components.query = nil
    components.fragment = nil
    components.user = nil
    components.password = nil

    let path = components.percentEncodedPath.lowercased()
    if path == "/healthz" || path == "/healthz/" || path == "/v1/healthz" || path == "/v1/healthz/" || path == "/" {
      components.percentEncodedPath = ""
    }

    guard let normalized = components.string else {
      return nil
    }
    if normalized.hasSuffix("/") {
      return String(normalized.dropLast())
    }
    return normalized
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

  var blink_shellQuoted: String {
    let escaped = replacingOccurrences(of: "'", with: "'\"'\"'")
    return "'\(escaped)'"
  }
}
