<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Audit della pipeline hosted — 29 ottobre 2026

## Prove CLI del 30 ottobre: VSync e attese concorrenti

L'utente ha autorizzato nuove prove automatiche del gioco, avviate e seguite
esclusivamente da CLI, con Metal HUD acceso, logging HUD disattivato e senza
acquisizione dello schermo. Questo supera il precedente vincolo delle prove
manuali riportato nelle sezioni storiche. Il benchmark interno `-benchmark`
esporta `summary.json` e `frames.csv`; gli argomenti temporanei del profilo
vengono ripristinati dopo le prove. Il comando esplicito
`ready --launch-installed-game steam:1091500` usa lo stesso percorso di profilo,
licenza e sessione del pulsante Gioca, e non installa versioni mancanti.

Con VSync 60, 1920×1200 e impostazioni esportate identiche, il nativo ha misurato
36,9237 FPS. Due controlli hosted hanno misurato 29,8781 e 29,9164 FPS. Il secondo
usa gli stessi binari dopo il rilascio del precedente contesto di controllo UI.
Il valore 60 è un limite richiesto, non una garanzia che la GPU renda questa
scena a 60 FPS; il difetto riprodotto è l'ulteriore gradino hosted a circa 30.

La traccia mostra `displaySyncEnabled=true` e richieste
`presentAfterMinimumDuration` da 16,666667 ms: non una richiesta del gioco di
limitarsi a 30. Nella sessione osservata ACQUIRE attende circa 22 ms medi dentro
`nextDrawable`; la lane RPC condivisa trattiene PRESENT per circa 6,18 ms medi.
Le medie della traccia comprendono l'intera sessione, mentre gli FPS derivano
dall'esportazione del solo benchmark.

La candidata separa la receive-port/mutex ACQUIRE dalla lane controllo/PRESENT.
L'host riserva l'acquisizione su Main, attende `nextDrawable` su un worker CPU,
poi pubblica la superficie su Main e risponde usando il diritto send-once
originale. Main, il server e PRESENT restano disponibili durante l'attesa.
Generazioni, arresto, riconfigurazione e rilascio dei diritti Mach hanno prove
con il server reale. Protocollo V6, due crediti, ordine FIFO e restituzione del
credito dopo fence GPU e ACK restano invariati. Non vengono aggiunti buffer
d'immagine, code GPU, copie o readback nel percorso di produzione.

La prima misura della candidata è 34,8874 FPS, con attesa media del lock PRESENT
di circa 0,00446 ms. È un recupero parziale: il nativo rimane più veloce e i picchi
del frametime richiedono altre verifiche. Non è una prova di costo zero o di
eliminazione dello stutter.

Una cache opt-in di tre wrapper texture importati (`RHG_TEXTURE_CACHE=1`)
conserva le stesse IOSurface del pool e invalida dopo il drain della
configurazione. La prova reale di riciclo presenta 48 frame con tre importazioni
e 45 riutilizzi; quella nel gioco registra 1316 hit e quattro importazioni su
1320 richieste, massimo tre entry. Il costo combinato lookup/wrapper scende
da circa 0,41 a 0,024 ms medi, ma il benchmark resta a 34,9746 FPS. Il risparmio
CPU non dimostra un recupero equivalente degli FPS. La cache resta disattivata
per default durante la validazione.

Un percorso separato, `--host-game-transport remote-layer`, lascia al guest
layer, drawable e code Metal originali e presenta il suo albero tramite
`CAContext`/`CALayerHost`. Non scambia superfici o PRESENT applicative per ogni
frame. Gli hook temporanei di avvio si rimuovono al primo timestamp positivo;
le correzioni input/sessione restano condivise. I probe fra due processi con
Metal 3 e Metal 4 (`present`) confermano GPU e presentazione visibile senza
finestre guest. Le primitive sono SPI private del sistema, non codice Apple
redistribuito; [WebKit](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Platform/cocoa/LayerHostingContext.mm)
documenta un impiego del medesimo modello di hosting.

Questo percorso non è ancora accettato in Cyberpunk: l'avvio incontra otto
drawable distinti con timestamp zero e termina conservando la schermata di
caricamento. Geometria, collegamento del contesto, finestra/Space e focus sono
validi nelle tracce. Le prove Metal 4 con durata minima falliscono anche nel
controllo locale, mentre `present` funziona: non è una prova di un difetto
specifico del contesto remoto né una giustificazione per cambiare l'API del
gioco. Si verifica prima il riscaldamento iniziale della run nativa.

