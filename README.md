# Movie Preflight

App Mac (Swift/SwiftUI, come Dolly) che controlla un film prima della proiezione: si trascina un mp4/mkv/avi (o più file, o una cartella) e restituisce dati tecnici e segnalazioni su immagine, audio e sottotitoli.

## Interfaccia
Una scheda per film. In alto la locandina e i dati (da Wikidata/Wikipedia, solo con il consenso) e **una frase chiara**: «Pronto per la sala» oppure «3 cose da sistemare», con un solo pulsante grande **«Sistema tutto»** (raggruppa le correzioni sicure, esclude le eliminazioni di tracce e le ricodifiche lunghe). Sotto, **righe compatte**: titolo breve, traccia, secondo in cui compare il problema e un pulsante con l'azione («Ripara gli accenti», «Togli la pubblicità», «Converti in Dolby»…). Cliccando la riga si apre la spiegazione con i secondi e il **fotogramma** del film in quel punto. Ogni azione mostra prima il riepilogo e chiede conferma. Due schede: **Riepilogo** (solo ciò che serve) e **Dettagli** (note, dati tecnici, rianalisi, copia/salvataggio del rapporto, «Correggi a mano…»). La barra laterale compare solo con più di un film.

## Indispensabile per la sala o miglioria?
Ogni segnalazione è classificata (`isEssential` in `swift/Model.swift`). Il verdetto «Pronto per la sala» dipende **solo dalle indispensabili**; le migliorie stanno in una sezione chiusa.
- **Indispensabile** (visibile o udibile dal pubblico, o rompe la riproduzione): tutti gli *errori* (crediti del torrent nell'immagine o nei sottotitoli, accenti rovinati, sottotitoli in un'altra lingua o vuoti, audio muto o assente, file troncato o illeggibile, nero iniziale di 60 s) e questi avvisi: sottotitoli attivi di default, lingua parlata diversa dall'etichetta, sottotitoli sfasati o che finiscono/iniziano fuori tempo, buchi nel video o nell'audio, audio e video non sincronizzati, errori di decodifica, schermo nero a metà film, HDR su proiettore SDR, Dolby Vision profilo 5, video interlacciato dichiarato, film più corto del previsto.
- **Miglioria facoltativa**: audio non Dolby, volume o picchi, musica sopra i dialoghi, lingue non indicate, predefiniti, nome del file e titolo nei metadati, risoluzione e bitrate bassi, interlacciamento solo rilevato, nero iniziale/finale lungo, fermi immagine, keyframe lontani, livelli di segnale, blocchettatura e sfocatura, note.

## Dati del film online (opzionale)
Titolo e anno si ricavano dal nome del file («Titolo (Anno - Regista).mkv» o «Titolo.Anno.1080p…»); con il consenso, l'app interroga **Wikidata** (CC0) e **Wikipedia** (testi CC BY-SA; le locandine sono mostrate solo nell'app, non redistribuite) inviando solo titolo e anno: ne ricava regia, durata attesa, lingua originale, locandina e descrizione. Usi: confronto della durata (film tagliato o incompleto), avviso se manca l'audio in lingua originale, nome del file secondo la convenzione «Titolo (Anno - Regista)» con correzione «Rinomina il file». Da riga di comando: `--online` e `--meta FILE`.

## Cosa controlla
- **Contenitore**: estensione/contenuto, durata, titolo nei metadati con pubblicità, capitoli, file troncato.
- **Video**: risoluzione, bitrate per pixel, frame rate (variabile/insolito), interlacciamento (dichiarato e rilevato), HDR, colore non dichiarato, bande nere incorporate, neri iniziali/finali/centrali, fermi immagine, errori di decodifica, buchi nel flusso, keyframe.
- **Immagine**: OCR (Vision) sui primi 45 s e sugli ultimi 150 s per trovare scritte/crediti del torrent.
- **Audio** (per le prime 3 tracce; nei 5.1 anche **dialoghi contro musica**: confronto tra il canale centrale e il fronte sinistro/destro nei momenti con parlato): volume integrato, LRA, picchi, salti bruschi di volume, parti sommesse/forti rispetto al livello tipico, silenzi, buchi nei pacchetti, sincronia audio/video, lingua mancante, predefinite ambigue.
- **Sottotitoli**: **caratteri rovinati** (doppia codifica UTF-8→Windows-1252: «SÃ¬» invece di «Sì»; rilevazione che distingue «Ã» da «ã» portoghese) con riparazione, lingua reale delle battute contro quella dichiarata (NaturalLanguage), crediti/pubblicità, battute sovrapposte o troppo veloci, caratteri rovinati, durata rispetto al film, predefiniti/forzati incoerenti, formato a immagine.

