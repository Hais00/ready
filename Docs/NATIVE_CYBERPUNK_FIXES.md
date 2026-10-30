# Cyberpunk macOS: scroll, cursore, overlay e pipeline V6

> Aggiornamento verificato del 30 ottobre: il trasporto nativo remoto è ora il
> default delle sessioni same-window esplicitamente abilitate. Benchmark CLI con
> HUD e senza cattura schermo: 37,11 FPS contro 36,75–36,92 nativi con VSync;
> 37,52 contro 37,12 con VSync Off. Vedere [risultati e limiti correnti](HOSTED_PERFORMANCE_AUDIT.md).
> I vincoli di benchmark manuale e la pipeline surface nelle sezioni storiche
> seguenti descrivono le fasi precedenti e il fallback esplicito.


Aggiornamento del 29 ottobre 2026. Queste modifiche riguardano Cyberpunk nativo
macOS ospitato nella finestra di Ready. I benchmark reali sono riservati all'utente:
nessuna acquisizione dello schermo o misura FPS automatica viene usata per
certificare la parità col percorso nativo. Il riferimento riportato dall'utente è
circa 37 FPS nativi contro 34 con injection, con opzioni uguali e direct mode in
entrambi i casi. Non è il risultato misurato della nuova build.

## Costi del percorso grafico

Il precedente credito unico attendeva completamento GPU, PRESENT e relativo ACK
prima di consentire l'acquisizione successiva. V6 negozia e valida un massimo di
due frame: ogni slot possiede drawable, layer, frame ID, generazione e superficie
distinti. Un terzo frame applica backpressure. Il guest conserva i completamenti
GPU arrivati fuori ordine e presenta soltanto il primo frame eleggibile, senza
bloccare il callback GPU in attesa del precedente. Il credito torna dopo l'ACK
reale del relativo PRESENT, mai al solo arrivo di un fence.

La riconfigurazione di formato, dimensioni o VSync drena tutti i crediti sotto un
lock di acquisizione separato dai callback GPU. Il server rifiuta configurazioni
con slot occupati, identità/generazioni errate e presentazioni duplicate o fuori
ordine. Le importazioni IOSurface e la residency rimangono vive fino al fence
corretto. Non vengono aggiunti command buffer, code GPU, encoder o copie della
superficie sul lato host.

Metal 4 riusa evento e listener per ciascuna coda reale, con valori monotoni e un
insieme limitato di fence pendenti. La prova isolata mostra una riduzione del
costo CPU di preparazione del segnale; questo dato non misura FPS del gioco.
Restano importazione della texture, IPC e verifiche necessarie: due frame possono
migliorare la sovrapposizione del lavoro ma non equivalgono a overhead nullo o a
una garanzia di latenza inferiore.

Alla chiusura con frame ancora pendenti, i relativi slot e layer vengono ritirati
in un pool limitato fino all'uscita del produttore autenticato. Identità e nascita
del processo evitano di confondere un PID riutilizzato. Il Main thread non attende
l'uscita; un nuovo host è temporaneamente bloccato finché il pool precedente non
è ritirato. Il percorso normale a slot vuoti non crea watcher o timer aggiuntivi.
La profondità uno rimane selezionabile nelle fixture/developer launch del guest
con `READY_HOSTED_FRAMES_IN_FLIGHT=1`; l'ambiente riservato non viene accettato
indiscriminatamente attraverso il launcher.

## Manutenzione del launcher durante il gioco

È stata corretta anche una regressione del precaricamento: una risposta pubblica
dei metadati poteva riavviare il lavoro sugli artwork dopo il rilascio del canvas.
Prima del lancio Ready sospende sincronizzazione pubblica/catalogo e warming,
cancella timer e richieste della libreria, e invalida il lavoro accodato di lettura
e decodifica. Risposte già attive possono aggiornare lo stato in RAM, senza
ripompaggio o riattivazione della cache. I byte già accettati completano soltanto
il salvataggio necessario alla durabilità; non viene avviata nuova decodifica.
Alla chiusura del gioco viene pubblicato lo stato più recente e la manutenzione
riprende. Autenticazione, heartbeat, attività Steam e download richiesti dall'utente
restano indipendenti e non vengono arrestati da questa pausa.

## Trackpad e cursore

Il protocollo conserva separatamente delta tradizionali, delta precisi, precisione,
inversione e fasi normali/momentum. La ricostruzione conserva anche i campi CGEvent
originali, inclusi i valori frazionari, oltre ai getter NSEvent. Il cambio di focus
o l'apertura dell'overlay interrompe il gesto e rilascia i controlli tenuti.