Le esportazioni misurano tempi del motore. Non certificano direct scanout,
assenza di compositing interno del sistema, latenza input o costo letteralmente
nullo. Nessuna cattura dello schermo viene usata per le misure correnti.

La diagnostica opt-in duplica il descrittore stderr ereditato prima che il gioco
lo sostituisca; il duplicato è CLOEXEC. Le scritture restano asincrone e limitate.
Con profilazione disattivata non viene aperto il descrittore. Controlli con
`freopen`, exec, pipe piena e consumatore chiuso verificano questo confine.

Il consumer nativo usa `CAMetalDisplayLink`, con preferenza 60 nell'intervallo
30–60 e latenza preferita 2. Non è `CADisplayLink`. Questi valori non vengono
alterati dalla candidata. Le modifiche alla cadenza o all'anticipo della
presentazione non devono essere dedotte dai soli test sintetici.

## Aggiornamento del 30 ottobre: stutter, input e ritorno

Il percorso attuale conserva la pipeline GPU con crediti limitati e ACK dopo
la PRESENT corretta: nessun anticipo del fence o copia aggiuntiva delle superfici.
Il polling input salta un tentativo quando la transazione RPC è occupata dal
rendering, mantenendo la singola reply-port protetta. La prova di completamento
verifica anche 128 tentativi a lock occupato senza inviare nuove richieste.

La verifica CoreGraphics della sessione console gira su una coda indipendente,
con refresh a 100 ms, età massima 350 ms e invalidazione immediata sugli eventi
di sessione/focus/Space/schermo. I controlli AppKit, frontmost e dell’eseguibile
peer restano freschi; una prova mancante, scaduta o invalidata nega la cattura.
Un risultato asincrono obsoleto non può riabilitarla. Il percorso POLL/mouse non
effettua più una query WindowServer della sessione per ogni pacchetto.

Serializzazione e scrittura del journal host sono asincrone e limitate a 64
record pendenti. Il journal periodico ogni 120 frame è ora legato alla diagnostica
prestazioni opt-in; non trattiene l’ACK dei frame durante il normale gioco.

Le prove controllate verificano una console-provider lenta, un writer bloccato,
scadenza/revoca e completamenti GPU/Mach con backpressure. Non dimostrano la
scomparsa dello stutter in Cyberpunk: il benchmark e il gesto fisico restano
all’utente. Per scroll/cursore e ritorno, vedere [focus/input](HOSTED_SCROLL_FOCUS.md),
[ripristino libreria](NATIVE_LIBRARY_RETURN.md) e [checkpoint](../Validation/hosted-native-interaction-checkpoint.json).

## Audit storico

La prima sezione conserva l’audit storico iniziale in sola lettura; le sezioni successive documentano implementazioni e prove distinte. Audit iniziale in sola lettura. Nessuna modifica di produzione, esecuzione del gioco, acquisizione del mouse/display, build globale o misurazione GPU eseguita da questo agente. Il confronto riferito dall'utente (37,72 FPS nativo contro circa 34 FPS hosted) equivale aritmeticamente a −9,86% e a un intervallo medio teorico da 26,51 a 29,41 ms, cioè circa +2,90 ms. Non è un benchmark A/B controllato né una misura della causa. Lo stutter richiede distribuzioni dei tempi e non si descrive con la sola media FPS.

Sorgenti ispezionati: `NativeEmbedding/ReadyHostedGameShim.m`, `Sources/ReadyHostedView/ReadyHostedView.m` e `Sources/ReadyHostedView/include/ReadyHostedGameProtocol.h`, protocollo 3. Fingerprint letti durante l'audit: shim `94833ebbd16ecf953a0685a58c2b90d519166d59f8b7f04f119da6be6bc86ecb`, host `01085dab3dd11b29856e5c111e57c35ca9463112e35f1b3635791cebb778df42`, protocollo `053b8d7f838e794f31ba9422f748f5af4937791a3bb245d5adbe12321bc1315f`. L'agente input possiede modifiche contemporanee nelle sezioni mouse/POLL; questi fingerprint descrivono il punto letto, non congelano una futura build.

## Fatti verificabili nel codice

