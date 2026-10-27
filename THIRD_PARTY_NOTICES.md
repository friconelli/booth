# Componenti di terze parti

Booth è software libero, distribuito con licenza **GNU GPL v3** (vedi `LICENSE`). L'app include o usa questi programmi open source, di cui si riportano licenza e dove trovare il codice sorgente. Il codice di Booth è in https://github.com/friconelli/movie-preflight.

| Componente | Versione | Licenza | Sorgente |
|---|---|---|---|
| FFmpeg (ffmpeg, ffprobe) compilato con `--enable-gpl --enable-version3 --enable-libx264 --enable-libx265 --enable-libdav1d --enable-libsvtav1 --enable-libvmaf --enable-libzimg` | 9.0.2 | GPL v3 | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz (compilazione: `tools/build_ffmpeg.sh`) |
| x264 | r3222 | GPL v2 o successiva | https://www.videolan.org/developers/x264.html |
| x265 | 4.3 | GPL v2 | https://bitbucket.org/multicoreware/x265_git |
| dav1d | 1.5.4 | BSD 2-Clause | https://code.videolan.org/videolan/dav1d |
| SVT-AV1 | 4.2.0 | BSD 2-Clause + licenza brevetti AOM | https://gitlab.com/AOMediaCodec/SVT-AV1 |
| libvmaf (Netflix) | 3.2.1 | BSD 2-Clause + brevetti | https://github.com/Netflix/vmaf |
| zimg | 3.0.6 | WTFPL | https://github.com/sekrit-twc/zimg |
| MediaInfo / MediaInfoLib | 26.05 | BSD 2-Clause | https://mediaarea.net/en/MediaInfo |
| ZenLib | 0.4.41 | zlib | https://github.com/MediaArea/ZenLib |
| whisper.cpp | 1.9.4 | MIT | https://github.com/ggml-org/whisper.cpp |
| ggml | 0.26.0 | MIT | https://github.com/ggml-org/ggml |
| Modello vocale Whisper «base» (scaricato dall'utente al primo uso, non incluso) | ggml-base.bin | MIT (OpenAI) | https://huggingface.co/ggerganov/whisper.cpp |
| libomp (LLVM OpenMP) | 23.1.2 | Apache 2.0 con eccezione LLVM | https://openmp.llvm.org |
| MKVToolNix (mkvpropedit, **non incluso**: usato solo se già installato) | — | GPL v2 | https://mkvtoolnix.download |

Il formato Dolby Digital (AC-3) viene prodotto con l'encoder libero di FFmpeg, non con gli encoder ufficiali Dolby. Dolby, Dolby Digital, Dolby Vision e Dolby Atmos sono marchi di Dolby Laboratories; qui servono solo a indicare i formati.

Per ricostruire l'app con gli stessi componenti: `brew install pkgconf x264 x265 dav1d svt-av1 libvmaf zimg whisper-cpp media-info`, poi `tools/build_ffmpeg.sh` e `./build.sh`.

## Dati online (opzionali, con consenso dell'utente)
- **Wikidata** (https://www.wikidata.org): dati strutturati in pubblico dominio (CC0).
- **Wikipedia** (it/en): descrizioni sotto CC BY-SA 4.0; le locandine sono ospitate da Wikipedia con le loro licenze (spesso uso a fini di identificazione) e vengono solo mostrate nell'app, mai salvate o ridistribuite.
Alle API viene inviato soltanto il titolo (e l'anno) ricavato dal nome del file, con uno User-Agent che identifica l'app.