Dopo lo scroll il proprietario del puntatore riapplica in modo bilanciato la hide
che AppKit può alterare durante il gesto. Il percorso non accumula hide count e
non nasconde il cursore fuori dalla finestra eleggibile. Le fixture verificano
la logica e gli eventi ricostruiti; il gesto fisico a due dita in Cyberpunk deve
ancora essere confermato dall'utente.

## Overlay

Il percorso hosted escludeva la precedente libreria overlay guest: per questo
la sua scorciatoia non poteva comparire. L'overlay hosted ora è un pannello AppKit
sopra la stessa superficie Metal di Ready. `Ctrl + Maiusc + Spazio` apre/chiude
Riprendi/Esci; frecce, Invio, Esc, mouse e controller usano le stesse azioni.
L'apertura sospende input/puntatore del guest, la chiusura ripristina il responder
e riapplica le verifiche di eleggibilità. Pressioni/rilasci della scorciatoia sono
accoppiati, incluso un rilascio perso durante il cambio di app.

Da chiuso il pannello viene rimosso e rilasciato: nessuna UI della libreria,
lettura dello schermo, loop, timer o comando GPU viene aggiunto dall'overlay.
Da aperto il pannello richiede il normale compositing della UI; le prove di
prestazioni devono mantenerlo chiuso e controllare le condizioni scelte dall'utente.

## Verifica e limiti

Il [checkpoint pubblico](../Validation/native-cyberpunk-fixes-checkpoint.json)
riporta hash e risultati delle prove isolate: input/scroll, puntatore, overlay,
fullscreen, VSync, callback/ACK, due frame reali con Metal e ritiro delle risorse.
I readback di controllo appartengono soltanto alle app di prova possedute, non al
percorso di produzione o al benchmark commerciale.

La nuova build non viene dichiarata equivalente in FPS al client nativo sulla
base di tali prove. Conferma del trackpad, assenza del cursore macOS, apertura
reale dell'overlay e confronto direct-mode di Cyberpunk restano prove manuali
riservate all'utente. Il precedente audit e le esportazioni storiche restano in
[HOSTED_PERFORMANCE_AUDIT.md](HOSTED_PERFORMANCE_AUDIT.md).

## Follow-up del 30 ottobre: riscontro reale e seconda correzione dello scroll

L'utente ha segnalato un blocco della prima build V6 e scroll ancora assente;
ha poi precisato di aver chiuso lui il gioco bloccato. Non risulta un nuovo crash
report. I diagnostici mostrano un massimo di due slot e nessun rifiuto osservato
di identità/ordine/deadline; questo non identifica la causa del blocco. Il log del
gioco contiene errori ANECompiler di allocazione del file backing e il disco
interno aveva circa 287 MiB liberi. La causa non viene attribuita automaticamente
alla pipeline o ad App Nap.

L'audit statico della copia installata identifica un consumer `GameView.scrollWheel:`
che legge i delta precisi. Il primo responder può invece ereditare il metodo di
base senza consumare lo scroll: i test precedenti non rappresentavano quel caso.
Il nuovo routing sceglie il consumer effettivo sotto il puntatore/nei suoi antenati
e mantiene il target durante gesto e momentum; non cambia il responder tastiera.

Sono stati spostati su Dati APFS soltanto artefatti e archivi verificati, mantenendo
alias e manifest prima/dopo; gli strumenti estratti, i runtime attivi, i prefix,
i salvataggi e il gioco restano intatti. L'archivio SDK resta interno perché il
suo verificatore rifiuta i symlink. Lo spazio interno recuperato è una mitigazione,
non la prova di risoluzione del blocco.

La preferenza locale `readySessionScratchDirectory` seleziona uno scratch privato
per sessione su Dati. Il manager valida i percorsi tramite FD e imposta le variabili
native dopo le altre configurazioni. Su questo sistema le sole TMPDIR/TMP/TEMP
non modificano Foundation. Il guest usa quindi, soltanto con la chiave validata,
le API pubbliche NSTemporaryDirectory, NSFileManager.temporaryDirectory e
confstr(_CS_DARWIN_USER_TEMP_DIR) verso quello scratch. La prova benigna verifica
il risultato reale e la semantica dei buffer; HOME, cwd e impostazioni globali
non cambiano. Nessuna pulizia automatica o modifica di altri processi. Il servizio
ANE esterno potrebbe avere proprie regole: non è stato verificato dal gioco.

Un token di attività user-initiated, con idle sleep consentito, protegge il guest
windowless soltanto durante il focus autenticato dell'host; viene rilasciato su
perdita focus, chiusura o stop. È una misura difensiva contro il throttling, senza
LatencyCritical o impostazioni globali. Non prova che App Nap abbia causato il
blocco osservato. L'effetto finale e il gesto sul trackpad restano da confermare
manualmente in Cyberpunk, senza benchmark/acquisizioni eseguiti dall'agente.