1. **Un solo frame può avanzare.** `rhgConnect` crea `rhgFrameAvailable` con valore 1. `rhgNextDrawable` prende il credito prima di ACQUIRE. Lo restituisce solo `rhgTryPresent`, dopo completamento GPU, richiesta PRESENT sincrona e ACK del present effettivo dell'host. Il layer host ha `maximumDrawableCount=3`, ma ciò non consente due frame guest contemporanei. L'acquisizione/import del frame successivo non può sovrapporsi alla GPU del precedente attraverso questa barriera. L'entità della perdita reale dipende anche dal lavoro che il motore svolge prima di chiedere il drawable.
2. **Input e rendering condividono il collo IPC.** `rhgExchange` tiene `rhgRPCLock` per send e receive su un solo reply receive-port. POLL ogni 16 ms, richieste pointer sincrone, ACQUIRE e PRESENT competono per la stessa transazione. Il callback GPU che deve liberare il credito può aspettare dietro un POLL o una richiesta cursor; viceversa ACQUIRE può ritardare l'input. Non si può assegnare a questo un numero fisso di millisecondi senza strumentazione.
3. **Il server rende seriale anche il Main thread.** `RHGServe` riceve una richiesta alla volta e ne esegue la gestione con `RHGMainSync`. ACQUIRE chiama `nextDrawable` dentro quel blocco. Quando non c'è un drawable disponibile, Main, il server e la risposta IPC attendono insieme; input, timer pointer e callback UI non possono proseguire su Main. Apple documenta questa attesa e il timeout predefinito fino a un secondo. È head-of-line blocking concreto; non è stata dimostrata una dipendenza circolare che produca un deadlock permanente. [Apple: nextDrawable](https://developer.apple.com/documentation/quartzcore/cametallayer/nextdrawable())
4. **Il completion handler Metal 2 effettua IPC bloccante.** `rhgBufferPresent` chiama `rhgTryPresent` dal completion handler. Ciò può trattenere il thread dei callback e il chiamante di `waitUntilCompleted`, che aspetta anche il termine degli handler. Apple raccomanda di rinviare il lavoro bloccante a un altro thread. La correttezza del requisito GPU-complete è preservata, ma l'attesa di rete locale non deve essere lavoro del callback GPU. [Apple: waitUntilCompleted](https://developer.apple.com/documentation/metal/mtlcommandbuffer/waituntilcompleted()), [Apple: command completion handlers](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Cmd-Submiss/Cmd-Submiss.html)
5. **Il percorso Metal 4 alloca sincronizzazione per ogni frame.** `rhgSignalDrawable` crea un nuovo `MTLSharedEvent` e un nuovo listener sul global queue per ogni segnale, usando sempre valore 1. La callback termina residency, marca GPU complete e chiama PRESENT sincrono. L'evento/listener sono candidati a riuso per coda con valori monotoni; prima serve misurare quanto costano creazione e consegna del callback. Il codice non crea un command buffer aggiuntivo: il segnale è sulla coda del gioco. [Apple: GPU/CPU shared events](https://developer.apple.com/documentation/metal/synchronizing-events-between-a-gpu-and-the-cpu)
6. **Import e residency sono ricreati per frame.** Dopo ACQUIRE: IOSurface lookup dal Mach port, nuovo texture descriptor, `newTextureWithDescriptor:iosurface:plane:`, nuovo residency-set, add/commit/request. Il set viene terminato solo dopo il fence GPU e la surface resta trattenuta dal drawable proxy. Questo ordinamento deve restare corretto. È costo potenziale di allocazione/import, non una copia dei pixel; nessuna misura ne dimostra ancora la quota di tempo.
7. **Esiste lavoro accessorio ripetuto.** Ogni `rhgNextDrawable` richiama `rhgInstallDevice` e i lookup/hook per i factory delle code. Metal 2 controlla tre hook per ogni command buffer creato dal gioco. Il lookup dell'IMP originale usa lock, stringhe e dizionario. Dal lato host, `RHGFill` fa riconciliazione pointer, geometria AppKit e guardie di foreground anche per le richieste grafiche; POLL ripete la guardia per il focus. Vanno contati e temporizzati prima di rimuovere qualunque controllo di sicurezza. La transazione `presentsWithTransaction=YES` riguarda soltanto il primo frame, quindi non è un costo continuo del loop.

## Prima modifica proposta: misurare le attese, senza cambiare profondità

Strumentazione esplicita e disattivata di default; durate monotone, nessun timestamp civile, account, token, testo tasti, posizione/delta input, nonce o path personale nei campioni. Aggregare in memoria e inviare un riepilogo limitato ogni 120 frame o al termine tramite writer seriale; nessun write/fsync per frame sul Main thread. Istogrammi a memoria fissa (per esempio 64 bucket), count/sum/max/p50/p95/p99 approssimati e unità dichiarate. Non chiamare “GPU time” una misura CPU di attesa del fence.

