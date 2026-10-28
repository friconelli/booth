#!/usr/bin/env python3
"""Prova Booth su film sintetici con difetti noti: ogni controllo deve scattare quando deve e non quando non deve.
Uso: python3 tests/test_booth.py   (usa dist/booth; serve ffmpeg)"""
import os, re, subprocess, sys, tempfile, shutil
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); BIN = os.path.join(ROOT, "dist", "booth")
T = tempfile.mkdtemp(prefix="booth-test-"); ok = bad = 0
def ff(*a): subprocess.run(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", *a], check=True, stdin=subprocess.DEVNULL)
def check(c, msg):
    global ok, bad
    if c: ok += 1; print("  ok  ", msg)
    else: bad += 1; print("  FAIL", msg)
def analyze(f): return subprocess.run([BIN, "--analyze", f], capture_output=True, text=True).stdout
def srt(path, cues):
    def t(s): return f"{int(s//3600):02d}:{int(s%3600//60):02d}:{int(s%60):02d},{int(s%1*1000):03d}"
    open(path, "w").write("\n".join(f"{i+1}\n{t(s)} --> {t(s+2.5)}\n{x}\n" for i, (s, x) in enumerate(cues)))
D = 140
IT = ["Questa è una frase abbastanza lunga in italiano numero %d" % i for i in range(40)]
EN = ["This is a fairly long sentence written in English number %d" % i for i in range(40)]
def video(name, vf="", extra=(), aud=True, af="sine=f=300:d=%d" % D, subs=None, size="640x360", fps=25, meta=()):
    out = os.path.join(T, name); a = ["-f", "lavfi", "-i", f"testsrc2=s={size}:r={fps}:d={D}"]
    if aud: a += ["-f", "lavfi", "-i", af]
    si = 2 if aud else 1
    for s in (subs or []): a += ["-i", s[0]]
    a += ["-map", "0:v"] + (["-map", "1:a"] if aud else [])
    for i, s in enumerate(subs or []): a += ["-map", str(si + i), f"-metadata:s:s:{i}", f"language={s[1]}"] + ([f"-disposition:s:{i}", s[2]] if len(s) > 2 else [])
    if vf: a += ["-vf", vf]
    a += ["-c:v", "libx264", "-preset", "ultrafast", "-b:v", "1500k", "-pix_fmt", "yuv420p"] + (["-c:a", "aac", "-metadata:s:a:0", "language=ita"] if aud else []) + (["-c:s", "srt"] if subs else []) + list(extra)
    for m in meta: a += ["-metadata", m]
    ff(*a, out); return out
try:
    print("== film pulito"); 
    srt(os.path.join(T, "it.srt"), [(i * 3 + 1, x) for i, x in enumerate(IT)])
    f = video("pulito.mkv", subs=[(os.path.join(T, "it.srt"), "ita")], af="sine=f=300:d=%d,volume=0.2" % D); o = analyze(f)
    check("Nessun problema rilevato" in o or "[PROBLEMA]" not in o, "film pulito: nessun problema")
    check("Risoluzione: 640×360" in o and "Codec: H264" in o, "dati tecnici presenti")
    check("[ATTENZIONE] Sottotitoli" not in o and "[PROBLEMA] Sottotitoli" not in o, "film pulito: sottotitoli italiani non segnalati")

    print("== crediti nell'immagine")
    subprocess.run(["swiftc", "-o", os.path.join(T, "card"), os.path.join(ROOT, "tests", "card.swift")], check=True, capture_output=True)
    subprocess.run([os.path.join(T, "card"), os.path.join(T, "card.png"), "www.YTS.mx"], check=True)
    out = os.path.join(T, "ad.mkv")
    ff("-f", "lavfi", "-i", f"testsrc2=s=640x360:r=25:d={D}", "-i", os.path.join(T, "card.png"), "-f", "lavfi", "-i", "sine=f=300:d=%d" % D, "-filter_complex", "[1]scale=640:360[c];[0][c]overlay=enable='between(t,2,7)'[v]", "-map", "[v]", "-map", "2:a", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", out)
    o = analyze(out); check("[PROBLEMA] Video: Scritta pubblicitaria" in o and "yts" in o.lower(), "scritta www.YTS.mx nei primi secondi rilevata dall'OCR")
    import hashlib; h_ad = hashlib.sha256(open(out, "rb").read()).hexdigest(); d_ad = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out], capture_output=True, text=True).stdout)
    r_ad = subprocess.run([BIN, "--fix", out, "--erase-text"], capture_output=True, text=True); cc = out.replace(".mkv", " (corretto).mkv")
    check(r_ad.returncode == 0 and os.path.exists(cc) and hashlib.sha256(open(out, "rb").read()).hexdigest() == h_ad, "scritta cancellata: nasce «… (corretto)» e l'originale è identico byte per byte")
    d_cc = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", cc], capture_output=True, text=True).stdout) if os.path.exists(cc) else 0
    check(abs(d_cc - d_ad) < 1 and "Scritta pubblicitaria" not in analyze(cc), f"scritta sparita dall'immagine e film non accorciato ({d_cc:.1f} s su {d_ad:.1f})")

    print("== sottotitoli")
    cues = [(i * 3 + 1, x) for i, x in enumerate(IT[:25])] + [(i * 3 + 80, x) for i, x in enumerate(EN[:12])] + [(5, "Subtitles by www.opensubtitles.org")]
    srt(os.path.join(T, "mix.srt"), sorted(cues)); srt(os.path.join(T, "en.srt"), [(i * 3 + 1, x) for i, x in enumerate(EN)])
    o = analyze(video("sub.mkv", subs=[(os.path.join(T, "mix.srt"), "ita", "default")]))
    check("Crediti o pubblicità nei sottotitoli" in o, "pubblicità nei sottotitoli")
    check("Parte dei sottotitoli non è in italiano" in o, "battute in inglese in una traccia dichiarata italiana")
    check("Sottotitoli attivi di default" in o, "sottotitoli predefiniti segnalati")
    o = analyze(video("sub2.mkv", subs=[(os.path.join(T, "en.srt"), "ita")])); check("Lingua dei sottotitoli diversa da quella dichiarata" in o, "traccia inglese etichettata italiano")
    o = analyze(video("sub3.mkv", subs=[(os.path.join(T, "it.srt"), "und")])); check("Lingua non indicata — sottotitoli 1" in o, "sottotitoli senza lingua")

    print("== audio")
    af = "sine=f=300:d=%d,volume='if(between(t,60,90),1,0.02)':eval=frame" % D
    o = analyze(video("loud.mkv", af=af)); check("salti bruschi di volume" in o or "più forti del parlato" in o or "Dinamica molto ampia" in o, "musica forte dopo parlato sommesso")
    o = analyze(video("silent.mkv", af="anullsrc=r=48000:d=%d" % D)); check("Audio quasi muto" in o, "traccia muta")
    o = analyze(video("noaudio.mkv", aud=False)); check("Nessuna traccia audio" in o, "niente audio")
    o = analyze(video("clip.mkv", af="sine=f=300:d=%d,volume=40,alimiter=limit=1:level=0" % D)); check("Picchi a 0 dB" in o or "Audio molto alto" in o, "audio saturo")

    print("== video e file")
    o = analyze(video("low.mkv", size="320x180")); check("Risoluzione bassa" in o, "risoluzione bassa")
    o = analyze(video("hdr.mkv", extra=["-x264-params", "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"])); check("HDR (PQ)" in o, "HDR segnalato")
    o = analyze(video("lbx.mkv", vf="crop=640:272,pad=640:360:0:44")); check("Bande nere incorporate" in o, "bande nere incorporate")
    o = analyze(video("title.mkv", meta=["title=www.torrent-site.com - Film"])); check("titolo nei metadati contiene pubblicità" in o, "titolo con pubblicità")
    o = analyze(video("blk.mkv", vf="fade=in:st=0:d=0.1,drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill:enable='between(t,0,15)'")); check("Nero iniziale lungo" in o, "nero iniziale")
    o = analyze(video("il.mkv", vf="interlace=scan=tff", extra=["-flags", "+ilme+ildct"])); check("interlacciat" in o.lower(), "video interlacciato")
    avi = os.path.join(T, "film.avi"); ff("-f", "lavfi", "-i", f"testsrc2=s=640x360:r=25:d={D}", "-f", "lavfi", "-i", "sine=d=%d" % D, "-c:v", "mpeg4", "-c:a", "mp3", avi)
    o = analyze(avi); check("Codec: MPEG4" in o and "Contenitore: AVI" in o, "file avi analizzato")
    full = video("trunc_src.mkv"); tr = os.path.join(T, "trunc.mkv"); data = open(full, "rb").read(); open(tr, "wb").write(data[: len(data) // 2])
    o = analyze(tr); check("[PROBLEMA]" in o or "troncato" in o or "non leggibile" in o or "prima del previsto" in o, "file troncato")
    open(os.path.join(T, "junk.mkv"), "w").write("non è un video"); o = analyze(os.path.join(T, "junk.mkv")); check("File non leggibile" in o, "file non video")
    print("== correzioni")
    def fix(f, *a): r = subprocess.run([BIN, "--fix", f, "--replace", *a], capture_output=True, text=True); return r.returncode, r.stdout   # modifica il file indicato (per le prove sul comportamento)
    def fixcopy(f, *a): r = subprocess.run([BIN, "--fix", f, *a], capture_output=True, text=True); return r.returncode, r.stdout          # comportamento normale: crea «… (corretto)»
    import hashlib
    def sha(f): return hashlib.sha256(open(f, "rb").read()).hexdigest()
    def probe(f):
        import json; return json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", f], capture_output=True, text=True).stdout)
    def tracks(f, t): return [s for s in probe(f)["streams"] if s["codec_type"] == t]
    adsrt = os.path.join(T, "ads.srt"); srt(adsrt, [(1, "Subtitles by www.opensubtitles.org")] + [(i * 3 + 10, x) for i, x in enumerate(IT[:20])])
    def two(name):
        out = os.path.join(T, name)
        ff("-f", "lavfi", "-i", f"testsrc2=s=640x360:r=25:d={D}", "-f", "lavfi", "-i", "sine=f=300:d=%d" % D, "-f", "lavfi", "-i", "sine=f=500:d=%d" % D, "-i", adsrt, "-i", os.path.join(T, "en.srt"),
           "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3", "-map", "4", "-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-c:a", "aac", "-c:s", "srt",
           "-metadata:s:a:0", "language=ita", "-metadata:s:a:1", "language=eng", "-metadata:s:s:0", "language=ita", "-metadata:s:s:1", "language=eng", "-disposition:a:0", "default", "-disposition:s:0", "default", out)
        return out
    f = two("fix1.mkv"); before = os.path.getsize(f)
    rc, o = fix(f, "--audio-default", "1", "--sub-default", "none", "--lang", "s1=fra")
    a, ss = tracks(f, "audio"), tracks(f, "subtitle")
    check(rc == 0 and a[1]["disposition"]["default"] == 1 and a[0]["disposition"]["default"] == 0, "audio predefinito cambiato (etichette sul posto)")
    check(all(x["disposition"]["default"] == 0 for x in ss) and ss[1]["tags"]["language"] == "fre", "nessun sottotitolo predefinito e lingua impostata")
    check(not os.path.exists(f.replace(".mkv", ".orig_backup.mkv")), "solo etichette: nessuna copia di backup")
    f = two("fix2.mkv"); full = float(probe(f)["format"]["duration"]); orig2 = f; h2 = sha(orig2)
    rc, o = fixcopy(f, "--clean-sub", "0", "--normalize", "0")
    f = orig2.replace(".mkv", " (corretto).mkv"); np = probe(f) if os.path.exists(f) else {"format": {"duration": "0"}}
    check(rc == 0 and os.path.exists(f) and sha(orig2) == h2, "correzione di contenuto: nasce «… (corretto)» e l'originale è identico byte per byte")
    check(abs(float(np["format"]["duration"]) - full) < 1, f"il film non viene accorciato (durata {float(np['format']['duration']):.0f} s su {full:.0f})")
    check([x["codec_name"] for x in tracks(f, "audio")][0] == "ac3" and tracks(f, "audio")[1]["codec_name"] == "aac", "solo la traccia scelta è ricodificata")
    cues = subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-map", "0:s:0", "-f", "srt", "-"], capture_output=True, text=True).stdout
    check("opensubtitles" not in cues and "Questa è una frase" in cues, "pubblicità tolta dai sottotitoli, il resto resta")
    check("prima:" in o and "dopo:" in o, "misura prima/dopo del volume riportata")
    check(float(probe(orig2)["format"]["duration"]) > full - 1 and len(tracks(orig2, "subtitle")) == 2, "l'originale ha ancora durata, tracce e sottotitoli di prima")
    f = two("fix3.mkv"); rc, o = fix(f, "--drop-sub", "1", "--drop-audio", "1")
    check(rc == 0 and len(tracks(f, "audio")) == 1 and len(tracks(f, "subtitle")) == 1, "tracce eliminate")
    f = two("fix4.mkv"); rc, o = fix(f, "--drop-audio", "0", "--drop-audio", "1"); check(rc != 0 and len(tracks(f, "audio")) == 2, "non si eliminano tutte le tracce audio")
    rc, o = fix(f, "--audio-default", "5"); check(rc != 0, "traccia predefinita inesistente rifiutata")
    print("== l'originale non si tocca mai")
    o1 = two("intatto.mkv"); h1 = sha(o1); rc, o = fixcopy(o1, "--audio-default", "1", "--lang", "s1=fra", "--forced", "0:1"); c1 = o1.replace(".mkv", " (corretto).mkv")
    check(rc == 0 and os.path.exists(c1) and sha(o1) == h1, "solo etichette: copia «(corretto)» creata, originale identico byte per byte")
    check(tracks(c1, "audio")[1]["disposition"]["default"] == 1 and tracks(o1, "audio")[0]["disposition"]["default"] == 1 and tracks(o1, "audio")[1]["disposition"]["default"] == 0, "le etichette cambiano solo nella copia")
    rc, o = fixcopy(o1, "--clear-title"); c2 = o1.replace(".mkv", " (corretto) 2.mkv")
    check(rc == 0 and os.path.exists(c2) and os.path.exists(c1), "una seconda correzione non sovrascrive la prima copia")
    o3 = two("nome.mkv"); h3 = sha(o3); rc, o = fixcopy(o3, "--rename", "Nome Nuovo (2001 - Regista)")
    check(rc == 0 and os.path.exists(os.path.join(T, "Nome Nuovo (2001 - Regista).mkv")) and os.path.exists(o3) and sha(o3) == h3, "la rinomina crea una copia con il nuovo nome: l'originale resta com'è")
    print("== titolo, HDR→SDR, qualità")
    tt = video("titolo.mkv", meta=["title=Film Bello [HD4ME]"]); o = analyze(tt)
    check("sigla di un gruppo di rilascio" in o, "sigla del gruppo di rilascio nel titolo rilevata")
    rc, o2 = fix(tt, "--clear-title"); o = analyze(tt); check(rc == 0 and "gruppo di rilascio" not in o and "Titolo nei metadati" not in o, "titolo tolto dal contenitore")
    check("Livelli fuori standard" in o and "Blocchettatura" in o, "controlli di segnale e qualità eseguiti")
    hd = video("hdr_tm.mkv", extra=["-x264-params", "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"])
    hdc = hd.replace(".mkv", " (corretto).mkv"); rc, o = fixcopy(hd, "--tonemap"); v = tracks(hdc, "video")[0] if rc == 0 else {}
    check(rc == 0 and v.get("color_transfer") == "bt709" and "luminanza media" in o and tracks(hd, "video")[0].get("color_transfer") == "smpte2084", f"HDR convertito in SDR con controllo della luminanza ({v.get('color_transfer')})")
    rc, o = fix(os.path.join(T, "pulito.mkv"), "--tonemap"); check(rc != 0 and "non è HDR" in o, "conversione HDR rifiutata su un video SDR")
    print("== accenti rovinati, forzati, rinomina, dati del film")
    clean = ["Sì, è così, perché la città è già qui e non c'è più tempo, %d" % i for i in range(25)]
    moj = os.path.join(T, "moj.srt"); srt(moj, [(i * 3 + 1, t.encode("utf-8").decode("cp1252")) for i, t in enumerate(clean)])
    mf = video("moj.mkv", subs=[(moj, "ita")]); o = analyze(mf)
    check("Caratteri rovinati" in o and "Si ripara senza toccare le battute" in o, "accenti rovinati (doppia codifica) rilevati")
    rc, o2 = fix(mf, "--repair-sub", "0"); txt = subprocess.run(["ffmpeg", "-v", "error", "-i", mf, "-map", "0:s:0", "-f", "srt", "-"], capture_output=True, text=True).stdout
    check(rc == 0 and "Sì, è così, perché la città è già qui e non c'è più tempo, 7" in txt and "Ã" not in txt and "Caratteri rovinati" not in analyze(mf), "accenti riparati, il resto delle battute invariato")
    pt = os.path.join(T, "pt.srt"); srt(pt, [(i * 3 + 1, "Não é São Paulo, eles já estão aqui e não sei porquê, %d" % i) for i in range(25)])
    check("Caratteri rovinati" not in analyze(video("pt.mkv", subs=[(pt, "por")])), "sottotitoli portoghesi (ã, ç) non segnalati per errore")
    ff_ = video("forz.mkv", subs=[(os.path.join(T, "it.srt"), "ita")]); rc, o2 = fix(ff_, "--forced", "0:1")
    check(rc == 0 and tracks(ff_, "subtitle")[0]["disposition"]["forced"] == 1, "etichetta «forzati» impostata")
    rn = video("da_rinominare.mkv"); rc, o2 = fix(rn, "--rename", "Nuovo Nome (2000 - Tizio Caio)")
    check(rc == 0 and os.path.exists(os.path.join(T, "Nuovo Nome (2000 - Tizio Caio).mkv")) and not os.path.exists(rn), "file rinominato")
    rc, o2 = fix(os.path.join(T, "Nuovo Nome (2000 - Tizio Caio).mkv"), "--rename", "rinominato due"); check(rc == 0, "rinomina senza altre modifiche"); rc, o2 = fix(os.path.join(T, "rinominato due.mkv"), "--rename", "pulito"); check(rc != 0 and "già" in o2, "la rinomina non sovrascrive un file esistente")
    open(os.path.join(T, "Piccoli omicidi tra amici (1994 - Danny Boyle).mkv"), "w").write("x")
    r = subprocess.run([BIN, "--meta", os.path.join(T, "Piccoli omicidi tra amici (1994 - Danny Boyle).mkv")], capture_output=True, text=True).stdout
    check("titolo «Piccoli omicidi tra amici» anno 1994 regista Danny Boyle" in r, "titolo, anno e regista ricavati dal nome del file")
    if "trovato" in r or "non trovato" in r: check("Q506032" in r and "89 min" in r or "non trovato" in r and "Q506032" not in r, "dati del film da Wikidata (se la rete è raggiungibile)")
    print("== Dolby")
    ac = video("aac.mkv", af="sine=f=300:d=%d,volume=0.2" % D); o = analyze(ac)
    check("Audio non Dolby (AAC)" in o and "Dolby: no (AAC)" in o, "traccia AAC segnalata come non Dolby")
    rc, o = fix(ac, "--dolby", "0"); m = re.search(r"prima:\s+(-?[\d.]+) LUFS.*\n.*dopo:\s+(-?[\d.]+) LUFS", o)
    check(rc == 0 and tracks(ac, "audio")[0]["codec_name"] == "ac3" and m is not None and abs(float(m.group(1)) - float(m.group(2))) < 1.0, f"conversione in AC-3 senza cambiare il volume ({m.group(1) if m else '?'} → {m.group(2) if m else '?'} LUFS)")
    o = analyze(ac); check("non Dolby" not in o and "Dolby: sì — Dolby Digital (AC-3)" in o, "dopo la conversione la traccia risulta Dolby")
    print("== parlato (whisper)")
    if shutil.which("say") and os.path.exists(os.path.expanduser("~/Library/Application Support/Booth/models/ggml-base.bin")):
        N = 100   # 100 frasi sintetiche con tempi noti
        sentsIT = ["Buongiorno a tutti, oggi parleremo di una storia molto importante.", "Non ho mai visto una cosa del genere in tutta la mia vita.", "Vieni qui subito, abbiamo moltissime cose da fare prima di sera.",
                   "La macchina è partita ieri mattina e non è ancora tornata a casa.", "Dimmi la verità, perché non mi hai chiamato quando sei arrivato?", "Il tempo è cambiato molto negli ultimi anni, e non solo qui da noi."]
        sentsEN = ["Good morning everyone, today we are going to talk about a very important story.", "I have never seen anything like this in my whole life.", "Come here right now, we have so many things to do before tonight.",
                   "The car left yesterday morning and it still has not come back home.", "Tell me the truth, why did you not call me when you arrived?", "The weather has changed a lot in recent years, and not only around here."]
        slots = [6.2 + ((i * 7919) % 13) * 0.35 for i in range(N)]   # tempi irregolari come nel parlato vero (un ritmo fisso renderebbe ambiguo lo spostamento)
        starts = [sum(slots[:i]) for i in range(N)]
        def say(voice, out, text):   # «say» a volte si pianta per ore: tempo massimo e un nuovo tentativo
            for _ in range(3):
                try: subprocess.run(["say", "-v", voice, "-o", out, text], check=True, timeout=60); return
                except subprocess.TimeoutExpired: pass
            raise RuntimeError("say non risponde")
        def speech(voice, sents, name):
            durs = []
            for i, t in enumerate(sents):
                a = os.path.join(T, f"{name}{i}.aiff"); say(voice, a, t)
                durs.append(float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", a], capture_output=True, text=True).stdout))
            lst = os.path.join(T, name + ".txt"); open(lst, "w").write("")
            parts = []
            for i in range(N):
                w = os.path.join(T, f"{name}_s{i}.wav"); ff("-i", os.path.join(T, f"{name}{i % len(sents)}.aiff"), "-ar", "16000", "-ac", "1", "-af", f"apad=whole_dur={slots[i]:.3f}", "-t", f"{slots[i]:.3f}", w); parts.append(w)
            open(lst, "w").write("".join(f"file '{w}'\n" for w in parts))
            out = os.path.join(T, name + "_all.wav"); ff("-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", out); return out, durs
        def film(name, wav, cues, lang_tag):
            sub = os.path.join(T, name + ".srt"); open(sub, "w").write("\n".join(f"{i+1}\n{fmt(a)} --> {fmt(b)}\nFrase {i}\n" for i, (a, b) in enumerate(cues)))
            out = os.path.join(T, name + ".mkv")
            ff("-f", "lavfi", "-t", f"{sum(slots):.1f}", "-i", "testsrc2=s=320x180:r=10", "-i", wav, "-i", sub, "-map", "0:v", "-map", "1:a", "-map", "2", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-c:s", "srt",
               "-metadata:s:a:0", f"language={lang_tag}", "-metadata:s:s:0", "language=ita", out); return out
        def fmt(x): ms = int(round(x * 1000)); return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"
        wavIT, dIT = speech("Alice", sentsIT, "it"); wavEN, dEN = speech("Albert", sentsEN, "en")
        cues = [(starts[i] + 0.3, starts[i] + 0.3 + dIT[i % len(dIT)]) for i in range(N)]
        f1 = film("sync_ok", wavIT, cues, "ita"); o = analyze(f1)
        check("Lingua parlata (rilevata): italiano" in o and "non corrisponde" not in o, "lingua parlata riconosciuta (italiano) senza falsi allarmi")
        check("sfasati" not in o and "si sfasano" not in o, "sottotitoli sincronizzati: nessun allarme")
        f2 = film("sync_shift", wavIT, [(a + 6.0, b + 6.0) for a, b in cues], "ita"); o = analyze(f2)
        check("Sottotitoli sfasati di" in o, "sottotitoli in ritardo di 6 s rilevati")
        rc, o2 = fix(f2, "--sync-sub", "0:1:-6.0"); o3 = analyze(f2)
        check(rc == 0 and "risincronizzati" in o2 and "sfasati" not in o3, "sottotitoli risincronizzati con la correzione")
        f3 = film("lang_wrong", wavEN, [(a, b) for a, b in cues], "ita"); o = analyze(f3)
        check("La lingua parlata non corrisponde all'etichetta" in o and "inglese" in o, "audio inglese etichettato italiano rilevato")
        rc, o2 = fix(f3, "--lang", "a0=eng"); check(rc == 0 and tracks(f3, "audio")[0]["tags"]["language"] == "eng", "etichetta di lingua corretta")
    else: print("  (saltato: serve `say` e il modello vocale)")
    hot = video("picchi.mkv", af="sine=f=300:d=%d,volume=6,alimiter=limit=1:level=0" % D); rc, o = fix(hot, "--dolby", "0")
    check(rc == 0 and tracks(hot, "audio")[0]["codec_name"] == "ac3", "conversione Dolby accettata anche se l'originale ha già picchi a 0 dB (conta il peggioramento, non il valore assoluto)")
    print("== deinterlacciamento")
    il = os.path.join(T, "interl.mkv")
    ff("-f", "lavfi", "-i", "mandelbrot=s=640x360:r=25", "-f", "lavfi", "-i", "sine=d=200", "-t", "200", "-map", "0:v", "-map", "1:a", "-vf", "interlace=scan=tff", "-c:v", "libx264", "-preset", "ultrafast", "-flags", "+ilme+ildct", "-b:v", "6M", "-c:a", "aac", il)
    ilc = il.replace(".mkv", " (corretto).mkv"); hil = sha(il); rc, o = fixcopy(il, "--deinterlace")
    check(rc == 0 and "VMAF" in o and os.path.exists(ilc) and sha(il) == hil, "deinterlacciamento riuscito con controllo VMAF, originale intatto")
    check(rc == 0 and tracks(ilc, "video")[0]["codec_name"] == "h264" and tracks(ilc, "audio")[0]["codec_name"] == "aac", "audio copiato, video ricodificato nello stesso codec")
    print("== dialoghi 5.1")
    f51 = os.path.join(T, "surround.mkv")
    ff("-f", "lavfi", "-i", f"testsrc2=s=640x360:r=25:d={D}", "-f", "lavfi", "-i", f"sine=f=300:d={D}", "-filter_complex", "[1]pan=5.1|FL=2.0*c0|FR=2.0*c0|FC=0.8*c0|LFE=0*c0|BL=0*c0|BR=0*c0[a]",
       "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "ac3", "-metadata:s:a:0", "language=ita", f51)   # fronte più forte del centro di ~8 dB (niente join: ffmpeg a volte si blocca)
    o = analyze(f51); check("Musica ed effetti coprono i dialoghi" in o, "musica sopra i dialoghi in un 5.1 rilevata")
    rc, o = fix(f51, "--boost-center", "0"); import re
    m = re.search(r"prima: (\d+)% .* dopo: (\d+)%", o)
    check(rc == 0 and m is not None and int(m.group(1)) > 80 and int(m.group(2)) < int(m.group(1)) - 50, f"canale centrale alzato: musica sopra i dialoghi {m.group(1) if m else '?'}% → {m.group(2) if m else '?'}%")
    rc, o = fix(os.path.join(T, "pulito.mkv"), "--boost-center", "0"); check(rc != 0, "alzare il centro su una traccia non 5.1 è rifiutato")
    print("== controllo di non-peggioramento")
    fb = os.path.join(T, "surround_ok.mkv")   # centro e fronte vicini (~4 dB): abbassare il centro lo farebbe coprire dalla musica
    ff("-f", "lavfi", "-i", f"testsrc2=s=640x360:r=25:d={D}", "-f", "lavfi", "-i", f"sine=f=300:d={D}", "-filter_complex", "[1]pan=5.1|FL=2.0*c0|FR=2.0*c0|FC=1.3*c0|LFE=0*c0|BL=0*c0|BR=0*c0[a]",
       "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "ac3", fb)
    before_size = os.path.getsize(fb); rc, o = fixcopy(fb, "--boost-center", "0", "--boost-db", "-6")
    check(rc != 0 and "annullata" in o and os.path.getsize(fb) == before_size and not os.path.exists(fb.replace(".mkv", " (corretto).mkv")), "correzione che peggiora i dialoghi: annullata, file intatto, nessuna copia creata")
    pl = os.path.join(T, "pulito.mkv"); rc, o = fix(pl, "--level", "0"); m = re.search(r"dopo:\s+(-?[\d.]+) LUFS", o)
    check(rc == 0 and m is not None and abs(float(m.group(1)) + 24) < 2.5 and "guadagno fisso" in o, f"volume portato a -24 LUFS con guadagno fisso ({m.group(1) if m else '?'} LUFS)")
    print("== quale copia è meglio")
    def better(a, b): return subprocess.run([BIN, "--better", a, b], capture_output=True, text=True).stdout
    hd_en, sd_it, sd_it2, hd_it = (os.path.join(T, n) for n in ("hd_en.mkv", "sd_it.mkv", "sd_it2.mkv", "hd_it.mkv"))
    ff("-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=24000/1001:d=40", "-f", "lavfi", "-i", "sine=f=440:d=40", "-c:v", "libx264", "-b:v", "6M", "-c:a", "aac", "-ac", "2", "-metadata:s:a:0", "language=eng", hd_en)
    ff("-f", "lavfi", "-i", "testsrc2=s=720x400:r=25:d=38.4", "-f", "lavfi", "-i", "sine=f=440:d=38.4", "-c:v", "libx264", "-b:v", "1M", "-c:a", "ac3", "-ac", "6", "-metadata:s:a:0", "language=ita", sd_it)
    ff("-f", "lavfi", "-i", "testsrc2=s=720x400:r=25:d=38.4", "-f", "lavfi", "-i", "sine=f=440:d=38.4", "-c:v", "libx264", "-b:v", "1M", "-c:a", "aac", "-ac", "2", "-metadata:s:a:0", "language=ita", sd_it2)
    ff("-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=24000/1001:d=40", "-f", "lavfi", "-i", "sine=f=440:d=40", "-c:v", "libx264", "-b:v", "6M", "-c:a", "ac3", "-ac", "6", "-metadata:s:a:0", "language=ita", hd_it)
    o1, o2 = better(hd_en, sd_it), better(sd_it, hd_en)
    check(o1.startswith("MEGLIO: B") and o2.startswith("MEGLIO: A") and "audio italiano" in o1 and "CONVIENE UNIRLE" in o1, "audio italiano batte l'immagine migliore, in qualunque ordine, e propone di unirle")
    o = better(sd_it2, hd_it); check(o.startswith("MEGLIO: B") and "1920×1080" in o and "5.1" in o and "CONVIENE" not in o and "minuti" not in o, "stessa lingua: vince l'immagine e l'audio 5.1, durata PAL non scambiata per scene mancanti")
    check(better(hd_it, hd_it).startswith("PARI"), "due copie uguali: pari")
    print("== unione di due copie")
    DM = 400
    def gate(seed, rate=7, dens=0.35): return f"volume='if(lt(abs(mod(sin(floor(t*{rate})*{seed})*43758.5453,1)),{dens}),1,0.03)':eval=frame"
    ME = f"anoisesrc=d={DM}:c=pink:a=0.5:r=48000,{gate(12.9898)}"           # musica ed effetti: uguali nelle due copie
    IT = f"sine=f=450:d={DM}:r=48000,{gate(78.233, 5)}"                      # «dialoghi» italiani
    EN = f"sine=f=620:d={DM}:r=48000,{gate(39.425, 5)}"                      # «dialoghi» inglesi
    def mix(dlg, post=""): return f"{ME}[m];{dlg}[d];[m][d]amix=inputs=2:normalize=0,aformat=channel_layouts=stereo{post}"
    def film(name, size, fps, audio_graph, lang, dur):
        out = os.path.join(T, name)
        ff("-f", "lavfi", "-i", f"testsrc2=s={size}:r={fps}:d={dur}", "-filter_complex", audio_graph + "[a]", "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "800k" if size == "640x360" else "3000k",
           "-c:a", "aac", "-b:a", "192k", "-metadata:s:a:0", f"language={lang}", "-shortest", out); return out
    truth = os.path.join(T, "verita_it.mka"); ff("-filter_complex", mix(IT) + "[a]", "-map", "[a]", "-c:a", "pcm_s16le", truth)   # l'audio italiano giusto sul tempo della copia buona
    best = film("buona.mkv", "1280x720", "24000/1001", mix(EN), "eng", DM)
    pal = film("pal.mkv", "640x360", 25, mix(IT, ",adelay=2300:all=1,asetrate=50050,aresample=48000"), "ita", round((DM + 2.3) * 23.976 / 25, 2))   # 2,3 s in più in testa, accelerata a 25 fps
    def merge(*a):
        try: r = subprocess.run([BIN, "--merge", *a], capture_output=True, text=True, timeout=600); return r.returncode, r.stdout
        except subprocess.TimeoutExpired: return -9, "BLOCCATO"
    def sync(f, t): o = subprocess.run([BIN, "--sync-point", truth, "0", f, "0", str(t)], capture_output=True, text=True).stdout; m = re.search(r"a salti: d=([-+\d.]+)", o); return float(m.group(1)) if m else 99
    rc, o = merge(pal, best, "--align-only"); m = re.search(r"ALLINEATO: k=([\d.]+) d=([-+\d.]+)", o)
    check(rc == 0 and "B [immagine]" in o and "audio: Aa0" in o, "proposta: immagine dalla copia migliore (720p), audio italiano dall'altra")
    check(m is not None and abs(float(m.group(1)) - 23.976 / 25) < 1e-4 and abs(float(m.group(2)) - 2.3) < 0.03, f"velocità 25 → 23,976 e scarto di 2,3 s trovati (k={m.group(1) if m else '?'}, d={m.group(2) if m else '?'})")
    hp, hb = sha(pal), sha(best); rc, o = merge(pal, best); out = os.path.join(T, "buona (unito).mkv")
    check(rc == 0 and os.path.exists(out) and sha(pal) == hp and sha(best) == hb, "film unito creato, i due originali identici byte per byte")
    if os.path.exists(out):
        v, a = tracks(out, "video"), tracks(out, "audio")
        check(len(v) == 1 and v[0]["width"] == 1280 and len(a) == 1 and a[0]["codec_name"] == "ac3" and a[0]["tags"].get("language") == "ita" and a[0]["disposition"]["default"] == 1, "immagine 1280×720 e audio italiano predefinito (Dolby Digital, velocità corretta)")
        ds = [sync(out, t) for t in (60, 200, 340)]; check(all(abs(d) < 0.03 for d in ds), "audio italiano a tempo con l'immagine in tutto il film (" + ", ".join(f"{d * 1000:+.0f} ms" for d in ds) + ")")
    same = film("stessa_vel.mkv", "640x360", "24000/1001", mix(IT, ",atrim=start=1.5,asetpts=PTS-STARTPTS"), "ita", DM - 1.5)   # stesso frame rate, audio che parte 1,5 s dopo
    rc, o = merge(best, same, "--audio", "b0,a0", "--default", "b0", "--output", os.path.join(T, "copia.mkv")); cp = os.path.join(T, "copia.mkv")
    check(rc == 0 and "copiato senza perdite" in o and os.path.exists(cp) and [s["codec_name"] for s in tracks(cp, "audio")] == ["aac", "aac"], "stesso frame rate: traccia italiana copiata senza ricodifica, ordine delle tracce rispettato")
    if os.path.exists(cp): ds = [sync(cp, t) for t in (60, 300)]; check(all(abs(d) < 0.03 for d in ds), "copia senza perdite spostata di 1,5 s e a tempo (" + ", ".join(f"{d * 1000:+.0f} ms" for d in ds) + ")")
    q0, q1 = os.path.join(T, "ant0.mp4"), os.path.join(T, "ant1.mp4")   # anteprima con la predefinita della copia con l'immagine: «Audio prima/dopo» deve comunque spostare l'audio che si sente
    merge(best, same, "--audio", "a0,b0", "--default", "a0", "--preview", "200", "--output", q0); merge(best, same, "--audio", "a0,b0", "--default", "a0", "--preview", "200", "--nudge", "0.04", "--output", q1)
    o = subprocess.run([BIN, "--sync-point", q0, "0", q1, "0", "7"], capture_output=True, text=True).stdout; m = re.search(r"a salti: d=([-+\d.]+)", o)
    check(m is not None and abs(float(m.group(1)) + 0.04) < 0.005, f"anteprima: «Audio prima» di 1 fotogramma sposta l'audio che si sente anche se la predefinita è dell'altra copia ({float(m.group(1)) * 1000 if m else 0:+.0f} ms)")
    rc, o = merge(best, same, "--audio", "b0", "--nudge-at", "200:0.08", "--output", os.path.join(T, "spostato.mkv")); sp = os.path.join(T, "spostato.mkv")
    check(rc == 0 and "Correzione a mano" in o and "Correzione automatica" not in o and os.path.exists(sp) and abs(sync(sp, 200) + 0.08) < 0.01, "correzione a mano di 80 ms conservata nel film unito, la verifica non la annulla")
    extra = film("scena_in_piu.mkv", "640x360", "24000/1001", f"{ME}[m];{IT}[d];[m][d]amix=inputs=2:normalize=0,aformat=channel_layouts=stereo,asplit[x][y];[x]atrim=0:200,asetpts=PTS-STARTPTS[p];[y]atrim=200,asetpts=PTS-STARTPTS[q];anoisesrc=d=6:c=white:a=0.6:r=48000,{gate(93.11, 9)},aformat=channel_layouts=stereo[n];[p][n][q]concat=n=3:v=0:a=1", "ita", DM + 6)
    rc, o = merge(best, extra, "--audio", "b0", "--output", os.path.join(T, "piu.mkv")); pu = os.path.join(T, "piu.mkv")
    check(rc == 0 and re.search(r"a 3:2\d.* 6\.0 s in più", o) is not None, "scena di 6 s in più nella copia italiana: trovata e saltata")
    if os.path.exists(pu): ds = [sync(pu, t) for t in (100, 300)]; check(all(abs(d) < 0.03 for d in ds), "prima e dopo la scena saltata l'audio è a tempo (" + ", ".join(f"{d * 1000:+.0f} ms" for d in ds) + ")")
    less = film("scena_in_meno.mkv", "640x360", "24000/1001", mix(IT, ",asplit[x][y];[x]atrim=0:150,asetpts=PTS-STARTPTS[p];[y]atrim=155,asetpts=PTS-STARTPTS[q];[p][q]concat=n=2:v=0:a=1"), "ita", DM - 5)
    rc, o = merge(best, less, "--audio", "b0", "--output", os.path.join(T, "meno.mkv")); me = os.path.join(T, "meno.mkv")
    check(rc == 0 and re.search(r"a 2:[23]\d.* mancano 5\.0 s", o) is not None, "scena di 5 s mancante nella copia italiana: lì resta silenzio")
    if os.path.exists(me): ds = [sync(me, t) for t in (80, 300)]; check(all(abs(d) < 0.03 for d in ds), "prima e dopo il silenzio l'audio è a tempo (" + ", ".join(f"{d * 1000:+.0f} ms" for d in ds) + ")")
    # copia con inglese e italiano, l'italiano montato male (120 ms in ritardo dopo 200 s); la copia con l'immagine ha solo l'inglese:
    # si allinea inglese con inglese, si misura il doppiaggio rispetto all'inglese nello stesso file e si sommano le due cose
    dub = os.path.join(T, "doppiata.mkv")
    ff("-f", "lavfi", "-i", f"testsrc2=s=640x360:r=24000/1001:d={DM}", "-filter_complex", mix(IT, ",asplit[x][y];[x]atrim=0:200,asetpts=PTS-STARTPTS[p];[y]atrim=200,asetpts=PTS-STARTPTS,adelay=120:all=1[q];[p][q]concat=n=2:v=0:a=1,atrim=0:" + str(DM)) + "[a];" + mix(EN).replace("[m]", "[m2]").replace("[d]", "[d2]") + "[b]",
       "-map", "0:v", "-map", "[a]", "-map", "[b]", "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "800k", "-c:a", "aac", "-b:a", "192k", "-metadata:s:a:0", "language=ita", "-metadata:s:a:1", "language=eng", "-shortest", dub)
    rc, o = merge(best, dub, "--audio", "b0", "--output", os.path.join(T, "dub.mkv")); du = os.path.join(T, "dub.mkv")
    check(rc == 0 and "inglese di tutte e due le copie" in o and "doppiaggio non è sempre a tempo" in o, "lingua in comune: allinea inglese con inglese e trova il doppiaggio italiano spostato a metà film")
    if os.path.exists(du): ds = [sync(du, t) for t in (100, 300)]; check(all(abs(d) < 0.03 for d in ds), "italiano a tempo prima e dopo il tratto montato male (" + ", ".join(f"{d * 1000:+.0f} ms" for d in ds) + ")")
    a = analyze(dub)
    check("Il doppiaggio non è a tempo con l'originale" in a and "in ritardo di 120 ms" in a and "INDISPENSABILE" in a, "controllo del film: doppiaggio confrontato con l'inglese dello stesso file, 120 ms di ritardo dopo 3:20 segnalati")
    rc, o = fixcopy(dub, "--retime-dub", "0:1"); dc = os.path.join(T, "doppiata (corretto).mkv")
    check(rc == 0 and "doppiaggio rimesso a tempo" in o and os.path.exists(dc) and "a tempo con la traccia in inglese" in analyze(dc) and abs(sync(dc, 300)) < 0.03, f"doppiaggio a gradini rimesso a tempo sull'inglese dello stesso file, senza una seconda copia ({sync(dc, 300) * 1000 if os.path.exists(dc) else 0:+.0f} ms a 5:00)")
    a = analyze(best)
    check("CONSIGLI PER LA PROIEZIONE" in a and "• Volume:" in a and "• Collegamento audio:" in a and "doppiaggio" not in a, "controllo del film: consigli per la proiezione (punto dove regolare il volume, collegamento audio)")
    # due copie con lo stesso montaggio (tagli d'inquadratura allo stesso posto) ma il doppiaggio dell'una a gradini: non è un montaggio diverso
    CUTS = "hue=H=2*PI*mod(floor(t/2.3)*0.37\\,1):s=1,eq=brightness='0.25*mod(floor(t/2.3)\\,3)-0.25':eval=frame"
    def cutfilm(name, audio_graph, lang):
        out = os.path.join(T, name)
        ff("-f", "lavfi", "-i", f"testsrc2=s=640x360:r=24000/1001:d={DM}", "-filter_complex", audio_graph + "[a]", "-map", "0:v", "-map", "[a]", "-vf", CUTS, "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "800k",
           "-c:a", "aac", "-b:a", "192k", "-metadata:s:a:0", f"language={lang}", "-shortest", out); return out
    cb = cutfilm("tagli_eng.mkv", mix(EN), "eng")
    ca = cutfilm("tagli_ita.mkv", mix(IT, ",asplit[x][y];[x]atrim=0:200,asetpts=PTS-STARTPTS[p];[y]atrim=200,asetpts=PTS-STARTPTS,adelay=120:all=1[q];[p][q]concat=n=2:v=0:a=1,atrim=0:" + str(DM)), "ita")
    rc, o = merge(ca, cb, "--video", "b", "--audio", "a0", "--align-only")
    check(rc == 0 and "Doppiaggio a gradini" in o and "le immagini delle due copie sono uguali" in o and "Montaggio diverso" not in o, "immagini uguali ai cambi di scarto: Booth dice che è il doppiaggio a gradini, non un montaggio diverso")
    other = film("altro_film.mkv", "640x360", "24000/1001", f"anoisesrc=d={DM}:c=brown:a=0.5:r=48000,{gate(55.55, 6)},aformat=channel_layouts=stereo", "ita", DM)
    rc, o = merge(best, other, "--audio", "b0", "--output", os.path.join(T, "altro.mkv"))
    check(rc != 0 and "NON ALLINEATO" in o and not os.path.exists(os.path.join(T, "altro.mkv")), "film diverso: unione rifiutata, nessun file creato")
finally:
    shutil.rmtree(T, ignore_errors=True)
print(f"\n{ok} controlli ok, {bad} falliti"); sys.exit(1 if bad else 0)
