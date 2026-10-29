<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Fullscreen nativo della finestra Ready

Il percorso sperimentale `--host-game-view <storeID>` usa il fullscreen nativo di AppKit sullo stesso `NSWindow` di Ready. La finestra dichiara `fullScreenPrimary` e `fullScreenDisallowsTiling`; `toggleFullScreen` avvia la transizione. Il controller attende `didEnterFullScreenNotification` prima di creare l'host grafico e restituire il lease che consente l'avvio del gioco. L'interfaccia già renderizzata resta visibile durante l'animazione e sopra la superficie host fino al primo `PRESENT` valido, completato dalla GPU del guest.

Il fullscreen viene mantenuto al ritorno alla libreria e dopo un avvio fallito. Un'uscita esplicita usa la transizione inversa di AppKit. Cancellazione e timeout non concedono lease tardivi: una transizione che si conclude dopo la cancellazione può lasciare Ready nel proprio Space, ma non avvia il backend o il gioco. Il delegate inoltra anche il fallimento della transizione, che AppKit non pubblica come notifica separata. Il timeout interno è di 10 secondi, inferiore al limite di preparazione del gestore sessioni.

Non si usano `CGDisplayCaptureWithOptions`, finestre di schermatura, livelli sopra lo shield o ridimensionamento manuale al rettangolo del display. Il precedente flag `--exclusive-hosted-view` non prevale sulla richiesta di Space nativo: il receipt registra `captureSuppressedForNativeSpace`. Uno Space fullscreen, il confinamento del puntatore e la composizione indicata da Metal HUD sono proprietà distinte. Nessuno di questi, da solo, prova un percorso di visualizzazione diretto o l'esclusività fisica del display.

Il controller abilita il puntatore dell'host solo dopo il primo frame e con fullscreen concluso, finestra key, applicazione attiva e Space visibile. Lo disabilita prima dell'uscita dal fullscreen, durante le transizioni, su perdita di focus/sessione e allo stop. Le guardie del C host verificano indipendentemente le condizioni di acquisizione. Il canvas di caricamento conserva la grafica ma non accetta interazioni; lo stato precedente viene ripristinato alla chiusura della presentazione.

`Scripts/test_hosted_fullscreen.py` compila il controller Swift reale con un driver controllato delle notifiche e un host C sintetico. Verifica che non vengano creati host/lease prima dell'ingresso, le transizioni già concluse, cancellazione, timeout, richieste concorrenti, eventi tardivi, ripristino dell'interazione e passaggio atomico dal canvas al primo frame. Non mostra finestre, non cambia Space, non cattura il display, non usa account, SDK Steam o giochi. La prova visiva di Mission Control, geometria degli angoli, input e presentazione su GPU resta distinta da queste fixture.