| Punto | Misure separate |
| --- | --- |
| Guest ingresso nextDrawable | attesa credito frame; tempo dall'ACK precedente al nuovo ACQUIRE |
| Guest IPC per op | attesa mutex, durata send, durata receive; conteggi POLL/pointer/ACQUIRE/PRESENT |
| Host server | attesa enqueue→inizio Main, durata `RHGFill`, durata specifica op e send reply |
| Host ACQUIRE | tempo solo `nextDrawable`, creazione Mach port, slot occupati e timeout/nil |
| Guest import | IOSurface lookup, creazione texture, creazione/commit/request residency, hit/miss eventuale cache |
| Guest fence | callback entry→PRESENT enqueue, attesa enqueue→worker, PRESENT roundtrip, durata callback totale |
| Metal 4 | creazione evento/listener, intervallo CPU signal-submit→callback, numero valori in attesa per coda |
| Presentazione | intervallo tra chiamate present; eventuali `presentedTime`/skip osservati separatamente e non confusi con ACK |

Usare `mach_continuous_time` con timebase esplicita per durate CPU e istogrammi. Le misure GPU Metal 2 `GPUEndTime-GPUStartTime` restano un dato separato. Il percorso Metal 4 attuale non dispone dello stesso campione: `gpuSeconds==0` non prova GPU gratuita. Non sottrarre clock GPU/CPU differenti senza aver verificato la loro correlazione. Riportare anche profondità massima effettiva, acquisizioni, fence conclusi, present chiamati e rilasci: devono concordare al drain.

## Riduzioni ordinate per rischio

- **Deferral bounded del PRESENT.** Il callback fa solo il minimo aggiornamento di stato e accoda una sola volta un record che trattiene fortemente drawable/texture. Un worker seriale effettua RPC e valida identità/ACK, quindi restituisce il credito. Lo stesso percorso copre il caso in cui `presentRequested` arrivi dopo il callback GPU. Nessun present prima del fence, nessun ACK simulato, nessun rilascio anticipato della residency. Mantiene un frame in volo, quindi può migliorare le attese del motore ma aggiunge un hop di scheduling: non promette da solo recupero FPS.
- **Riuso evento/listener Metal 4 per coda.** Stato associato alla coda reale, valori monotoni distinti, callback per frame e device/queue identity verificata. Nessuna coda o command buffer host aggiuntivo. Non condividere un unico contatore senza ordinamento tra code differenti; teardown solo dopo i fence pendenti.
- **Ridurre lookup/hook e snapshot ripetuti.** Segnare classi già installate senza lookup a ogni command buffer e usare IMP originali tipizzati conservati. Una snapshot di geometria immutabile per generazione può evitare conversioni AppKit per ogni op. Le guardie di autenticità del peer e di sicurezza pointer restano indipendenti: una cache non deve trasformare una vecchia eleggibilità in un permesso permanente.
- **Separare controllo/input e grafica.** Reply port per transazione/canale e requestID atomici rimuovono il mutex globale, ma non bastano se il server aspetta ancora Main/nextDrawable per ogni messaggio. ACQUIRE deve uscire dal Main thread e non monopolizzare il loop ricevente, con layer/configuration generation immutabile per l'acquisizione. Per ogni completamento verificare ancora stop/generazione prima di esportare la surface. Con timeout Apple di un secondo si può rifiutare e ripulire una risposta tardiva; non abilitare un'attesa infinita. Servono risposte esatte e una coda bounded, non invii “fire-and-forget”.
- **Cache import limitata alla pool.** Solo dopo misure: chiave composta da generazione, IOSurface trattenuta/identità, device, formato, dimensioni, plane e usage. Non fidarsi del solo IOSurfaceID (può essere riutilizzato). Non trattenere il CAMetalDrawable host nella cache. Residency e texture non vanno terminate/evitte mentre un fence guest le usa; limitare gli slot e invalidare al drain per resize/configure. Il riuso va provato con raster/readback realmente alternati sulle surface, non solo con un test della mappa cache.

## Due frame in volo: modifica successiva, non un valore del semaforo

Non basta cambiare `dispatch_semaphore_create(1)` in 2 o 3. L'host conserva **un solo** `host.drawable`/surfaceID e incrementa frameID al PRESENT, non all'ACQUIRE. Il protocollo attuale risponde BUSY o può assegnare identità improprie se lo si aggira. Il requisito è una tabella bounded di slot con frameID monotono allocato all'ACQUIRE, generazione di configurazione, surfaceID, drawable host e stato di completamento/rilascio.

