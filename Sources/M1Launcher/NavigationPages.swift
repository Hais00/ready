// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

enum SettingsPageSection: String {
  case overview, accounts, storage, runtime, data, evaluation
  var title: String {
    switch self {
    case .overview: return "Generali"
    case .accounts: return "Account"
    case .storage: return "Archiviazione"
    case .runtime: return "Motori"
    case .data: return "Dati e ripristino"
    case .evaluation: return "Toolkit Apple"
    }
  }
}

extension AppDelegate {
  func beginPage(_ section: CanvasSection) {
    guard canvas != nil,canNavigateInterfaceWhilePlaying else { return }
    let previousTransition = pageNavigationTransition
    pageNavigationTransition = true
    pages.cancelCurrent()
    if authenticationSession != nil { cancelAuthentication() }
    pageNavigationTransition = previousTransition
    canvas.section = section
    canvas.pageTitle = section == .steamAccount ? "Amici" : nil
    let back: () -> Void = { [weak self] in self?.navigateToLibrary() }
    switch section {
    case .settings:
      pages.configureNavigation(title: "Impostazioni", tabs: [SettingsPageSection.overview, .accounts, .storage, .runtime, .data, .evaluation].map { item in
        ReadyPageTab(id: item.rawValue, title: item.title, action: { [weak self] in self?.openSettingsSection(item) })
      }, selected: settingsPageSection.rawValue, onBack: back)
    case .steamAccount:
      pages.configureNavigation(title: "Amici", tabs: [
        ReadyPageTab(id: "library", title: "Libreria", action: { [weak self] in self?.navigateToLibrary(store: .steam) }),
        ReadyPageTab(id: "account", title: "Account e amici", action: { [weak self] in MainActor.assumeIsolated { self?.showSteamAccount() } }),
        ReadyPageTab(id: "downloads", title: "Download", action: { [weak self] in MainActor.assumeIsolated { self?.showSteamDownloads() } }),
      ], selected: "account", onBack: back)
    case .downloads:
      pages.configureNavigation(title: "Download", tabs: [], selected: nil, onBack: back)
    case .profiles:
      pages.configureNavigation(title: "Profili", tabs: [], selected: nil, onBack: back)
    case .utility:
      pages.configureNavigation(title: "Libreria", tabs: [], selected: nil, onBack: back)
    case .library,.game: break
    }
    canvas.refresh()
  }
  func beginSettingsSection(_ section: SettingsPageSection) {
    settingsPageSection = section
    beginPage(.settings)
  }
  func openSettingsSection(_ section: SettingsPageSection) {
    guard !maintenanceInProgress, canNavigateInterfaceWhilePlaying, pendingLaunch == nil else { return }
    switch section {
    case .overview: settings()
    case .accounts: connectStore()
    case .storage: MainActor.assumeIsolated { showStorageSettings() }
    case .runtime: runtimeLocationSettings()
    case .data: dataMaintenance()
    case .evaluation: evaluationSettings()
    }
  }
  func navigateToLibrary(store: Store? = nil, preservingSelection: Bool = false) {
    guard canvas != nil,canNavigateInterfaceWhilePlaying else { return }
    pageNavigationTransition = true
    pages.cancelCurrent()
    _ = pages.detachForSession()
    cancelAuthentication()
    pageNavigationTransition = false
    canvas.section = .library
    canvas.filter = nil
    canvas.pageTitle=nil
    if !preservingSelection { canvas.selected = 0 }
    window?.makeFirstResponder(canvas)
    canvas.refresh()
  }
  func pageNeedsLanding() {
    guard !pageNavigationTransition, canvas != nil, canNavigateInterfaceWhilePlaying,
      !maintenanceInProgress, !pages.isPresenting else { return }
    if canvas.section == .settings { settings() }
    else { navigateToLibrary(store: canvas.filter, preservingSelection: true) }
  }
  func isPresentationShowing(_ id: UUID) -> Bool { pages.isShowing(id) || dialogs.isShowing(id) }
  func setPresentationActionEnabled(_ id: UUID, index: Int, enabled: Bool) {
    if pages.isShowing(id) { pages.setActionEnabled(id,index:index,enabled:enabled) }
    else { dialogs.setActionEnabled(id,index:index,enabled:enabled) }
  }
  func activatePresentationPrimary(_ id: UUID) {
    if pages.isShowing(id) { pages.activatePrimary(id) }
    else { dialogs.activatePrimary(id) }
  }
}
