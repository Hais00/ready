// SPDX-License-Identifier: GPL-3.0-only
import AppKit

private final class DownloadRows: NSView { override var isFlipped:Bool{true} }
private final class DownloadControl:NSButton {
  var invoke:(()->Void)?
  init(_ title:String,_ action:@escaping()->Void){super.init(frame:.zero);self.title=title;bezelStyle = .rounded;invoke=action;target=self;self.action = #selector(run)}
  required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
  @objc private func run(){invoke?()}
}
@MainActor final class SteamDownloadsView:NSView,ReadyDialogContentSizing {
  nonisolated var maximumViewportHeight:CGFloat{460}
  var onControl:((String,String)->Void)?
  var titleForGame:((String)->String)?
  private let scroll=NSScrollView(), rows=DownloadRows()
  private var lastJobs=[SteamDownloadJob]()
  private var renderedWidth:CGFloat = -1
  override init(frame:NSRect){
    super.init(frame:frame);scroll.frame=bounds;scroll.autoresizingMask=[.width,.height]
    scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.documentView=rows;addSubview(scroll)
  }
  required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
  override func layout() {
    super.layout()
    if abs(renderedWidth-bounds.width)>0.5 { render(lastJobs) }
  }
  func update(_ jobs:[SteamDownloadJob]) {
    lastJobs=jobs;render(jobs)
  }
  private func render(_ jobs:[SteamDownloadJob]) {
    renderedWidth=bounds.width
    rows.subviews.forEach{$0.removeFromSuperview()}
    let width=max(200,bounds.width-20)
    rows.frame=NSRect(x:0,y:0,width:width,height:bounds.height)
    if jobs.isEmpty {
      let label=NSTextField(wrappingLabelWithString:"Nessun download. Seleziona un gioco e scegli la versione macOS o Windows da installare.")
      label.frame=NSRect(x:4,y:15,width:width-15,height:60);rows.addSubview(label);return
    }
    let states=["queued":"In coda","running":"Download in corso","preparing":"Preparazione","downloading":"Download in corso","verifying":"Verifica dei file","paused":"In pausa","completed":"Installato e verificato","failed":"Errore","cancelled":"Annullato · file conservati","retry_wait":"Attesa rete","authorization_required":"Accesso Steam richiesto","interrupted":"Download interrotto"]
    var top:CGFloat=0
    for job in jobs {
      let title=NSTextField(labelWithString:(titleForGame?(job.gameID) ?? job.gameID)+" · "+job.platform)
      title.font = .systemFont(ofSize:14,weight:.semibold);title.frame=NSRect(x:4,y:top,width:width-10,height:22);rows.addSubview(title)
      var text=states[job.state] ?? job.state
      if let completed=job.completed {text += " · "+ByteCountFormatter.string(fromByteCount:completed,countStyle:.file)
        if let total=job.total{text += " / "+ByteCountFormatter.string(fromByteCount:total,countStyle:.file)}}
      if let error=job.error{text += " · "+error}
      let status=NSTextField(labelWithString:text);status.frame=NSRect(x:4,y:top+23,width:width-10,height:20);rows.addSubview(status)
      let progress=NSProgressIndicator(frame:NSRect(x:4,y:top+49,width:width-12,height:10))
      progress.style = .bar;progress.isIndeterminate=job.fraction==nil;progress.minValue=0;progress.maxValue=1
      if let fraction=job.fraction {progress.doubleValue=fraction}else if ["running","preparing","downloading","verifying"].contains(job.state){progress.startAnimation(nil)}
      rows.addSubview(progress)
      var controls=[(String,String)]()
      if ["running","preparing","downloading","verifying","queued","retry_wait"].contains(job.state){controls.append(("Metti in pausa","pause"))}
      if ["paused","interrupted"].contains(job.state){controls.append(("Riprendi","resume"))}
      if ["failed","retry_wait"].contains(job.state){controls.append(("Riprova","retry"))}
      if !["completed","cancelled"].contains(job.state){controls.append(("Annulla download","cancel"))}
      let columns=max(1,Int((width-4)/160))
      for(i,control)in controls.enumerated(){let button=DownloadControl(control.0){[weak self]in self?.onControl?(job.id,control.1)};button.frame=NSRect(x:4+CGFloat(i%columns)*160,y:top+69+CGFloat(i/columns)*34,width:150,height:30);rows.addSubview(button)}
      top += max(115,81+CGFloat((controls.count+columns-1)/columns)*34)
    }
    rows.setFrameSize(NSSize(width:width,height:max(bounds.height,top)))
  }
}