Partire da profondità 2, lasciando la pool Core Animation a 3. Ogni surface resta del proprio slot fino al GPU-complete e al present corretto; il credito del relativo frame torna solo dopo l'ACK previsto. Fence completati fuori ordine devono essere conservati e presentati secondo l'ordine esplicito senza bloccare il loop server in attesa di un messaggio precedente. Resize/configure richiede drain o generazione isolata: nessun cambio dimensioni mentre slot vecchi sono usati. La profondità 3 è un confronto successivo di throughput/latency e memoria, non il default presunto migliore.

Test richiesti prima di promozione: slot 2/3 pieni e backpressure; identità tutte distinte; fence N+1 prima di N; doppio PRESENT e surface sbagliata rifiutati; nessun present prima del fence; configurazione durante uso; release/eviction esattamente una volta; stop durante acquire e GPU; nessuna esportazione tardiva dopo stop; frame timeout senza perdita di credit/right; queue/device distinti; riuso IOSurfaceID tra generazioni; drain contatori coerente. Questi test devono esercitare il nuovo codice reale. Un modello sintetico non dimostra correttezza GPU. Poi probe GPU con colori/sequence alternati e readback nel solo test, contatori produzione zero copie/host command buffer, e confronto A/B ripetuto della stessa scena con mediane e p95/p99. Nessuna ottimizzazione sopra è implementata o approvata da questo audit.

## Passo implementato dopo l'approvazione di Root

Il successivo intervento autorizzato implementa soltanto profiler e deferral del PRESENT, mantenendo un solo frame in volo. `RHG_PERF_PROFILE=1` abilita contatori e clock; senza il flag il profiler non legge clock né emette riepiloghi; restano i log diagnostici preesistenti. Il callback Metal 2 marca il fence concluso e accoda il lavoro; anche il listener Metal 4 usa il worker seriale posseduto. Il worker mantiene il riferimento forte al drawable, termina la residency dopo il fence, esegue il vero PRESENT RPC, verifica frame/surface e soltanto dopo l'ACK restituisce il credito. Nessun nuovo command buffer, encoder, copia o modifica del protocollo 3. Eventi, texture e residency non sono stati trasformati in cache e la profondità non è stata aumentata.

Il nuovo header originale `RHGPerformance.h` mantiene istogrammi fissi a 64 bucket log2 in nanosecondi con somma/count/max, intervalli invalidi e saturazione espliciti. p50/p95/p99 sono **limiti superiori approssimati dei bucket**, non percentili esatti: per piccoli confronti usare anche la media esatta `sumNs/count`. Le statistiche sono cumulative; tra due snapshot si possono sottrarre count/sum e ogni bucket, non sottrarre max o percentili. Startup, Alt-Tab, lock e cambi Space possono contribuire: Root deve selezionare l'intervallo del benchmark mediante il journal dei present e i riferimenti temporali del test.

Ogni 120 ACK guest/present CALLS host viene copiata una snapshot e accodata la serializzazione su un writer separato, con al massimo un report pendente per lato e limite JSON di 64 KiB. Nessun I/O per frame. L'host aggiunge un handler per ogni drawable soltanto con profiling attivo; quel callback aggiorna esclusivamente contatori/istogramma sotto lock. Timestamp positivo, zero/skipped-no-timestamp, dato invalido e arrivo non crescente restano distinti. Una sequenza di callback non crescente non dimostra, da sola, ordine visivo invertito. Il report non contiene timestamp dei singoli frame, coordinate, input, account o capability. HostPID/guestPID, elapsedMilliseconds e presentCalls permettono a Root di associare il riepilogo alla propria prova.

I report aggiungono `guestLayerDisplaySyncEnabled` e `hostLayerDisplaySyncEnabled`: la configurazione v3 non propaga ancora questa proprietà dal layer guest all'host. Un'eventuale differenza è una causa da verificare nel gioco reale, non è stata dedotta dal solo menu VSync. Il profiler non cambia questa proprietà. I CSV che Root ha successivamente verificato riportano media motore 26,5156 ms nativa contro 29,2386 ms hosted (circa +2,723 ms), con p95 rispettivamente 33,60/34,15 ms e p99 35,05/36,15 ms a impostazioni corrispondenti. Questo non misura ancora gli intervalli di effettiva presentazione del drawable host.

