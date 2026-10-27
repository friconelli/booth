#!/usr/bin/env python3
"""Copia gli strumenti open source usati dall'app (ffmpeg, ffprobe, mediainfo, whisper-cli) dentro l'app con tutte le librerie da cui dipendono e ne riscrive i percorsi, così funziona anche senza Homebrew.
ffmpeg viene preso da vendor/ffmpeg-zimg (tools/build_ffmpeg.sh, con zscale) se esiste, altrimenti da Homebrew.
Uso: tools/bundle_tools.py "dist/Booth.app/Contents/Resources"   → Resources/<strumenti>, Resources/lib/*.dylib"""
import glob, os, re, shutil, subprocess, sys
dest = os.path.abspath(sys.argv[1]); lib = os.path.join(dest, "lib"); os.makedirs(lib, exist_ok=True)
SYS = ("/usr/lib/", "/System/")
def otool(p): return [l.split(" (")[0].strip() for l in subprocess.run(["otool", "-L", p], capture_output=True, text=True).stdout.splitlines()[1:]]
def resolve(dep, owner):
    if dep.startswith("@rpath/") or dep.startswith("@loader_path/"):
        n = dep.split("/", 1)[1]
        for d in ("/opt/homebrew/lib", os.path.dirname(owner)):
            c = os.path.join(d, n)
            if os.path.exists(c): return os.path.realpath(c)
        raise SystemExit(f"non trovo {dep} (richiesta da {owner})")
    return os.path.realpath(dep)
copied = {}   # percorso reale → nome nella cartella lib
todo = []
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for b in ("ffmpeg", "ffprobe", "mediainfo", "whisper-cli"):
    mine = os.path.join(here, "vendor", "ffmpeg-zimg", "bin", b)
    src = mine if os.path.exists(mine) else (shutil.which(b) or f"/opt/homebrew/bin/{b}")
    if not os.path.exists(src): print(f"manca {b}: salto"); continue
    shutil.copy(os.path.realpath(src), os.path.join(dest, b)); os.chmod(os.path.join(dest, b), 0o755); todo.append(os.path.join(dest, b))
backends = []   # moduli di calcolo di ggml (CPU/Metal/BLAS): whisper-cli li carica a runtime dalla cartella dell'eseguibile
for so in sorted(glob.glob("/opt/homebrew/opt/ggml/libexec/*.so")):
    out = os.path.join(dest, os.path.basename(so)); shutil.copy(os.path.realpath(so), out); os.chmod(out, 0o755); backends.append(out)
queue = list(todo) + list(backends)
while queue:
    cur = queue.pop()
    for dep in otool(cur):
        if dep.startswith(SYS) or dep.startswith("@executable_path") or os.path.basename(dep) == os.path.basename(cur): continue
        real = resolve(dep, cur)
        if real not in copied:
            name = os.path.basename(real)
            if name in copied.values(): raise SystemExit(f"due librerie diverse con lo stesso nome: {name}")
            copied[real] = name
            out = os.path.join(lib, name); shutil.copy(real, out); os.chmod(out, 0o755); queue.append(out)
byname = {os.path.basename(k): v for k, v in copied.items()}
def fix(path, is_bin, prefix=None):
    if not is_bin and prefix is None: subprocess.run(["install_name_tool", "-id", "@loader_path/" + os.path.basename(path), path], capture_output=True)
    for dep in otool(path):
        if dep.startswith(SYS) or dep.startswith("@executable_path") or dep.startswith("@loader_path"): continue
        real = resolve(dep, path); name = copied.get(real) or byname.get(os.path.basename(real))
        if name: subprocess.run(["install_name_tool", "-change", dep, (prefix or ("@executable_path/lib/" if is_bin else "@loader_path/")) + name, path], capture_output=True)
for b in todo: fix(b, True)
for b in backends: fix(b, False, "@loader_path/lib/")
for name in copied.values(): fix(os.path.join(lib, name), False)
for p in todo + backends + [os.path.join(lib, n) for n in copied.values()]: subprocess.run(["codesign", "--force", "-s", "-", p], capture_output=True)
# controllo: nessun riferimento rimasto a /opt/homebrew
bad = [(p, d) for p in todo + backends + [os.path.join(lib, n) for n in copied.values()] for d in otool(p) if d.startswith("/opt/homebrew") or d.startswith("/usr/local")]
print(f"{len(copied)} librerie copiate, {sum(os.path.getsize(os.path.join(lib, n)) for n in copied.values()) / 1e6:.0f} MB; riferimenti esterni rimasti: {len(bad)}")
for p, d in bad[:5]: print("  ", os.path.basename(p), "→", d)
sys.exit(1 if bad else 0)
