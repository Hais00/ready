// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore
private enum InstallationCheck:Error{case failed(String)}
@main struct ReadyGameInstallationProbe {
  @MainActor static func main()throws{
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var checks=[String:Bool]()
    func check(_ value:Bool,_ label:String)throws{checks[label]=value;if !value{throw InstallationCheck.failed(label)}}
    let a=UUID(),b=UUID(),bad=UUID()
    let options=[GameInstallationOption(id:a,title:"Own disk A",path:"/fixture/A",availableBytes:300_000_000_000,usable:true,issue:nil),GameInstallationOption(id:b,title:"Own disk B",path:"/fixture/B",availableBytes:100_000_000_000,usable:true,issue:nil),GameInstallationOption(id:bad,title:"Own unusable disk",path:"/fixture/bad",availableBytes:500_000_000_000,usable:false,issue:"Fixture unavailable")]
    let variant=GameVariant(id:"windows",platform:.windows),game=Game(id:"fixture",store:.steam,storeID:"480",title:"Own installation fixture",variants:[variant])
    let view=GameInstallationView(game:game,variant:variant)
    let window=NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;defer{window.close()}
    let button: (String)->NSButton={title in view.subviews.compactMap{$0 as?NSButton}.first{$0.title==title}!}
    let picker=view.subviews.compactMap{$0 as?NSPopUpButton}.first!
    var installs=0,plans=0,manages=0,cancels=0,libraries=[UUID]()
    view.onInstall={installs+=1};view.onPlan={plans+=1};view.onManage={manages+=1};view.onCancel={cancels+=1};view.onLibraryChanged={libraries.append($0)}
    let known=GameStorageInfo(installedBytes:200_000_000_000,downloadBytes:130_000_000_000,source:"own-plan",verified:true,status:"available")
    view.update(options:options,selected:a,info:known,loading:true)
    try check(!button("Installa").isEnabled && !button("Ricalcola dimensione").isEnabled,"loadingDisablesInstallAndPlan")
    view.update(options:options,selected:a,info:known,loading:false)
    try check(button("Installa").isEnabled && view.selectedLibraryID==a,"knownReservationAndSufficientFreeSpaceEnableInstall")
    button("Installa").performClick(nil);try check(installs==1,"installCallbackRequiresEnabledKnownPlan")
    view.update(options:options,selected:b,info:known,loading:false)
    try check(!button("Installa").isEnabled && view.subviews.compactMap{$0 as?NSTextField}.contains{$0.stringValue.contains("insufficiente")},"insufficientSelectedCapacityDisablesInstall")
    view.update(options:options,selected:bad,info:known,loading:false)
    try check(!button("Installa").isEnabled,"unusableLibraryCannotInstallDespiteNominalCapacity")
    view.update(options:options,selected:a,info:GameStorageInfo(downloadBytes:1_000),loading:false)
    try check(!button("Installa").isEnabled,"downloadBytesAloneDoNotInventInstallationReservation")
    view.update(options:options,selected:a,info:GameStorageInfo(),loading:false)
    try check(!button("Installa").isEnabled && view.subviews.compactMap{$0 as?NSTextField}.contains{$0.stringValue.contains("Dimensione non disponibile")},"unknownBytesDisableInstallWithoutTreatingUnknownAsZero")
    view.update(options:options,selected:a,info:known,loading:false,canInstall:false,authorizationRequired:true)
    try check(!button("Installa").isEnabled && button("Accedi allo store").isEnabled,"offlineOrAuthorizationGateOverridesKnownFreeSpace")
    _=view.handleController(.activate);try check(installs==1 && NSApp.modalWindow==nil,"controllerActivateOnVersionDoesNotOpenPopupOrInstall")
    _=view.handleController(.move(.down));_=view.handleController(.activate)
    try check(plans==1,"controllerReachesAuthorizedPlanActionWithoutInstalling")
    _=view.handleController(.move(.down));_=view.handleController(.activate)
    try check(manages==1,"controllerReachesManageLibraries")
    _=view.handleController(.move(.down));_=view.handleController(.activate)
    try check(cancels==1,"controllerReachesPageBackAction")
    _=view.handleController(.cancel);try check(cancels==2,"controllerCancelUsesRootHook")
    // A fresh view starts controller focus on the selector without native menu tracking.
    let selectionView=GameInstallationView(game:game,variant:variant);selectionView.onLibraryChanged={libraries.append($0)}
    selectionView.update(options:options,selected:a,info:known,loading:false)
    _=selectionView.handleController(.move(.right));try check(selectionView.selectedLibraryID==b && libraries.last==b,"controllerCyclesSelectedLibraryAndNotifiesRoot")
    selectionView.update(options:options,selected:selectionView.selectedLibraryID,info:known,loading:false)
    try check(selectionView.subviews.compactMap{$0 as?NSButton}.first{$0.title=="Installa"}?.isEnabled==false,"rootSelectedLibraryRefreshAppliesItsOwnCapacityGate")
    view.update(options:[],selected:nil,info:known,loading:false)
    try check(view.selectedLibraryID==nil && !picker.isEnabled && !button("Installa").isEnabled,"missingLibrariesDisablePickerAndInstallation")
    view.update(options:options,selected:a,info:GameStorageInfo(requiredBytes:100_000_000_000,source:"store-minimum"),loading:false)
    try check(button("Installa").isEnabled && view.subviews.compactMap{$0 as?NSTextField}.contains{$0.stringValue.contains("richiesto dal negozio")},"knownStoreRequirementCanGateReservationWithoutInventingDownloadSize")
    view.setWorking("Own job queued")
    try check(!button("Installa").isEnabled && !picker.isEnabled && !button("Gestisci cartelle…").isEnabled,"workingStateDisablesInstallPickerAndManagement")
    for width:CGFloat in [360,600]{view.setFrameSize(NSSize(width:width,height:view.frame.height));view.layoutSubtreeIfNeeded()
      try check(view.subviews.allSatisfy{$0.frame.minX>=0 && $0.frame.maxX<=width+0.1 && $0.frame.height>0},"allControlsFitWidth\(Int(width))")
      let frames=[button("Ricalcola dimensione").frame,button("Gestisci cartelle…").frame,button("Indietro").frame]
      try check(!frames[0].intersects(frames[1]) && !frames[0].intersects(frames[2]) && !frames[1].intersects(frames[2]),"planManageCancelDoNotOverlapWidth\(Int(width))")
    }
    let focusView=GameInstallationView(game:game,variant:variant)
    let fw=NSWindow(contentRect:focusView.frame,styleMask:[.titled],backing:.buffered,defer:false);fw.isReleasedWhenClosed=false;fw.contentView=focusView;defer{fw.close()}
    var intendedPlans=0,unexpectedInstalls=0;focusView.onPlan={intendedPlans+=1};focusView.onInstall={unexpectedInstalls+=1}
    focusView.update(options:options,selected:a,info:GameStorageInfo(),loading:false)
    _=focusView.handleController(.move(.down))
    focusView.update(options:options,selected:a,info:known,loading:false)
    _=focusView.handleController(.activate)
    try check(intendedPlans==1 && unexpectedInstalls==0,"controllerPlanFocusRemainsOnPlanWhenAsyncSizeEnablesInstall")
    try check(!NSApp.isActive && !window.isKeyWindow && NSApp.modalWindow==nil,"ownHiddenInstallationWindowNeverActivatesOrStartsModalUI")
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"fixtureOnly":true,"realGameAccountUserDataOrInstallationTouched":false,"globalInputInjected":false]
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
  }
}