Fonti primarie: [Apple: toggleFullScreen](https://developer.apple.com/documentation/appkit/nswindow/togglefullscreen(_:)), [fullScreenPrimary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenprimary), [didEnterFullScreenNotification](https://developer.apple.com/documentation/appkit/nswindow/didenterfullscreennotification), [windowDidFailToEnterFullScreen](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowdidfailtoenterfullscreen(_:)). Il contratto è verificato anche nell'header `NSWindow.h` del MacOSX SDK locale: la finestra deve essere primary/auxiliary per `toggleFullScreen`, e il delegate riceve i fallimenti anche senza animazione personalizzata.


## Evidenza provvisoria del 29 ottobre 2026

Una prova propria ha eseguito la transizione AppKit reale: fullscreen nativo e
driver attivi all'ingresso, `fullScreenPrimary` e `fullScreenDisallowsTiling`
veri, appartenenza allo Space attivo, finestra 8626 preservata e livello 0.
L'uscita nativa è stata osservata. Il rapporto è
`WORK/tests/ready-native-space-eszc2xz_/report.json`, SHA-256
`f8a77a9c009b8cc665887cce101a162f9fa19983f743fefd90e000c7d285180b`.
Non sono stati usati account, SDK Steam o giochi.

Il blocco precedente da 41 controlli rimane storico. Il controller reale passa
ora 47 controlli, compresi sei casi aggiuntivi di eligibility e ripristino del
puntatore dopo uscita fullscreen fallita:
`WORK/tests/hosted-fullscreen-maqzqkqj/report.json`, SHA-256
`6399d0b04bfedcd6be67762e602761309f123af1146241d1f756b6afe0ce98e3`.
Queste fixture non eseguono una transizione Space reale né la GPU di produzione.

Mission Control non è ancora verificato visivamente: l'ispezione AX del Dock è
andata in timeout. Una cattura CUA della sola finestra propria con margini
bianchi non prova gli angoli del display. Non viene aggiunto o dedotto un raggio
privato o una maschera estetica. Il recupero completo focus/Space/sessione resta
non certificato; i risultati live parziali del puntatore sono distinti sotto.

Il [checkpoint provvisorio separato](../Validation/ready-hosted-native-space-checkpoint.json)
mantiene questi risultati separati dalla precedente sessione commerciale da
7.038 PRESENT: quella resta [storica e relativa al display-fill/capture](../Validation/ready-hosted-presentation-checkpoint.json).


## Prova live parziale precedente: cursore video fermo (v2)

La sessione Ready 8704 / guest 8740 mantiene la finestra 8699 prima e dopo
l'ingresso, con fullscreen nativo e copertura del display veri, senza cattura
fisica del display. La presentazione commerciale prosegueva oltre 13.000 frame;
il prefisso sicuro successivamente salvato ne osserva almeno 26.760. Il Metal HUD
riporta **Composited**. Root ha osservato le impostazioni del gioco; lo screenshot
privato conservato mostra invece l'intro, non quella schermata successiva.
Questa è una sessione parziale, senza esito di uscita finale in questo checkpoint.

Il journal registra acquisizione, rilascio e riacquisizione del puntatore con
`pointerError=0`. L'utente conferma cursore macOS nascosto e input di tastiera e
mouse funzionante nell'interazione osservata. **Il cursore video di Cyberpunk
rimane però fermo: la posizione assoluta non è completa e il bug resta aperto.**
Questa osservazione precede la correzione v3 descritta sotto e resta storica.
Non è autorizzata una dichiarazione generale di mouse risolto.

Passano anche 14 controlli CPU del puntatore, 8 dello shim e una prova offscreen
di 30 frame con 15 controlli; build e 14 controlli di relocation passano per la
versione esaminata. Questi risultati non trasformano la prova parziale in
certificazione di gameplay, controller, Mission Control visivo o angoli fisici.
Il [checkpoint](../Validation/ready-hosted-native-space-checkpoint.json) conserva
hash separati per fixture, prefisso live sicuro e screenshot non pubblicato.

## Correzione v3 confermata: parità input e performance ancora aperte

Il protocollo v3 trasporta la posizione virtuale globale in una cache coerente
del guest. L’adattamento caller-scoped di `NSEvent.mouseLocation` usa questa
cache, senza IPC o query al getter originale del framework; i callsite del
main executable sono stati riscontrati staticamente. La build corretta passa
14 controlli CPU del puntatore, 11 dello shim, 30 frame/15 controlli GPU
offscreen e 14 controlli di relocation. L’esecuzione offscreen precedente
`nxp59w4y` resta conservata come arresto della guardia di attivazione: il
processo di prova era diventato attivo dopo la chiusura di Ready; non è
riportata come un guasto del prodotto.

Il nuovo candidato live Ready 10290 / guest 10337 presenta almeno 120 frame
con puntatore acquisito e `pointerError=0`, secondo il journal osservato.
**L’utente conferma che la freccia video di Cyberpunk ora segue il movimento:**
il bug della posizione osservato nel v2 è risolto in questa interazione. Resta
aperto un feeling diverso dell’input; una possibile curva di sistema è solo
un’ipotesi. L’utente segnala anche stutter evidente e valori circa 37,72 nativo
contro 34 hosted: non è un benchmark controllato e non stabilisce una causa.
Non si certificano parità input/prestazioni, compatibilità mouse generale o
gameplay completo. Space e angoli non hanno una nuova conferma manuale.

## V4: build verificata, confronto live ancora pendente

Il [checkpoint performance separato](../Validation/ready-hosted-performance-checkpoint.json)
lega il confronto dei CSV del motore a impostazioni uguali: 37,71597 FPS nativo
contro 34,20225 hosted v3, −9,3163% e +2,723 ms medi. Non sono intervalli di
presentazione sul display. Il profilo reale pre-v4 riguarda intro/titolo e
mostra VSync guest falso/host vero, non un risultato successivo alla correzione.
La build v4 e relocation14 passano insieme alle fixture mirate; il nuovo
avvio non ha ancora frame v4 verificati, dopo timeout CUA e richiesta unlock.
Stutter, feeling e parità input/prestazioni restano aperti. Le evidenze v3
precedenti non sono usate come prova di recupero v4.