## Strumenti open source inclusi
Tutto dentro l'app, senza Homebrew (vedi `THIRD_PARTY_NOTICES.md` e `LICENSE`, GPL-3.0):
- **ffmpeg/ffprobe 9.0.2** compilato da `tools/build_ffmpeg.sh` con x264, x265, dav1d, SVT-AV1, **libvmaf** e **zimg** (filtro `zscale`: conversione HDR→SDR);
- **MediaInfo**: dettagli di codifica, profili Dolby Vision/HDR10+, nome commerciale dell'audio, sigla del gruppo di rilascio nel titolo;
- **whisper.cpp** (modello «base» da 148 MB, scaricato solo dopo il consenso dell'utente da File → Controlli sul parlato…): lingua realmente parlata di ogni traccia e sincronia dei sottotitoli. Tempi fini = zone di parlato di whisper ∩ energia nella banda della voce; sfasamenti misurati con correlazione di Pearson su 3 tratti del film (spostamento fisso o deriva da frame rate diverso: 25↔23,976 ecc.).
`tools/bundle_tools.py` copia gli eseguibili e le librerie in `Contents/Resources` riscrivendo i percorsi: verificato eseguendoli in un sandbox che vieta la lettura di `/opt/homebrew`.

## Confronto prima e dopo
Dopo una correzione, «Confronta prima e dopo» (nel messaggio di esito o nel menu ⋯) mostra: l'esito dei due rapporti, i problemi **risolti**, **ancora presenti** e **nuovi**, le misure prima/dopo (volume, VMAF…) e i dati tecnici diversi; e poi un confronto da guardare e ascoltare: dal punto scelto (barra o «Punti dei problemi») due **fotogrammi affiancati**, il **testo dei sottotitoli** nello stesso istante e **20 secondi di audio** da ascoltare prima/dopo con commutazione A/B senza perdere la posizione.

**Confrontare due file qualsiasi** (per esempio un originale e una versione corretta fatta altrove): pulsante «Confronta due film» nella barra o File → Confronta due film… (⇧⌘C), scegli i due file (⌘-clic): l'app analizza quelli non ancora analizzati e apre lo stesso confronto. «Prima» è il file chiamato `.orig_backup`, altrimenti il più vecchio; «Inverti prima e dopo» scambia i ruoli.

## Correzioni
Dalle segnalazioni (pulsante «Correggi…») o dal pulsante in alto si apre una finestra che mostra tutto quello che verrà fatto, da confermare:
- traccia **audio predefinita**, **sottotitoli predefiniti** (o nessuno), **lingua** delle tracce senza etichetta;
- **togliere pubblicità e crediti** dai sottotitoli, **eliminare** tracce audio/sottotitoli;
- **cancellare la scritta** del torrent (es. «By Licdom») dall'immagine nei primi secondi: si ricodifica solo il tratto fino al primo fotogramma chiave dopo la scritta (il pezzo di immagine accanto la ricopre, con bordi sfumati; HDR10 e metadati conservati) e il resto del film è copiato senza perdite. Solo .mkv HEVC/H.264 a 8 o 10 bit; serve MKVToolNix. L'app non taglia mai parti del film;
- **alzare i dialoghi** (canale centrale +4 dB con limitatore) nei 5.1 dove la musica li copre;
- **riparare gli accenti rovinati** dei sottotitoli (ogni battuta riletta come Windows-1252 e rimessa in UTF-8; se restano oltre il 10% di battute rovinate l'operazione è annullata), **impostare o togliere l'etichetta «forzati»**, **rinominare il file**;
- **risincronizzare i sottotitoli** (spostamento fisso o allungamento per frame rate diverso), **correggere la lingua** di una traccia audio dopo il riconoscimento del parlato, **togliere il titolo** dal contenitore (sigle di gruppi di rilascio);
- **convertire HDR in SDR** (`zscale` + tone mapping Hable, solo se non è Dolby Vision profilo 5), con controllo di luminanza e tag BT.709;
- **convertire in Dolby Digital (AC-3)** le tracce che non sono Dolby (fino a 5.1; 640 kb/s per il 5.1, 384 per lo stereo), con controllo che il volume non cambi;
- **portare il volume a un livello standard** (-24 LUFS) con un **guadagno fisso**: sale o scende tutto insieme, la dinamica non cambia;
- **deinterlacciare l'immagine** (`bwdif`, ricodifica x264/x265 ad alta qualità nello stesso codec e profondità colore);
- (avanzata, sconsigliata) **compressione dinamica** `dynaudnorm`+`alimiter`: può abbassare la musica sotto il parlato e rialzarla dove c'è solo musica.

**Principio: meglio non toccare un file che peggiorarlo.** Solo strumenti standard del settore (ffmpeg: `bwdif`, `loudnorm`-style gain fisso, `alimiter`, `libvmaf`; mkvtoolnix) e ogni correzione di audio/immagine viene misurata prima e dopo; se non migliora, viene annullata e il file resta com'è:
- audio: nessuna distorsione (picco ≤ 0 dBFS), livello obiettivo raggiunto, nei 5.1 la «musica sopra i dialoghi» non deve aumentare di oltre 1,5 punti, la dinamica non deve crescere con la compressione;
- immagine: l'interlacciamento deve sparire e il **VMAF** (Netflix) su 3 tratti deve restare ≥ 93 (minimo ≥ 88) rispetto al deinterlacciato ideale.
Non inclusi: ingrandimento con IA (Real-ESRGAN è troppo lento per un film intero), separazione voce/musica con Demucs (PyTorch, centinaia di MB), OCR dei sottotitoli a immagine, encoder ufficiali Dolby/DTS (non esistono open source).

**L'originale non viene mai toccato.** Ogni correzione crea una copia accanto al film, chiamata «Titolo (corretto).ext» (o il nuovo nome, per la rinomina; mai sovrascrive file esistenti). Per le sole etichette in un mkv la copia è un **clone APFS** istantaneo (nessuno spazio in più finché non cambia) e `mkvpropedit` ci lavora dentro; per tutto il resto ffmpeg scrive un file temporaneo, l'app lo **verifica** (numero di tracce, durata, buchi nell'audio rispetto all'originale, qualità) e solo allora lo salva. Le correzioni successive aggiornano la stessa copia corretta; «Elimina la copia corretta» la manda nel Cestino e torna all'originale.

## Uso
    ./build.sh                       # dist/Movie Preflight.app (+ dist/moviepreflight per la riga di comando)
    dist/moviepreflight --analyze film.mkv # rapporto testuale
    python3 tests/test_moviepreflight.py   # 70 controlli su film sintetici con difetti noti

Gli strumenti vengono copiati dentro l'app da `tools/bundle_tools.py` (`BUNDLE_FFMPEG=0 ./build.sh` per saltare e usare quelli di /opt/homebrew/bin). Per distribuire l'app pubblicamente tieni conto della licenza di ffmpeg (la build di Homebrew include componenti GPL). Solo Apple Silicon (arm64), macOS 13+. Non modifica mai i file analizzati.

## Soglie
Tarate su 9 film reali della libreria "Opere Prime" (nessun falso positivo su OCR/pubblicità/interlacciamento). Le soglie di dinamica audio (LRA, salti, sommesso/forte) sono volutamente larghe: i film reali normali hanno LRA 18-23 LU. Per i 5.1, la misura «musica sopra i dialoghi» (secondi con parlato in cui il fronte supera il centro di oltre 6 LU) vale 0-10% nei film normali della libreria, 15% in Ex Machina e 26% in Flow (colonna sonora invadente): nota sopra il 12%, attenzione sopra il 20%.

## Icona
`icon/generate_icon.py` (generata con Codex a partire dall'icona di Dolly) disegna `icon/MoviePreflight-1024.png`; `icon/MoviePreflight.icns` si costruisce con `sips` + `iconutil` (vedi lo script di build).
