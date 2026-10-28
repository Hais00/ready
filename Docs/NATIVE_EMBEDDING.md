# Giochi macOS nella finestra Ready: esperimenti Metal indipendenti

Data: 28 ottobre 2026. Mac Apple M1, macOS 27.0.1 (26A434), SDK Command Line Tools locale. Risultato **sperimentale**, senza integrazione nel launcher e senza avviare giochi reali.

**È fattibile far apparire i pixel di un secondo processo nella finestra già esistente dell’host. È stato eseguito, anche tramite shim iniettato nel guest sintetico. I due entitlement abilitano il caricamento dello shim; non trasferiscono una `NSWindow`/`NSView` da un processo all’altro.** Il percorso funzionante qui è inoltro di superfici Metal/IOSurface e composizione nell’host.

## Che cosa è stato costruito ed eseguito

Sorgenti isolati in `NativeEmbedding/`: `Lab.m`, `EmbeddingShim.m`, `LaunchContext.m`, `run_lab.py`, `experiment.py`. Nessun file del launcher, Steam, motore o runtime esistente modificato.

Prodotti, firme, plist, log, immagini CUA, sorgenti esatti e SHA-256 sono sul volume esterno privato:

`/Volumes/Dati APFS/Codex-ready-01a17e79/tests/native-embedding-20261028/`

`NativeEmbeddingHost.app` crea una finestra propria con `CAMetalLayer` **prima** del guest. `NativeEmbeddingGuest.app` normalmente crea una sua finestra indipendente e disegna un triangolo verde; il fondo cambia colore con il contatore frame. Sono bundle distinti, PID distinti, firme ad hoc con hardened runtime. Lo stesso sorgente contiene anche il percorso cooperativo senza finestra guest e il consumatore Metal headless.

| Esperimento reale | Esito e prove |
| --- | --- |
| Guest indipendente + shim AppKit | Costruttore dello shim e intercettazione `NSWindow.init…` eseguiti nel PID del guest. `standalone-injected.txt`; screenshot CUA osservato durante l’esecuzione. |
| Ricerca finestra di altro processo | Host PID 32546, finestra 5658; guest PID 32548, propria finestra 5659; `NSApp.windowWithWindowNumber(5658)` restituisce `nil`, con una sola finestra locale. `foreign-lookup.*`, entrambi exit 0. |
| Reparenting nello stesso processo | Nel PID 32563 una vera `NSView` passa dalla finestra 5661 alla 5662; `view.window.windowNumber == 5662`, rendering successivo funzionante. `local-reparent.*`, entrambi exit 0. |
| Producer/consumer Metal separati, headless | 180 frame, 6/6 campioni validi sul **target Metal del consumer**, dimensioni 640×360 → 800×450 → 1280×720, exit 0/0. `headless.*`. |
| Inoltro cooperativo verso finestra host esistente | 180 frame, 6/6 campioni validi, host PID 32570/finestra 5663 conservati; guest PID 32572 senza `NSWindow`. Risoluzione guest segue dimensioni host/scala. `cooperative.*`, `cooperative.host.cua.png`, exit 0/0. |
| Inoltro tramite **iniezione**, guest non cooperativo | Guest lanciato soltanto con `--frames 180`, senza `--forward`. Lo shim nasconde l’ordine della finestra guest, intercetta `CAMetalLayer.nextDrawable` e il selettore pubblico `presentDrawable:` sulla classe concreta `AGXG13GFamilyCommandBuffer`, aggiunge un blit GPU verso IOSurface e trasmette il diritto Mach. Host PID 32211/finestra 5646 rimane distinto dal guest PID 32215; 180 frame, 6/6 campioni validi, exit 0/0. `injected.*`; immagine CUA `injected.host.cua.png` mostra i pixel del guest nella finestra host. |