Verifiche: 26 controlli dell'header con clock controllato/timebase, limiti, quantili, overflow, timestamp display invalidi/zero/non crescenti; 20 controlli delle funzioni shim reali con Mach IPC e ACK deliberatamente trattenuto; due controlli negativi su identità del PRESENT e errore GPU; verifica del JSON bounded e privo di campi sensibili. Il produttore del callback ritorna mentre l'ACK è ancora bloccato, e il credito non torna anticipatamente. Le chiamate GPU sono sostituite soltanto nella fixture privata; non c'è esecuzione di account, SDK, gioco o input fisico. Le suite CPU esistenti shim11/pointer14/input15 passano.

La prova transport offscreen su shim compilato e firmato esclusivamente in Dati è stata fermata dalla propria guardia foreground a zero frame: il processo harness risultava active/key e ha terminato soltanto il proprio guest. Non è un PASS GPU e non è stata aggirata la guardia. Root eseguirà la prova grafica e il confronto reale dalla build finale controllando il foreground. Ricevuta unit finale: `Evidence/hosted-performance-tests.json`; nessun miglioramento FPS o risoluzione dello stutter è ancora dichiarato.

## Correzione VSync successiva — protocollo 4

Il profiling reale di Root ha confermato nello stesso gioco `guestLayerDisplaySyncEnabled=false` e `hostLayerDisplaySyncEnabled=true`. È una differenza effettiva della configurazione di presentazione; non dimostra da sola quanta parte del costo medio o dello stutter produca. Il protocollo 4 usa il precedente campo request `reserved2` come `displaySyncEnabled` e aggiunge un ACK tipizzato nella reply. Il server rifiuta valori oltre 1 e applica il valore del guest, senza forzare Off globalmente. Il producer verifica l'adozione effettiva e include la proprietà nella cache di configurazione: Off→On→Off genera le rispettive CONFIGURE, mentre richieste identiche restano cached. Il controllo di drawable outstanding resta precedente alle mutazioni.

Verifiche offline: 11 controlli dell'helper C di configurazione di produzione con proprietà reali CAMetalLayer (nessuna window/drawable/command buffer), 6 del caller/cache guest e trasporto Mach reale, 2 ACK negativi per valore diverso o invalido. Riferimento: `Evidence/hosted-vsync-tests.json`. Le 26 verifiche stats e 20 completion/Mach più 2 negativi passano anche con il protocollo 4. Le suite non provano il guadagno FPS: Root deve ricompilare la coppia host/shim e confrontare la nuova sessione reale. La sessione già attiva, che mappa la precedente coppia v3, non viene modificata dai nuovi file sorgenti.

## Checkpoint candidato v4: nessun recupero dichiarato

Il confronto riproducibile `Scripts/analyze_native_benchmarks.py` lega gli hash
dei due `frames.csv` e `summary.json`: 37,7159729 FPS nativo e 34,2022514 hosted
v3, impostazioni grafiche JSON identiche, −9,31627% e +2,72301 ms medi del
motore. Sono esportazioni fornite dall’utente, con identità del run assegnata
dal chiamante; non misurano display pacing, latenza input o controllo termico.
Il [checkpoint separato](../Validation/ready-hosted-performance-checkpoint.json)
conserva gli hash e non riscrive quello storico v3.

Il campione reale pre-v4 Ready12886/guest12940 è intro/titolo. Medie CPU:
foreground eligibility 0,6701 ms per controllo; nextDrawable 0,3355 ms; present
API 0,5487 ms; service ACQUIRE 0,7589 / PRESENT 1,2078 / POLL 1,4269 ms;
attesa credito guest 14,4115 ms e import 0,3254 ms. Sono intervalli sovrapposti
e includono attesa/scheduling: non vanno sommati come costo GPU per frame.
La differenza guest VSync false/host true è reale nel campione, ma la sua quota
causale sulla regressione non è stata isolata.

La coppia v4 compilata include propagazione VSync booleana e ACK/cache,
foreground checks rimossi dalle operazioni render e mantenuti una volta per
POLL/input senza cache fra turni; FIFO input sensibile alla modalità e polling
a 8 ms. Passano eligibility11/input15/pointer14/shim11, stats26/completion20
più 2 negativi, VSync host11/guest6 più 2 ACK negativi e relocation14.
Ready14076 è stato avviato con profiling/host/HUD; CUA ha dato timeout senza
finestra e l’unlock è stato richiesto. **Nessun frame/rendering v4 o recupero
FPS/stutter è ancora verificato.** Il confronto reale a scena e impostazioni
uguali e la verifica input/pacing restano necessari.