Il lookup fallito non costituisce una prova matematica dell’assenza di ogni tecnologia remota in macOS. Dimostra che un numero WindowServer non diventa una `NSWindow` locale utilizzabile dal normale AppKit. [`addSubview`](https://developer.apple.com/documentation/appkit/nsview/addsubview(_:)) richiede un oggetto `NSView`; i due entitlement non espongono oggetti di un altro spazio di indirizzamento. Non è stato passato deliberatamente un puntatore esterno invalido a Objective-C, né usata un’API privata WindowServer. Il test positivo nello stesso processo distingue chiaramente il reparenting locale dal trasporto di pixel.

## Entitlement: firme e caricamento effettivo

[Apple: allow-dyld-environment-variables](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables) abilita le variabili `DYLD_*`; [Apple: disable-library-validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) rimuove il requisito Apple/stesso Team ID per le librerie. Non sono permessi di embedding grafico.

Ogni variante è stata realmente firmata con `codesign`, verificata con `codesign --verify --strict`, e poi eseguita con la nostra dylib ad hoc. Il controllo legge `_dyld_image_count/_dyld_get_image_name`, risolve un simbolo dello shim e registra il costruttore. Non si limita a leggere plist. `matrix.json`, `*.signature.txt`, `*.probe.txt`, `*.dlopen.txt`, `build-and-sign.jsonl` contengono le prove.

| Firma eseguibile proprio | `DYLD_INSERT_LIBRARIES` visibile | Shim effettivamente caricato |
| --- | --- | --- |
| Hardened + entrambi | sì | sì, costruttore + simbolo + immagine dyld |
| Hardened + solo allow-dyld | sì | no, dylib ad hoc rifiutata dalla library validation |
| Hardened + solo disable-library-validation | no | no via ambiente; `dlopen` esplicito proprio funziona |
| Hardened + nessuno | no | no |
| Ad hoc senza hardened runtime, nessuno | sì | sì |

Il probe `dlopen` della variante allow-dyld-only registra esplicitamente il rifiuto per Team ID incompatibili; due firme ad hoc non equivalgono a due prodotti dello stesso team Apple. Con librerie correttamente firmate dallo stesso team, disable-library-validation non è una necessità universale. Gli eseguibili di sistema, le altre restrizioni di firma e le policy di lancio rimangono casi distinti. [Apple descrive il modello Hardened Runtime e il fatto che le librerie ereditano gli entitlement del processo host](https://developer.apple.com/documentation/security/hardened-runtime).

È stata ripetuta la matrice anche con `NSWorkspace.openApplication` e `NSWorkspaceOpenConfiguration.environment`, **per singolo lancio**, senza `launchctl setenv` o modifiche globali: stesso risultato, `nsworkspace.matrix.json` e `*.nsworkspace.probe.txt`. Alcune callback NSWorkspace vedono già PID -1 perché il probe termina immediatamente: il file scritto dal processo registra il suo PID e il simbolo caricato, quindi il risultato non viene dedotto dalla callback.

### L’ipotesi sui giochi Steam

L’intuizione ha una base ufficiale: [Valve, Platforms / macOS](https://partner.steamgames.com/doc/store/application/platforms?l=english) prescrive i due entitlement per il supporto Catalina, per caricare Steamworks/overlay e iniettare l’overlay. Questo rende plausibile trovare queste eccezioni nei giochi Mac moderni; non verifica retroattivamente ogni eseguibile, helper, vecchia build o variante dello store.

È stato ispezionato **soltanto il codice firmato**, senza esecuzione o modifica, del bundle locale `Cyberpunk2077.app`, Steam, sul volume Dati: main executable arm64, hardened runtime, Team ID `PL47UP47QQ`, entrambi gli entitlement presenti, firma Developer ID CD PROJEKT. Ricevuta `cyberpunk-main.signature.txt`. È un esempio positivo concreto, non una misura della copertura dell’intero catalogo. Il client `/Applications/Steam.app` non presenta queste due chiavi: il client non è un controesempio relativo ai giochi e non va confuso con il loro eseguibile principale.

## Dati grafici, sincronizzazione e costi osservati

Percorso cooperativo: il guest rende direttamente in una texture creata con `newTextureWithDescriptor:iosurface:plane:`. Invia `IOSurfaceCreateMachPort`, il consumer importa `IOSurfaceLookupFromMachPort` e crea una texture sullo stesso storage. Il consumer esegue **un ulteriore pass di rendering** che campiona la superficie nel drawable host. Nessun blit full-frame è codificato in questo percorso. [Apple documenta texture su IOSurface](https://developer.apple.com/documentation/metal/mtldevice/maketexture(descriptor:iosurface:plane:)) e [importazione dal diritto Mach](https://developer.apple.com/documentation/iosurface/iosurfacelookupfrommachport(_:)).

Percorso iniettato: il gioco sintetico continua ad acquisire e presentare il suo drawable. Lo shim imposta `framebufferOnly=NO`, aggiunge **un blit GPU completo** dal drawable a una seconda IOSurface, poi l’host compone come sopra. A 640×360 BGRA sono 921.600 byte logici copiati per frame, oltre al pass host. Il guest possiede ancora la sua finestra, nascosta, e il suo ciclo dei drawable. Non sono eliminati i suoi oggetti WindowServer.

Sincronizzazione volutamente conservativa: producer `waitUntilCompleted` oppure completion handler prima del messaggio Mach; consumer attende il proprio command buffer prima dell’ACK; il guest non riusa la superficie prima dell’ACK. Questo evita race nel laboratorio, ma serializza CPU/GPU e processi. Non è una coda di produzione con più buffer o `MTLSharedEvent`. [Apple avverte dei conflitti fra letture/scritture e descrive eventi/fence](https://developer.apple.com/documentation/metal/resource-synchronization); [il suo esempio di readback spiega la perdita di parallelismo dovuta alle attese sincrone](https://developer.apple.com/documentation/metal/reading-pixel-data-from-a-drawable-texture).

| Run finale, 180 frame | Media GPU guest | Media GPU pass host | Media da guest pronto a consumer GPU completato |
| --- | --- | --- | --- |
| Headless, tre risoluzioni fino a 1280×720 | 0,044719 ms | 0,072 ms | 0,493 ms |
| Cooperativo con finestra, fino a 1600×900 | 0,181 ms | 0,276 ms | 2,102 ms |
| Shim, guest 640×360 e host fino a 1600×900 | 0,147 ms, **render + blit insieme** | 0,169 ms | 3,300 ms |

Sono workload piccoli, con dimensioni diverse, rumore di scheduling, inizializzazione e policy drawable. Non permettono di calcolare una percentuale di overhead su un gioco. I timestamp GPU vengono da `GPUStartTime/GPUEndTime`; l’intervallo CPU parte **dopo** il rendering guest e finisce dopo la GPU consumer, non misura input-to-photon, scansione del display o presentazione visibile completata. Le pause artificiali del guest non sono usate come benchmark FPS.

`MTLDevice.currentAllocatedSize` viene registrato per processo e a ogni campione. Massimi **campionati**, non picchi certificati: host cooperativo 18.038.784 B, guest cooperativo 6.504.448 B; host con shim 18.972.672 B, guest con shim 4.472.832 B. Include risorse/allocator del device; importare la stessa IOSurface in due processi non autorizza a sommare questi numeri come memoria fisica distinta. Non sono state misurate bandwidth hardware, allocation di WindowServer o copie interne del driver.

Ogni 30 frame il test controlla il verde al centro e il rosso del fondo uguale all’indice del frame, non soltanto un frame statico ripetuto. Headless controlla il **render target del consumer** tramite `getBytes`; con finestra il probe CPU controlla la superficie importata e lo screenshot CUA verifica la composizione visibile. I pochi byte letti per la verifica non sono il percorso di trasporto frame.

**IOSurface/Metal non dimostrano zero-copy end-to-end, direct scanout o eliminazione di WindowServer.** La finestra host e `CAMetalLayer` restano dentro AppKit/Core Animation; il sistema decide la composizione/presentazione. L’iniezione qui aggiunge esplicitamente una copia GPU. Nessun contatore del display/compositor è stato misurato, quindi nessuna promessa di latenza/bypass globale.

## Resize, input, fullscreen e limiti concreti

- Cooperativo: l’ACK riporta dimensioni in pixel. Sul display con backing scale reale 2 il guest passa da 640×360 a 1280×720, poi 1600×900 dopo il resize della finestra a 800×450 punti. La richiesta esplicita scale=2 nel self-test è **sintetica**, non un passaggio fisico fra monitor.
- Cooperativo: un `NSEvent` sintetico viene gestito dalla view host e il contatore attraversa l’ACK; il guest modifica il colore del triangolo, verificato da pixel rosso 26→38. CUA ha anche inviato un vero click alla view host, registrato come secondo input **dopo** il guest: prova del responder host, non di inoltro live di quel click.
- Shim: riceve e registra dimensioni/input richiesti, ma **non** ridimensiona il gioco e non traduce gli eventi al suo responder. Il guest resta 640×360 mentre l’host scala fino a 1600×900, come mostrano i log. Mouse relativo, pointer capture, tastiera, gamepad, focus, IME e key-up richiedono un adapter verificato; non sono risolti da un entitlement.
- Fullscreen: self-test **dell’host**, sul suo stesso window number 5646, ha registrato entrata `style_fullscreen=1` e uscita `=0`, poi exit 0. Avveniva sul frame finale, dopo la conclusione del guest: nessuna prova di rendering live durante il cambio Space. Un primo loop che pompava solo NSRunLoop non completava correttamente l’uscita; il loop finale pompa gli effettivi eventi AppKit. [Apple descrive fullscreen/Space e callback di transizione](https://developer.apple.com/documentation/appkit/nswindowdelegate). Nessuno Space o finestra di altre applicazioni è stato controllato.
- Lo shim copre solo questo percorso Metal e il selettore `presentDrawable:`. Altri metodi di presentazione, Metal 4, OpenGL, MetalFX/HDR/EDR, formati diversi, swapchain multipli, overlay e finestre ausiliarie non sono validati. Il metodo è pubblico, ma sostituirne l’implementazione su una classe concreta AGX non è un contratto di integrazione Apple e può rompersi con OS, validation layer o engine diversi.
- Il canale Mach usa `bootstrap_register`, disponibile ma **deprecato**: warning conservato nelle ricevute. È un trasporto locale da laboratorio, senza autenticazione del peer/schema robusto, non una nuova infrastruttura pronta per Ready. Un prodotto dovrebbe usare un servizio XPC/Mach configurato, verificare audit token e lifecycle, e gestire crash/restart/timeout.

## Decisione e prossimo test proposto

Per una sola finestra Ready visibile, la strada verificata è **host persistente + inoltro delle superfici + adapter espliciti per input, resize e fullscreen**. Il percorso cooperativo può evitare la copia esplicita intermedia; l’intercettazione del drawable è una base più compatibile con un guest indipendente, ma costa copia/pass aggiuntivi e dipende dal percorso del renderer. Non è un trapianto del suo albero AppKit nel processo Ready.

Caricare un engine direttamente nello stesso processo consentirebbe normale embedding locale, ma richiederebbe un engine/libreria cooperante, gestione di `NSApplication`, main thread e simboli; gli entitlement del gioco non trasformano un eseguibile arbitrario in quel modello.

Proposta successiva, da autorizzare separatamente prima di eseguire un gioco reale: un solo titolo Mac con firma/entitlement e percorso Metal verificati; primo lancio con shim che **registra soltanto** layer, formati, metodi di presentazione e finestre; poi prova temporanea di forwarding per quel titolo con rollback e confronto visivo/frame timing/allocazioni/input/resize/fullscreen/overlay. Nessun re-sign del gioco, patch permanente, modifica globale di `DYLD_*` o elusione SIP/TCC. Il prototipo sintetico non autorizza dichiarazioni di compatibilità del catalogo o di architettura Ready completata.

## Riproduzione e ricevute

Dalla radice repository, con il workspace Dati privato montato e **nessun nostro test app ancora in esecuzione**:

```sh
python3 NativeEmbedding/run_lab.py
python3 NativeEmbedding/experiment.py '/Volumes/Dati APFS/Codex-ready-01a17e79/tests/native-embedding-20261028' headless
python3 NativeEmbedding/experiment.py '/Volumes/Dati APFS/Codex-ready-01a17e79/tests/native-embedding-20261028' foreign-lookup
python3 NativeEmbedding/experiment.py '/Volumes/Dati APFS/Codex-ready-01a17e79/tests/native-embedding-20261028' local-reparent
python3 NativeEmbedding/experiment.py '/Volumes/Dati APFS/Codex-ready-01a17e79/tests/native-embedding-20261028' cooperative --view
python3 NativeEmbedding/experiment.py '/Volumes/Dati APFS/Codex-ready-01a17e79/tests/native-embedding-20261028' injected --view --fullscreen-cycle
```

`--view` mantiene la sola finestra host per 45 secondi dopo i frame; il driver attende e registra gli exit status. Le immagini sono state catturate esclusivamente mediante CUA, non screen capture del launcher. Le prove non usano SIP/TCC override, task port esterni, giochi reali o impostazioni globali di ambiente.

`manifest.json` collega i sorgenti snapshot ai prodotti con SHA-256. `final-rebuild-comparison.json` conferma che i due binari app e lo shim ricompilati/verificati alla consegna hanno **identici hash** rispetto ai binari delle prove finali. `build-and-sign.jsonl` conserva comandi, esiti e warning. I file `*.result.json` sono le ricevute primarie per le cinque modalità sopra; vecchi file esplorativi `window.*`/`standalone.*` non sostituiscono queste ricevute. Tutti i PID delle modalità finali sono terminati; nessuna finestra sintetica è stata lasciata aperta.
