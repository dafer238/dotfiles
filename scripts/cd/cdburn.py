#!/usr/bin/env python3
"""
cdburn - turn folders of music into gapless, bit-perfect Audio CDs with printable labels.

  cdburn                          interactive menu (j/k move · enter/l open · space toggle · h/esc back · q quit)
  cdburn new DIR [DIR ...]        start a project from one or more music folders (-p sets the project folder)
  cdburn scan                     rescan the project's music folders
  cdburn plan                     automatic disc plan (which albums go on which CD)
  cdburn status                   the plan and the state of every disc
  cdburn build CD01 [CD02 ...]|all [-j N]   make burn-ready images
  cdburn burn CD05 [--simulate] [--speed N] [--device DEV] [-y]
  cdburn verify CD05 [--readback FILE]
  cdburn labels [--no-open]       write labels.html + tracklists.txt and open the labels
  cdburn install | uninstall      add/remove the 'cdburn' command

Global option: -p/--project DIR (default: the current folder if it holds a project, else the last one used).
Linux: ffmpeg + cdrdao + cdparanoia.  Windows: ffmpeg + ImgBurn (or cdrdao).
"""
import argparse
import array
import hashlib
import json
import math
import mmap
import os
import random
import re
import shutil
import subprocess
import sys
import time
import unicodedata
from collections import Counter
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor, as_completed
from pathlib import Path

VERSION = "1.0.0"
WINDOWS = os.name == "nt"
if WINDOWS:
    import msvcrt
else:
    import select
    import termios
    import tty

SELF = Path(__file__).resolve()
PROJECT_FILE = "cdburn.json"
CACHE_FILE = ".cdburn-cache.json"
RATE = 44100
FRAME = 588                      # samples per CD sector (1/75 s)
MIN_TRACK_S = 4.1                # Red Book minimum track length is 4 s
AUDIO_EXT = {".flac", ".wav", ".wave", ".aif", ".aiff", ".aifc", ".mp3", ".m4a", ".alac", ".ogg", ".oga", ".opus",
             ".wv", ".ape", ".wma", ".dsf", ".dff", ".tta", ".tak", ".mpc"}
LOSSLESS = {"flac", "alac", "wavpack", "ape", "tta", "tak", "mlp", "truehd"}
LOSSY_NAMES = {"mp3": "MP3", "aac": "AAC", "vorbis": "Ogg Vorbis", "opus": "Opus", "wmav2": "WMA", "wmav1": "WMA",
               "musepack7": "Musepack", "musepack8": "Musepack", "mp2": "MP2"}
DISC_DIR = re.compile(r"^(?:cd|disc|disk|disco|part)\s*[-_.#]?\s*(\d{1,2})\b|^(\d{1,2})$", re.I)
KEEP_TAGS = ("title", "artist", "album_artist", "albumartist", "album", "date", "year", "originaldate",
             "original_year", "originalyear", "track", "tracknumber", "disc", "discnumber")

DEFAULT_SETTINGS = {
    "capacity_min": 80,          # blank CD size
    "margin_s": 30,              # keep away from the very edge of the disc
    "gap_s": 2,                  # silence between two albums on one disc
    "combine": "any",            # put short albums together: any | artist | off
    "max_per_disc": 2,
    "pair_split": False,         # may a part of a split album share a disc?
    "clean_titles": True,        # drop "(2019 Mix)", "(Remastered 2011)" ... from track titles
    "cdtext": True,
    "precision": 28,             # soxr precision (28 = very high quality, 33 = maximum)
    "dither": "triangular",      # TPDF; or shibata (noise shaped), triangular_hp
    "ceiling_db": -0.05,         # peak limit before 16-bit (constant gain only if exceeded)
    "jobs": max(1, min(4, (os.cpu_count() or 2) // 2)),
}
SETTING_INFO = {
    "capacity_min": "Blank CD length (minutes)",
    "margin_s": "Safety margin at the end of the disc (seconds)",
    "gap_s": "Silence between two albums on the same CD (seconds)",
    "combine": "Put short albums on the same CD",
    "max_per_disc": "Max albums per CD",
    "pair_split": "Allow parts of split albums to share a CD",
    "clean_titles": "Clean track titles (drop '(2019 Mix)', '(Remastered)' ...)",
    "cdtext": "Write CD-Text (names on the car display)",
    "precision": "Resampler precision (bits)",
    "dither": "Dither when reducing to 16 bit",
    "ceiling_db": "Peak ceiling before 16-bit (dBFS)",
    "jobs": "Discs to build in parallel",
}
TITLE_NOISE = [
    re.compile(r"\s*[\(\[]\s*(?:(?:19|20)\d\d\s+)?(?:digital(?:ly)?\s+)?remaster(?:ed)?(?:\s+(?:version|(?:19|20)\d\d))?\s*[\)\]]\s*$", re.I),
    re.compile(r"\s*[\(\[]\s*(?:19|20)\d\d\s+(?:stereo\s+)?(?:mix|remix|version)\s*[\)\]]\s*$", re.I),
    re.compile(r"\s+-\s+(?:(?:19|20)\d\d\s+)?(?:digital\s+)?remaster(?:ed)?(?:\s+(?:19|20)\d\d)?(?:\s+version)?\s*$", re.I),
]

# ------------------------------------------------------------------ colours --
TTY = sys.stdout.isatty() and sys.stdin.isatty()
if WINDOWS:
    os.system("")                # enables ANSI escape codes in the Windows console
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8")
        except Exception:
            pass
if TTY and not os.environ.get("NO_COLOR"):
    C0, CB, CD, CR, CG, CY, CBL, CM, CC, CRV = ("\x1b[0m", "\x1b[1m", "\x1b[2m", "\x1b[31m", "\x1b[32m", "\x1b[33m",
                                                "\x1b[34m", "\x1b[35m", "\x1b[36m", "\x1b[7m")
else:
    C0 = CB = CD = CR = CG = CY = CBL = CM = CC = CRV = ""
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def say(s=""): print(s, flush=True)
def info(s): print(f"{CBL}::{C0} {s}", flush=True)
def ok(s): print(f"{CG}✔{C0} {s}", flush=True)
def warn(s): print(f"{CY}!{C0} {s}", file=sys.stderr, flush=True)
def err(s): print(f"{CR}✘{C0} {s}", file=sys.stderr, flush=True)
def have(cmd): return shutil.which(cmd) is not None


def tildify(p):
    p, h = str(p), str(Path.home())
    return "~" + p[len(h):] if p == h or p.startswith(h + os.sep) else p


def mmss(sec):
    sec = int(round(sec or 0))
    return f"{sec // 60}:{sec % 60:02d}"


def msf(frames):
    m, rest = divmod(int(frames), 75 * 60)
    s, f = divmod(rest, 75)
    return f"{m:02d}:{s:02d}:{f:02d}"


def hsize(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:.0f}{u}" if u == "B" else f"{n:.1f}{u}"
        n /= 1024


def slug(s, n=40):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-")[:n] or "disc"


def now_iso(): return time.strftime("%Y-%m-%d %H:%M")


def write_json(path, data):
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=1, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def open_path(p):
    p = str(p)
    try:
        if WINDOWS:
            os.startfile(p)  # type: ignore[attr-defined]
        elif sys.platform == "darwin":
            subprocess.Popen(["open", p])
        else:
            subprocess.Popen(["xdg-open", p], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception as e:
        warn(f"could not open {p}: {e}")


# ------------------------------------------------------------------- config --
def config_dir():
    if WINDOWS:
        return Path(os.environ.get("APPDATA", Path.home())) / "cdburn"
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "cdburn"


CFG_FILE = config_dir() / "config.json"
CFG = {"device": "", "speed": 16, "engine": "auto", "driver": "", "imgburn": "", "last_project": "", "recent": []}


def load_cfg():
    try:
        CFG.update(json.loads(CFG_FILE.read_text(encoding="utf-8")))
    except Exception:
        pass


def save_cfg():
    CFG_FILE.parent.mkdir(parents=True, exist_ok=True)
    write_json(CFG_FILE, CFG)


def remember_project(d):
    d = str(Path(d).resolve())
    CFG["last_project"] = d
    CFG["recent"] = [d] + [x for x in CFG.get("recent", []) if x != d][:9]
    save_cfg()


# ------------------------------------------------------------------ project --
class Project:
    def __init__(self, folder):
        self.dir = Path(folder).expanduser().resolve()
        self.file = self.dir / PROJECT_FILE
        self.data = {"version": 1, "sources": [], "albums": [], "discs": [], "settings": dict(DEFAULT_SETTINGS),
                     "plan_basis": "", "plan_manual": False, "plan_locked": False, "sig_version": 2}

    @classmethod
    def load(cls, folder):
        p = cls(folder)
        d = json.loads(p.file.read_text(encoding="utf-8"))
        p.data.update(d)
        p.data["settings"] = {**DEFAULT_SETTINGS, **d.get("settings", {})}
        if d.get("sig_version", 1) < 2:
            # v1 disc signatures used full paths; convert so built/burned/verified states are kept
            for disc in p.discs:
                old, new = disc_sig(p, disc, legacy=True), disc_sig(p, disc)
                for st in disc.get("status", {}).values():
                    if st.get("sig") == old:
                        st["sig"] = new
            p.data["sig_version"] = 2
            p.save()
        return p

    def save(self):
        self.dir.mkdir(parents=True, exist_ok=True)
        write_json(self.file, self.data)

    sources = property(lambda s: s.data["sources"])
    albums = property(lambda s: s.data["albums"])
    discs = property(lambda s: s.data["discs"])
    S = property(lambda s: s.data["settings"])
    build_dir = property(lambda s: s.dir / "build")

    def album(self, aid):
        for a in self.albums:
            if a["id"] == aid:
                return a
        return None

    def budget(self):
        return self.S["capacity_min"] * 60 - self.S["margin_s"]

    def max_frames(self):
        return self.S["capacity_min"] * 60 * 75 - 1


# ---------------------------------------------------------------- tools ---
def ffbin(name):
    return shutil.which(name) or shutil.which(name + ".exe")


FFMPEG, FFPROBE = ffbin("ffmpeg"), ffbin("ffprobe")


def need_ffmpeg():
    if not (FFMPEG and FFPROBE):
        err("ffmpeg/ffprobe not found.")
        say("  Install:  " + install_hint("ffmpeg"))
        sys.exit(1)


_SOXR = None


def has_soxr():
    global _SOXR
    if _SOXR is None:
        try:
            out = subprocess.run([FFMPEG, "-hide_banner", "-buildconf"], capture_output=True, text=True).stdout
            _SOXR = "libsoxr" in out
        except Exception:
            _SOXR = False
    return _SOXR


def pkg_manager():
    for pm in ("pacman", "apt", "dnf", "zypper", "brew", "winget"):
        if have(pm):
            return pm
    return ""


def install_hint(*what):
    pm = pkg_manager()
    names = " ".join(what)
    if WINDOWS:
        m = {"ffmpeg": "Gyan.FFmpeg", "imgburn": "LIGHTNINGUK.ImgBurn"}
        return " & ".join(f"winget install {m.get(w, w)}" for w in what)
    return {"pacman": f"sudo pacman -S --needed {names}", "apt": f"sudo apt install {names}",
            "dnf": f"sudo dnf install {names}", "zypper": f"sudo zypper install {names}",
            "brew": f"brew install {names}"}.get(pm, f"install: {names}")


# ------------------------------------------------------------------ probing --
def probe_file(path):
    try:
        out = subprocess.run([FFPROBE, "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", str(path)],
                             capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
        j = json.loads(out or "{}")
    except Exception:
        return None
    streams = [s for s in j.get("streams", []) if s.get("codec_type") == "audio"]
    if not streams:
        return None
    s, fmt = streams[0], j.get("format", {})
    tags = {}
    for src in (s.get("tags") or {}, fmt.get("tags") or {}):
        for k, v in src.items():
            tags.setdefault(k.lower(), v)
    codec = s.get("codec_name", "?")
    bits = s.get("bits_per_raw_sample") or s.get("bits_per_sample")
    bits = int(bits) if str(bits).isdigit() and int(bits) > 0 else None
    m = re.match(r"pcm_[su](\d+)", codec)
    if m:
        bits = int(m.group(1))
    if codec.startswith("pcm_f"):
        bits = 32
    try:
        dur = float(fmt.get("duration") or s.get("duration") or 0)
    except ValueError:
        dur = 0.0
    return {"codec": codec, "rate": int(s.get("sample_rate") or 0), "bits": bits, "channels": int(s.get("channels") or 2),
            "duration": dur, "tags": {k: tags[k] for k in KEEP_TAGS if k in tags}}


def lossless(codec): return codec in LOSSLESS or (codec.startswith("pcm_") and not codec.startswith("pcm_f"))
def is_exact(t): return lossless(t["codec"]) and t["rate"] == RATE and t["bits"] == 16 and t["channels"] == 2


def quality_of(t):
    c = t["codec"]
    if c.startswith("dsd"):
        return "DSD → 16/44.1"
    if c in LOSSY_NAMES or not (lossless(c) or c.startswith("pcm_f")):
        return f"{LOSSY_NAMES.get(c, c.upper())} (lossy)"
    if is_exact(t):
        return "16/44.1 bit-perfect"
    chs = "" if t["channels"] == 2 else " mono" if t["channels"] == 1 else f" {t['channels']}ch"
    return f"{t['bits'] or '?'}/{t['rate'] / 1000:g}{chs} → 16/44.1"


def quality_label(tracks):
    return " + ".join(sorted(dict.fromkeys(quality_of(t) for t in tracks)))


def num(v):
    m = re.match(r"\s*(\d+)", str(v or ""))
    return int(m.group(1)) if m else None


def read_text_any(p):
    for enc in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return Path(p).read_text(encoding=enc)
        except UnicodeDecodeError:
            continue
    return ""


def parse_cue(path):
    """single-file CUE sheet -> (file name, album title, album performer, [ {n,title,performer,start} ])"""
    files, tracks, cur = [], [], None
    meta = {}
    for line in read_text_any(path).splitlines():
        line = line.strip()
        m = re.match(r'(\w+)\s+(.*)', line)
        if not m:
            continue
        key, rest = m.group(1).upper(), m.group(2).strip()
        val = rest[1:rest.rfind('"')] if rest.startswith('"') else rest.split()[0] if rest else ""
        if key == "FILE":
            files.append(val)
        elif key == "TRACK":
            cur = {"n": num(rest), "title": "", "performer": "", "start": None, "audio": "AUDIO" in rest.upper()}
            tracks.append(cur)
        elif key in ("TITLE", "PERFORMER"):
            if cur is None:
                meta[key.lower()] = val
            else:
                cur["title" if key == "TITLE" else "performer"] = val
        elif key == "INDEX" and cur is not None:
            mm = re.match(r"(\d+)\s+(\d+):(\d+):(\d+)", rest)
            if mm and int(mm.group(1)) == 1:
                cur["start"] = (int(mm.group(2)) * 60 + int(mm.group(3))) * 75 + int(mm.group(4))
    tracks = [t for t in tracks if t["audio"] and t["start"] is not None]
    return files, meta, tracks


def clean_title(t):
    t = re.sub(r"\s+", " ", t or "").strip()
    for _ in range(2):
        for p in TITLE_NOISE:
            t = p.sub("", t)
    return t.strip() or "Untitled"


def title_from_filename(stem):
    s = re.sub(r"^\s*(?:\d{1,2}[-.]?)?\d{1,3}\s*[-._)]\s*", "", stem)
    return s.strip() or stem


def clean_album_title(t):
    t = re.sub(r"^\[(.*?)\]", r"\1", (t or "").strip())
    junk = r"flac|mp3|wav|24.?bit|16.?bit|\d+\s*khz|hi-?res|web|vinyl|cd rip|\b\d{2}-\d{2,3}\b"
    t = re.sub(r"\s*[\(\[][^\)\]]*(?:" + junk + r")[^\)\]]*[\)\]]", "", t, flags=re.I)
    t = re.sub(r"\s*[\(\[]\s*(?:cd|disc|disk)?\s*\d{1,2}\s*[\)\]]\s*$", "", t, flags=re.I)
    t = re.sub(r"\s*[-–:]?\s*(?:cd|disc|disk)\s*\d{1,2}\s*$", "", t, flags=re.I)
    t = re.sub(r"\s*[\(\[](?:19|20)\d\d[\)\]]\s*$", "", t)
    t = re.sub(r"\s*[\(\[][^\)\]]*\b(?:remaster(?:ed)?|deluxe|anniversary|edition|expanded|collector'?s|reissue)\b[^\)\]]*[\)\]]",
               "", t, flags=re.I)
    for p in TITLE_NOISE:
        t = p.sub("", t)
    return re.sub(r"\s+", " ", t).strip()


def folder_guess(name):
    base = re.sub(r"[\[\(\{][^\]\)\}]*[\]\)\}]", " ", name)
    parts = [p.strip() for p in re.split(r"\s+[-–]\s+", base) if p.strip() and not re.fullmatch(r"(?:19|20)\d\d", p.strip())]
    if len(parts) >= 2:
        return parts[0], parts[-1]
    return "", (parts[0] if parts else name).strip()


def years_in(s):
    cur = int(time.strftime("%Y")) + 1
    return [int(y) for y in re.findall(r"(?<!\d)((?:19|20)\d\d)(?!\d)", str(s or "")) if 1900 <= int(y) <= cur]


def norm_key(s):
    s = re.sub(r"[\[\(\{][^\]\)\}]*[\]\)\}]", "", (s or "").lower())
    s = re.sub(r"^the\s+", "", s.strip())
    return re.sub(r"[^a-z0-9]+", "", unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode())


def find_album_dirs(sources, skip):
    leaves = {}
    for src in sources:
        for dp, dns, fns in os.walk(src):
            d = Path(dp)
            dns[:] = sorted(x for x in dns if not x.startswith(".") and (d / x).resolve() not in skip
                            and not (d / x / PROJECT_FILE).exists())
            aud = sorted(f for f in fns if Path(f).suffix.lower() in AUDIO_EXT and not f.startswith("."))
            if aud:
                leaves[d] = aud
    groups = {}
    for d in sorted(leaves):
        m = DISC_DIR.match(d.name)
        if m and d.parent not in leaves:
            groups.setdefault(d.parent, []).append((int(m.group(1) or m.group(2)), d, leaves[d]))
        else:
            groups.setdefault(d, []).append((0, d, leaves[d]))
    for g in groups.values():
        g.sort(key=lambda x: (x[0], str(x[1])))
    return groups


def scan_project(P, progress=None):
    """(re)scan all music folders. Keeps edits/choices for albums seen before."""
    need_ffmpeg()
    cache_file = P.dir / CACHE_FILE
    try:
        cache = json.loads(cache_file.read_text(encoding="utf-8"))
    except Exception:
        cache = {}
    skip = {P.dir.resolve()}
    groups = find_album_dirs([Path(s) for s in P.sources], skip)
    files = [d / f for g in groups.values() for _, d, fs in g for f in fs]
    todo = []
    probes = {}
    for f in files:
        st = f.stat()
        c = cache.get(str(f))
        if c and c.get("size") == st.st_size and c.get("mtime") == int(st.st_mtime):
            probes[str(f)] = c
        else:
            todo.append((f, st))
    done = 0
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(probe_file, f): (f, st) for f, st in todo}
        for fu in as_completed(futs):
            f, st = futs[fu]
            p = fu.result()
            done += 1
            if progress:
                progress(done, len(todo))
            if p:
                p.update(size=st.st_size, mtime=int(st.st_mtime))
                probes[str(f)] = p
    cache = {k: v for k, v in probes.items()}
    try:
        write_json(cache_file, cache)
    except OSError:
        pass

    built = [a for a in (build_album(folder, parts, probes) for folder, parts in groups.items()) if a]
    old = {a["folder"]: a for a in P.albums}
    # a renamed/moved folder keeps its files: recognise it by them so its id, edits and CDs survive
    found = {a["folder"] for a in built}
    moved = {album_fingerprint(a): a for a in P.albums if a["folder"] not in found}
    albums = []
    for a in built:
        prev = old.get(a["folder"]) or moved.get(album_fingerprint(a))
        if prev:
            a["id"] = prev["id"]
            a["include"] = prev.get("include", True)
            a["dup_of"] = prev.get("dup_of")
            for k in prev.get("edited", []):
                a[k] = prev[k]
            a["edited"] = prev.get("edited", [])
            pt = {(Path(t["path"]).name, t.get("cue_start")): t for t in prev["tracks"]}
            for t in a["tracks"]:
                q = pt.get((Path(t["path"]).name, t.get("cue_start")))
                if q:
                    t["include"] = q.get("include", True)
                    if q.get("title"):
                        t["title"] = q["title"]
            a["_new"] = False
        albums.append(a)
    mark_duplicates(albums)
    for a in albums:
        a.pop("_new", None)
    albums.sort(key=album_sort)
    P.data["albums"] = albums
    P.data["scanned"] = now_iso()
    P.save()
    return albums


def build_album(folder, parts, probes):
    tracks, part_names = [], []
    multi_dir = len(parts) > 1 or parts[0][1] != folder
    cue_meta = {}
    for pi, (pno, d, fnames) in enumerate(parts):
        part_names.append(d.name if multi_dir else "")
        ptracks = []
        cues = sorted(d.glob("*.cue")) + sorted(d.glob("*.CUE"))
        image = None
        if len(fnames) == 1 and cues:
            for c in cues:
                cf, meta, ct = parse_cue(c)
                if len(cf) == 1 and len(ct) >= 2:
                    image = (c, meta, ct)
                    break
        if image:
            c, meta, ct = image
            path = d / fnames[0]
            pr = probes.get(str(path))
            if not pr:
                continue
            cue_meta = meta
            for i, ctr in enumerate(ct):
                end = ct[i + 1]["start"] if i + 1 < len(ct) else None
                dur = ((end - ctr["start"]) / 75) if end is not None else pr["duration"] - ctr["start"] / 75
                tg = dict(pr["tags"])
                tg["title"] = ctr["title"] or f"Track {ctr['n']}"
                tg["artist"] = ctr["performer"] or meta.get("performer") or tg.get("artist", "")
                tg["album"] = meta.get("title") or tg.get("album", "")
                ptracks.append(track_rec(path, pr, tg, pi, dur, ctr["start"], end, ctr["n"]))
        else:
            for f in fnames:
                path = d / f
                pr = probes.get(str(path))
                if not pr:
                    continue
                ptracks.append(track_rec(path, pr, pr["tags"], pi, pr["duration"], None, None,
                                         num(pr["tags"].get("track") or pr["tags"].get("tracknumber"))))
            ptracks.sort(key=lambda t: (t["_disc"] or 0, t["_n"] if t["_n"] is not None else 999, t["path"]))
        tracks += ptracks
    if not tracks:
        return None
    if not multi_dir:
        discs = sorted({t["_disc"] or 1 for t in tracks})
        if len(discs) > 1:
            for t in tracks:
                t["part"] = discs.index(t["_disc"] or 1)
            part_names = [f"Disc {x}" for x in discs]
            tracks.sort(key=lambda t: (t["part"], t["_n"] if t["_n"] is not None else 999, t["path"]))
    for t in tracks:
        t.pop("_disc", None)
        t.pop("_n", None)

    tags = [t["tags"] for t in tracks]
    cnt = lambda key: Counter(x for x in (tg.get(k) for tg in tags for k in key) if x)
    aa = cnt(("album_artist", "albumartist"))
    ta = Counter(t["artist"] for t in tracks if t["artist"])
    f_artist, f_title = folder_guess(folder.name)
    va = False
    if aa:
        artist = aa.most_common(1)[0][0]
        va = artist.lower() in ("various artists", "various", "va")
    elif ta:
        top, n = ta.most_common(1)[0]
        if len(ta) > 2 and n < len(tracks) / 2:
            artist, va = "Various Artists", True
        else:
            artist = top.split(";")[0].strip()
    else:
        artist = cue_meta.get("performer") or f_artist or "Unknown Artist"
    alb = cnt(("album",))
    title = clean_album_title(alb.most_common(1)[0][0]) if alb else ""
    title = title or cue_meta.get("title") or f_title or folder.name
    years = years_in(folder.name) + [y for tg in tags for k in ("date", "year", "originaldate", "original_year", "originalyear")
                                     for y in years_in(tg.get(k))]
    year = min(years) if years else ""
    for t in tracks:
        t.pop("tags", None)
    guess = {"artist": artist, "title": title, "year": year}
    return {"id": hashlib.sha1(str(folder).encode()).hexdigest()[:10], "folder": str(folder), **guess, "guess": guess,
            "va": va, "include": True, "edited": [], "dup_of": None, "parts": part_names, "tracks": tracks, "_new": True}


def track_rec(path, pr, tags, part, dur, cue_start, cue_end, n):
    title = tags.get("title") or title_from_filename(Path(path).stem)
    return {"path": str(path), "tag_title": title, "title": None, "artist": (tags.get("artist") or "").split(";")[0].strip(),
            "duration": max(0.0, dur), "codec": pr["codec"], "rate": pr["rate"], "bits": pr["bits"],
            "channels": pr["channels"], "size": pr["size"], "mtime": pr["mtime"], "part": part,
            "cue_start": cue_start, "cue_end": cue_end, "include": True, "tags": tags,
            "_disc": num(tags.get("disc") or tags.get("discnumber")), "_n": n}


def album_fingerprint(a):
    """identifies an album by its files (names + sizes), independent of where its folder is"""
    return tuple(sorted((Path(t["path"]).name, t.get("size"), t.get("cue_start")) for t in a["tracks"]))


def album_quality_score(a):
    ts = a["tracks"]
    return (all(lossless(t["codec"]) for t in ts), min((t["bits"] or 0) for t in ts), min(t["rate"] for t in ts), len(ts))


def mark_duplicates(albums):
    by = {}
    for a in albums:
        by.setdefault((norm_key(a["artist"]), norm_key(a["title"])), []).append(a)
    for group in by.values():
        if len(group) < 2:
            continue
        best = max(group, key=album_quality_score)
        for a in group:
            if a is not best and (a.get("_new") or best.get("_new")):
                a["include"] = False
                a["dup_of"] = best["id"]
            elif a is best and a.get("_new"):
                a["dup_of"] = None


def artist_key(s):
    s = (s or "").lower().strip()
    return re.sub(r"^the\s+", "", s)


def album_sort(a):
    y = a.get("year")
    return (artist_key(a["artist"]), int(y) if str(y).isdigit() else 9999, a["title"].lower(), a["folder"])


def track_title(P, t):
    if t.get("title"):
        return t["title"]
    return clean_title(t["tag_title"]) if P.S["clean_titles"] else t["tag_title"]


def inc_tracks(a):
    return [i for i, t in enumerate(a["tracks"]) if t.get("include", True)]


def album_duration(a, idx=None):
    idx = inc_tracks(a) if idx is None else idx
    return sum(a["tracks"][i]["duration"] for i in idx)


# ----------------------------------------------------------------- planning --
def plan_basis(P):
    S = P.S
    h = hashlib.sha1()
    for a in P.albums:
        if a.get("include"):
            h.update(json.dumps([a["id"], inc_tracks(a), [round(t["duration"], 2) for t in a["tracks"]],
                                 a["artist"], a["year"], a["title"]]).encode())
    h.update(json.dumps([S[k] for k in ("capacity_min", "margin_s", "gap_s", "combine", "max_per_disc", "pair_split")]).encode())
    return h.hexdigest()[:16]


def plan_stale(P):
    return bool(P.discs) and P.data.get("plan_basis") != plan_basis(P)


def linear_partition(d, k):
    """split list of durations d into k consecutive groups minimising the longest group"""
    n = len(d)
    pre = [0]
    for x in d:
        pre.append(pre[-1] + x)
    INF = float("inf")
    best = [[INF] * (n + 1) for _ in range(k + 1)]
    cut = [[0] * (n + 1) for _ in range(k + 1)]
    best[0][0] = 0
    for j in range(1, k + 1):
        for i in range(j, n + 1):
            for m in range(j - 1, i):
                v = max(best[j - 1][m], pre[i] - pre[m])
                if v < best[j][i]:
                    best[j][i], cut[j][i] = v, m
    groups, i = [], n
    for j in range(k, 0, -1):
        m = cut[j][i]
        groups.append((m, i))
        i = m
    return best[k][n], groups[::-1]


def split_album(a, idx, budget):
    durs = [a["tracks"][i]["duration"] for i in idx]
    if any(x > budget for x in durs):
        raise ValueError(f"{a['artist']} - {a['title']}: a single track is longer than a CD")
    total = sum(durs)
    kmin = math.ceil(total / budget)
    parts = []
    for i in idx:
        p = a["tracks"][i]["part"]
        if parts and parts[-1][0] == p:
            parts[-1][1].append(i)
        else:
            parts.append((p, [i]))
    if len(parts) > 1:
        groups, cur, cd, okp = [], [], 0.0, True
        for _, p in parts:
            d = sum(a["tracks"][i]["duration"] for i in p)
            if d > budget:
                okp = False
                break
            if cur and cd + d > budget:
                groups.append(cur)
                cur, cd = [], 0.0
            cur, cd = cur + p, cd + d
        if okp:
            groups.append(cur)
            if len(groups) == kmin:
                return groups
    for k in range(kmin, len(idx) + 1):
        worst, g = linear_partition(durs, k)
        if worst <= budget:
            return [idx[s:e] for s, e in g]
    raise ValueError("cannot split album")


def auto_plan(P):
    budget, gap = P.budget(), P.S["gap_s"]
    units = []
    for a in sorted((a for a in P.albums if a.get("include")), key=album_sort):
        idx = inc_tracks(a)
        if not idx:
            continue
        if album_duration(a, idx) <= budget:
            units.append({"album": a["id"], "tracks": idx, "part": "", "pair": True, "artist": a["artist"],
                          "dur": album_duration(a, idx), "key": album_sort(a) + (0,)})
            continue
        groups = split_album(a, idx, budget)
        for j, g in enumerate(groups):
            units.append({"album": a["id"], "tracks": g, "part": f"Disc {j + 1} of {len(groups)}",
                          "pair": P.S["pair_split"], "artist": a["artist"], "dur": album_duration(a, g),
                          "key": album_sort(a) + (j,)})
    bins = [[u] for u in units]
    mode, maxn = P.S["combine"], max(1, int(P.S["max_per_disc"]))
    bdur = lambda b: sum(u["dur"] for u in b) + gap * (len(b) - 1)
    if mode != "off" and maxn > 1:
        for p in (["artist", "any"] if mode == "any" else ["artist"]):
            for b in sorted([b for b in bins if len(b) == 1 and b[0]["pair"]], key=bdur):
                if b not in bins:
                    continue
                u = b[0]
                cands = [t for t in bins if t is not b and len(t) < maxn and all(x["pair"] for x in t)
                         and bdur(t) + gap + u["dur"] <= budget
                         and (p == "any" or all(x["artist"] == u["artist"] for x in t))]
                if cands:
                    # same artist first, then the closest release year, then the tightest fit
                    yr = lambda x: x["key"][1] if x["key"][1] != 9999 else 0
                    t = min(cands, key=lambda c: (min(abs(yr(x) - yr(u)) for x in c), -bdur(c)))
                    t.append(u)
                    bins.remove(b)
    for b in bins:
        b.sort(key=lambda u: u["key"])
    bins.sort(key=lambda b: b[0]["key"])
    old = {disc_sig(P, d): d.get("status", {}) for d in P.discs}
    discs = []
    for b in bins:
        d = {"uid": "%08x" % random.getrandbits(32),
             "segments": [{"album": u["album"], "tracks": u["tracks"], "part": u["part"]} for u in b], "status": {}}
        d["status"] = old.get(disc_sig(P, d), {})
        discs.append(d)
    if P.discs:
        P.data["plan_undo"] = {"discs": P.discs, "plan_basis": P.data.get("plan_basis", ""),
                               "plan_manual": P.data.get("plan_manual", False), "at": now_iso()}
    P.data["discs"] = discs
    P.data["plan_basis"] = plan_basis(P)
    P.data["plan_manual"] = False
    P.save()
    return discs


def undo_plan(P):
    """swap the current plan with the one before the last re-plan (so undo can itself be undone)"""
    u = P.data.get("plan_undo")
    if not u:
        return False
    cur = {"discs": P.discs, "plan_basis": P.data.get("plan_basis", ""),
           "plan_manual": P.data.get("plan_manual", False), "at": now_iso()}
    # keep states (built/burned/verified) gathered since, for discs that exist in both plans
    states = {}
    for d in P.discs + u["discs"]:
        for k, st in d.get("status", {}).items():
            prev = states.setdefault(st.get("sig"), {}).get(k)
            if not prev or st.get("at", "") > prev.get("at", ""):
                states[st.get("sig")][k] = st
    P.data["discs"] = u["discs"]
    for d in P.discs:
        d["status"] = dict(states.get(disc_sig(P, d), {}))
    P.data["plan_basis"], P.data["plan_manual"] = u["plan_basis"], u["plan_manual"]
    P.data["plan_undo"] = cur
    P.save()
    return True


def burned_count(P):
    return sum(1 for d in P.discs if disc_state(P, d)["burned"])


def disc_duration(P, d):
    tot = 0.0
    for s in d["segments"]:
        a = P.album(s["album"])
        if a:
            tot += sum(a["tracks"][i]["duration"] for i in s["tracks"] if i < len(a["tracks"]))
    return tot + P.S["gap_s"] * (len(d["segments"]) - 1)


def disc_problems(P, d):
    out = []
    for s in d["segments"]:
        a = P.album(s["album"])
        if not a:
            out.append("an album on this disc is no longer in the library")
        elif any(i >= len(a["tracks"]) for i in s["tracks"]):
            out.append(f"{a['title']}: its tracks changed since planning")
    if disc_duration(P, d) > P.budget():
        out.append(f"longer than {mmss(P.budget())}")
    return out


def disc_entries(P, d):
    """CD tracks of a disc, numbered; tracks under 4 s are merged into a neighbour (Red Book minimum)."""
    out = []
    for si, s in enumerate(d["segments"]):
        a = P.album(s["album"])
        if not a:
            continue
        groups = [[i] for i in s["tracks"] if i < len(a["tracks"])]
        i = 0
        while i < len(groups):
            if sum(a["tracks"][x]["duration"] for x in groups[i]) < MIN_TRACK_S and len(groups) > 1:
                if i + 1 < len(groups):
                    groups[i + 1] = groups[i] + groups[i + 1]
                else:
                    groups[i - 1] += groups[i]
                del groups[i]
                continue
            i += 1
        for g in groups:
            ts = [a["tracks"][x] for x in g]
            out.append({"seg": si, "album": a, "idx": g, "title": " / ".join(track_title(P, t) for t in ts),
                        "artist": ts[0]["artist"] if a.get("va") and ts[0]["artist"] else a["artist"],
                        "duration": sum(t["duration"] for t in ts)})
    for n, e in enumerate(out, 1):
        e["n"] = n
    return out


def disc_sig(P, d, legacy=False):
    """identifies the audio of a disc: same sig = the built image is still valid.
    Uses file names (not full paths), so renaming or moving a music folder keeps it."""
    S = P.S
    parts = []
    for s in d["segments"]:
        a = P.album(s["album"])
        if not a:
            return "missing"
        parts.append([[t["path"] if legacy else Path(t["path"]).name, t.get("cue_start"), t.get("cue_end"), t.get("size"), t.get("mtime")]
                      for t in (a["tracks"][i] for i in s["tracks"] if i < len(a["tracks"]))])
    marks = [[e["seg"], e["idx"][0]] for e in disc_entries(P, d)]
    blob = json.dumps([parts, marks, S["gap_s"], S["precision"], S["dither"], S["ceiling_db"], has_soxr()])
    return hashlib.sha1(blob.encode()).hexdigest()[:16]


def disc_name(P, d):
    names = []
    for s in d["segments"]:
        a = P.album(s["album"])
        if a:
            names.append(f"{a['artist']} – {a['title']}" + (f" ({s['part']})" if s["part"] else ""))
    return " + ".join(names) or "(empty)"


def disc_state(P, d):
    st, sig = d.get("status", {}), disc_sig(P, d)
    b = st.get("built")
    built = bool(b and b.get("sig") == sig and (Path(b.get("dir", "")) / "disc.wav").exists())
    stale = bool(b and not built)
    burned = bool(st.get("burned") and st["burned"].get("sig") == sig)
    verified = bool(st.get("verified") and st["verified"].get("sig") == sig)
    return {"built": built, "stale": stale, "burned": burned, "verified": verified, "sig": sig}


def state_badge(P, d):
    s = disc_state(P, d)
    out = []
    if s["verified"]:
        out.append(f"{CG}✔ verified{C0}")
    elif s["burned"]:
        out.append(f"{CG}● burned{C0}")
    if s["built"]:
        out.append(f"{CC}▣ built{C0}")
    elif s["stale"]:
        out.append(f"{CY}▣ outdated{C0}")
    return " ".join(out)


def find_disc(P, name):
    n = num(str(name).upper().replace("CD", ""))
    if n is None or not 1 <= n <= len(P.discs):
        raise SystemExit(f"no disc '{name}' (there are {len(P.discs)})")
    return n, P.discs[n - 1]


# ------------------------------------------------------------- audio build --
# ffmpeg messages about embedded cover art (broken/empty picture blocks) - the audio is unaffected
HARMLESS_FF = re.compile(r"attached picture|mimetype|cover art|Invalid PNG|image2", re.I)


def ffmpeg(args, stdout=None):
    r = subprocess.run([FFMPEG, "-hide_banner", "-nostdin", "-v", "error", "-y"] + args,
                       stdout=stdout, stderr=subprocess.PIPE)
    msgs = [x for x in r.stderr.decode("utf-8", "replace").splitlines() if x.strip() and not HARMLESS_FF.search(x)]
    if r.returncode:
        raise RuntimeError("ffmpeg failed: " + " | ".join(msgs[-5:]))
    for m in msgs:
        warn(f"ffmpeg: {m}")


def float_peak(path):
    peak = 0.0
    with open(path, "rb") as fh:
        while True:
            buf = fh.read(1 << 24)
            if not buf:
                break
            a = array.array("f")
            a.frombytes(buf[: len(buf) - len(buf) % 4])
            if len(a):
                peak = max(peak, max(a), -min(a))
    return peak


def wav_header(n_samples):
    data = n_samples * 4
    return (b"RIFF" + (36 + data).to_bytes(4, "little") + b"WAVEfmt " + (16).to_bytes(4, "little")
            + (1).to_bytes(2, "little") + (2).to_bytes(2, "little") + RATE.to_bytes(4, "little")
            + (RATE * 4).to_bytes(4, "little") + (4).to_bytes(2, "little") + (16).to_bytes(2, "little")
            + b"data" + data.to_bytes(4, "little"))


def _decode(t_path, start, end, kind, fh, channels=2):
    """decode [start,end) samples of a file and append to fh; returns samples written"""
    filters = []
    if start or end:
        filters.append(f"atrim=start_sample={start or 0}" + (f":end_sample={end}" if end else ""))
    if channels == 1:
        filters.append("pan=stereo|c0=c0|c1=c0")   # same signal on both sides, full level (-ac 2 would be -3 dB)
    af = ["-af", ",".join(filters)] if filters else []
    codec, fmt, width = ("pcm_s16le", "s16le", 4) if kind == "s16" else ("pcm_f32le", "f32le", 8)
    fh.flush()
    before = fh.seek(0, os.SEEK_END)
    extra = [] if kind == "s16" or channels == 1 else ["-ac", "2"]
    ffmpeg(["-i", t_path, "-map", "0:a:0", *af, *extra, "-c:a", codec, "-f", fmt, "-"], stdout=fh)
    return (fh.seek(0, os.SEEK_END) - before) // width


def _chunks(tracks):
    """group consecutive tracks of one CUE image into a single decode"""
    out = []
    for i, t in enumerate(tracks):
        c = out[-1] if out else None
        if (c and t.get("cue_start") is not None and c["path"] == t["path"] and c["end"] == t["cue_start"]):
            c["items"].append(i)
            c["end"] = t.get("cue_end")
        else:
            out.append({"path": t["path"], "start": t.get("cue_start"), "end": t.get("cue_end"), "items": [i]})
    return out


def build_segment(seg, S, tmp, log, si):
    tracks = seg["tracks"]
    runs = []
    for i, t in enumerate(tracks):
        key = (is_exact(t), t["rate"])
        if runs and runs[-1]["key"] == key:
            runs[-1]["items"].append(i)
        else:
            runs.append({"key": key, "items": [i]})
    starts = [0] * len(tracks)
    parts, pos, notes = [], 0, []
    for ri, run in enumerate(runs):
        exact, rate = run["key"]
        rtracks = [tracks[i] for i in run["items"]]
        path = tmp / f"s{si}r{ri}.{'s16' if exact else 'f32'}"
        in_pos = 0
        local = []
        with open(path, "wb") as fh:
            for ch in _chunks(rtracks):
                first = rtracks[ch["items"][0]]
                to_s = lambda fr: fr * rate // 75
                s0 = to_s(ch["start"]) if ch["start"] is not None else 0
                e0 = to_s(ch["end"]) if ch["end"] is not None else None
                for k in ch["items"]:
                    t = rtracks[k]
                    off = (to_s(t["cue_start"]) - s0) if t.get("cue_start") is not None else 0
                    local.append((run["items"][k], in_pos + off))
                names = ", ".join(rtracks[k]["title"] for k in ch["items"])
                log(f"    {'copy  ' if exact else 'decode'} {names[:70]}" + ("" if exact else f"  ({first['codec']} {first['bits'] or ''}/{rate})"))
                in_pos += _decode(ch["path"], s0, e0, "s16" if exact else "f32", fh, first["channels"])
        if exact:
            for i, p in local:
                starts[i] = pos + p
            pos += in_pos
            parts.append(("s16", path))
            continue
        out = path
        if rate != RATE:
            out = tmp / f"s{si}r{ri}.44k.f32"
            if has_soxr():
                rs = f"aresample={RATE}:resampler=soxr:precision={S['precision']}"
                log(f"    resample {rate} → {RATE} Hz (SoX VHQ)")
            else:
                rs = f"aresample={RATE}:filter_size=64:phase_shift=10:cutoff=0.97"
                log(f"    resample {rate} → {RATE} Hz (ffmpeg swr - install an ffmpeg with libsoxr for best quality)")
            ffmpeg(["-f", "f32le", "-ar", str(rate), "-ac", "2", "-i", str(path), "-af", rs, "-c:a", "pcm_f32le", "-f", "f32le", str(out)])
            path.unlink()
        n_out = out.stat().st_size // 8
        for i, p in local:
            starts[i] = pos + min(n_out, round(p * RATE / rate))
        pos += n_out
        parts.append(("f32", out))

    gain = 0.0
    f32 = [p for k, p in parts if k == "f32"]
    if f32:
        ceiling = 10 ** (S["ceiling_db"] / 20)
        peak = max(float_peak(p) for p in f32)
        if peak > ceiling:
            gain = 20 * math.log10(ceiling / peak)
        pk = f"{20 * math.log10(peak):+.2f} dBFS" if peak > 0 else "silence"
        notes.append(f"peak before 16-bit: {pk}" + (f" → constant gain {gain:+.2f} dB (no clipping)" if gain else " → level unchanged"))
    pcm = tmp / f"seg{si}.s16"
    with open(pcm, "wb") as fh:
        for kind, path in parts:
            fh.flush()
            if kind == "s16":
                with open(path, "rb") as src:
                    shutil.copyfileobj(src, fh, 1 << 24)
            else:
                af = (f"volume={gain:.4f}dB:precision=double," if gain else "") + f"aresample=osf=s16:dither_method={S['dither']}"
                ffmpeg(["-f", "f32le", "-ar", str(RATE), "-ac", "2", "-i", str(path), "-af", af,
                        "-c:a", "pcm_s16le", "-f", "s16le", "-"], stdout=fh)
                fh.seek(0, os.SEEK_END)
            path.unlink()
        total = fh.tell() // 4
        pad = (-total) % FRAME
        fh.write(b"\0" * pad * 4)
    return pcm, starts, total + pad, notes


def build_job(job):
    """worker: build disc.wav + layout for one disc. job is plain data (picklable)."""
    out = Path(job["dir"])
    tmp = out / "tmp"
    if out.exists():
        shutil.rmtree(out)
    tmp.mkdir(parents=True)
    tag = job["label"]

    def log(m):
        print(f"[{tag}] {m}", flush=True)

    segs, notes = [], []
    try:
        for si, seg in enumerate(job["segments"]):
            log(f"  {seg['artist']} – {seg['title']} {seg['part']}")
            pcm, starts, n, nt = build_segment(seg, job["S"], tmp, log, si)
            segs.append((seg, pcm, starts, n))
            notes.append({"album": f"{seg['artist']} – {seg['title']} {seg['part']}".strip(), "quality": seg["quality"], "notes": nt})
        total = sum(s[3] for s in segs)
        with open(out / "disc.wav", "wb") as fh:
            fh.write(wav_header(total))
            for _, pcm, _, _ in segs:
                with open(pcm, "rb") as src:
                    shutil.copyfileobj(src, fh, 1 << 24)
                pcm.unlink()
        shutil.rmtree(tmp)
        layout_segments, tracks, offset = [], [], 0
        for si, (seg, _, starts, n) in enumerate(segs):
            layout_segments.append({"start_sample": offset, "samples": n, "pregap_s": job["gap"] if si else 0})
            marks = seg["marks"]
            frames = [(offset + starts[m]) // FRAME for m in marks]
            frames[0] = offset // FRAME
            end_f = (offset + n) // FRAME
            for k, f in enumerate(frames):
                e = frames[k + 1] if k + 1 < len(frames) else end_f
                tracks.append({"start": f, "length": e - f, "pregap": job["gap"] * 75 if (si and k == 0) else 0})
            offset += n
        layout = {"sig": job["sig"], "samples": total, "segments": layout_segments, "tracks": tracks, "notes": notes,
                  "built": now_iso()}
        write_json(out / "disc.json", layout)
        log(f"done → {tildify(out)}")
        return job["uid"], layout
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


def make_job(P, n, d):
    entries = disc_entries(P, d)
    segs = []
    for si, s in enumerate(d["segments"]):
        a = P.album(s["album"])
        ts = []
        for i in s["tracks"]:
            t = dict(a["tracks"][i])
            t["title"] = track_title(P, t)
            ts.append(t)
        pos_of = {i: k for k, i in enumerate(s["tracks"])}
        marks = [pos_of[e["idx"][0]] for e in entries if e["seg"] == si]
        segs.append({"artist": a["artist"], "title": a["title"], "part": s["part"], "quality": quality_label(ts),
                     "tracks": ts, "marks": marks})
    dirname = f"CD{n:02d}_{slug(disc_name(P, d))}"
    return {"uid": d["uid"], "label": f"CD{n:02d}", "dir": str(P.build_dir / dirname), "segments": segs,
            "S": dict(P.S), "gap": P.S["gap_s"], "sig": disc_sig(P, d)}


def cdtext(s):
    s = (s or "").replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"').replace("–", "-").replace("—", "-")
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return s.replace("\\", "\\\\").replace('"', '\\"')


def write_toc(P, n, d, bdir):
    """(re)write disc.toc + disc.cue from the built layout and the current names"""
    layout = json.loads((bdir / "disc.json").read_text(encoding="utf-8"))
    entries = disc_entries(P, d)
    if len(entries) != len(layout["tracks"]):
        raise RuntimeError("the built image does not match the plan any more - build it again")
    used = 150 + sum(t["length"] + t["pregap"] for t in layout["tracks"])
    if used > P.max_frames():
        raise RuntimeError(f"{msf(used)} does not fit on a {P.S['capacity_min']}-minute CD")
    albums = [P.album(s["album"]) for s in d["segments"]]
    dtitle = " / ".join(a["title"] + (f" ({s['part'].split(' · ')[0]})" if s["part"] else "") for a, s in zip(albums, d["segments"]))
    dperf = " / ".join(dict.fromkeys(a["artist"] for a in albums))
    use_text = P.S["cdtext"]
    tb = sum(len(cdtext(e["title"])) + 1 for e in entries) + len(cdtext(dtitle))
    pb = sum(len(cdtext(e["artist"])) + 1 for e in entries) + len(cdtext(dperf))
    track_perf = math.ceil(tb / 12) + math.ceil(pb / 12) + 3 <= 250
    toc = ["CD_DA", ""]
    if use_text:
        toc += ["CD_TEXT {", "  LANGUAGE_MAP {", "    0 : EN", "  }", "  LANGUAGE 0 {",
                f'    TITLE "{cdtext(dtitle)}"', f'    PERFORMER "{cdtext(dperf)}"', "  }", "}", ""]
    q = lambda s: (s or "").replace('"', "'")
    cue = [f'PERFORMER "{q(dperf)}"', f'TITLE "{q(dtitle)}"', 'FILE "disc.wav" WAVE']
    for e, t in zip(entries, layout["tracks"]):
        toc += [f"// Track {e['n']}", "TRACK AUDIO"]
        if use_text:
            toc += ["CD_TEXT {", "  LANGUAGE 0 {", f'    TITLE "{cdtext(e["title"])}"']
            if track_perf:
                toc.append(f'    PERFORMER "{cdtext(e["artist"])}"')
            toc += ["  }", "}"]
        if t["pregap"]:
            toc.append(f"PREGAP {msf(t['pregap'])}")
        toc += [f'FILE "disc.wav" {msf(t["start"])} {msf(t["length"])}', ""]
        cue += [f"  TRACK {e['n']:02d} AUDIO"]
        if use_text:
            cue += [f'    TITLE "{q(e["title"])}"', f'    PERFORMER "{q(e["artist"])}"']
        if t["pregap"]:
            cue.append(f"    PREGAP {msf(t['pregap'])}")
        cue.append(f"    INDEX 01 {msf(t['start'])}")
    (bdir / "disc.toc").write_text("\n".join(toc) + "\n", encoding="utf-8")
    (bdir / "disc.cue").write_text("\n".join(cue) + "\n", encoding="utf-8")
    lines = [f"CD{n:02d}  {msf(used)}  ({len(entries)} tracks)"]
    for nt in layout.get("notes", []):
        lines.append(f"  {nt['album']}  [{nt['quality']}]")
        lines += [f"      {x}" for x in nt["notes"]]
    for e in entries:
        lines.append(f"  {e['n']:2d}. {e['title']}  {mmss(e['duration'])}")
    (bdir / "info.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return used


def build_discs(P, which, jobs=None):
    """which: list of (n, disc). Builds in parallel, updates status."""
    need_ffmpeg()
    bad = [(n, p) for n, d in which for p in disc_problems(P, d)]
    for n, p in bad:
        err(f"CD{n:02d}: {p}")
    if bad:
        return False
    need = sum(disc_duration(P, d) for _, d in which) * RATE * 4 * 1.6
    P.build_dir.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(P.build_dir).free
    if need > free:
        err(f"Not enough disk space in {tildify(P.build_dir)}: need ~{hsize(need)}, free {hsize(free)}.")
        return False
    jobs = max(1, int(jobs or P.S["jobs"]))
    js = [make_job(P, n, d) for n, d in which]
    by_uid = {d["uid"]: (n, d) for n, d in which}
    for j in js:
        d = by_uid[j["uid"]][1]
        oldb = d.get("status", {}).get("built")
        if oldb and oldb.get("dir") and oldb["dir"] != j["dir"] and Path(oldb["dir"]).is_dir():
            shutil.rmtree(oldb["dir"], ignore_errors=True)
    t0, okc = time.time(), 0
    results = []
    if jobs == 1 or len(js) == 1:
        for j in js:
            try:
                results.append((j, build_job(j)))
            except Exception as e:
                err(f"{j['label']}: {e}")
    else:
        with ProcessPoolExecutor(min(jobs, len(js))) as ex:
            futs = {ex.submit(build_job, j): j for j in js}
            for fu in as_completed(futs):
                j = futs[fu]
                try:
                    results.append((j, fu.result()))
                except Exception as e:
                    err(f"{j['label']}: {e}")
    for j, (uid, layout) in results:
        n, d = by_uid[uid]
        d.setdefault("status", {})["built"] = {"sig": j["sig"], "dir": j["dir"], "at": now_iso()}
        try:
            used = write_toc(P, n, d, Path(j["dir"]))
            okc += 1
            for nt in layout["notes"]:
                if nt["notes"]:
                    info(f"CD{n:02d} {nt['album']}: {'; '.join(nt['notes'])}")
            ok(f"CD{n:02d} ready ({msf(used)})")
        except Exception as e:
            err(f"CD{n:02d}: {e}")
    P.save()
    say(f"\n{okc}/{len(js)} disc(s) built in {time.time() - t0:.0f} s.")
    return okc == len(js)


# --------------------------------------------------------------- burning ---
def list_drives():
    out = []
    if WINDOWS:
        try:
            r = subprocess.run(["powershell", "-NoProfile", "-Command",
                                "Get-CimInstance Win32_CDROMDrive | ForEach-Object { $_.Drive + '|' + $_.Caption }"],
                               capture_output=True, text=True, timeout=20)
            for line in r.stdout.splitlines():
                if "|" in line:
                    dv, cap = line.split("|", 1)
                    out.append((dv.strip(), cap.strip()))
        except Exception:
            pass
    else:
        for dev in sorted(Path("/dev").glob("sr[0-9]*")):
            sysd = Path("/sys/block") / dev.name / "device"
            name = " ".join(x for x in ((sysd / f).read_text().strip() if (sysd / f).exists() else "" for f in ("vendor", "model")) if x)
            out.append((str(dev), name or "optical drive"))
    return out


def current_device():
    if CFG.get("device"):
        return CFG["device"]
    drives = list_drives()
    return drives[0][0] if drives else ("D:" if WINDOWS else "/dev/sr0")


def find_imgburn():
    cands = [CFG.get("imgburn") or "", shutil.which("ImgBurn") or ""]
    for env in ("ProgramFiles(x86)", "ProgramFiles"):
        if os.environ.get(env):
            cands.append(str(Path(os.environ[env]) / "ImgBurn" / "ImgBurn.exe"))
    return next((c for c in cands if c and Path(c).exists()), "")


def engine():
    e = CFG.get("engine", "auto")
    if e == "cdrdao" or (e == "auto" and have("cdrdao")):
        return "cdrdao" if have("cdrdao") else ""
    if e == "imgburn" or (e == "auto" and WINDOWS):
        return "imgburn" if find_imgburn() else ""
    return ""


def burn_disc(P, n, d, simulate=False, speed=None, device=None, assume_yes=False):
    st = disc_state(P, d)
    if not st["built"]:
        err(f"CD{n:02d} has no up-to-date image yet - build it first.")
        return False
    bdir = Path(d["status"]["built"]["dir"])
    try:
        write_toc(P, n, d, bdir)
    except Exception as e:
        err(str(e))
        return False
    eng = engine()
    device = device or current_device()
    speed = int(speed or CFG.get("speed", 16))
    if not eng:
        err("No burning program found.")
        say("  Install:  " + (install_hint("imgburn") if WINDOWS else install_hint("cdrdao")))
        if WINDOWS:
            say(f"  Or open {bdir / 'disc.cue'} in any burner that supports CUE + Disc-At-Once.")
        return False
    say(f" {CB}CD{n:02d}{C0}  {disc_name(P, d)}")
    say(f" {CD}{tildify(bdir)}{C0}")
    say(f" {'Simulate (laser off)' if simulate else 'Burn'} with {eng} on {device} at {speed}x, Disc-At-Once\n")
    if eng == "cdrdao":
        r = subprocess.run(["cdrdao", "show-toc", "disc.toc"], cwd=bdir, capture_output=True, text=True)
        if r.returncode:
            err("cdrdao rejected the TOC:\n" + (r.stderr or r.stdout)[-2000:])
            return False
        r = subprocess.run(["cdrdao", "disk-info", "--device", device], capture_output=True, text=True)
        txt = r.stdout + r.stderr
        m = re.search(r"CD-R empty\s*:\s*(\w+)", txt)
        if m and m.group(1).lower() == "no" and not simulate:
            err("The disc in the drive is not blank.")
            return False
        if "Unit not ready" in txt or "no disk" in txt.lower() or (r.returncode and not m):
            warn("No disc detected in the drive (insert a blank CD-R).")
        if TTY and not assume_yes and not yesno(" Start?", "y"):
            return False
        cmd = ["cdrdao", "simulate" if simulate else "write", "--device", device, "--speed", str(speed),
               "--buffers", "256", "-n", "--eject"]
        if CFG.get("driver"):
            cmd += ["--driver", CFG["driver"]]
        cmd.append("disc.toc")
        say(CD + " ".join(cmd) + C0)
        rc = subprocess.run(cmd, cwd=bdir).returncode
    else:
        exe = find_imgburn()
        if TTY and not assume_yes and not yesno(" Insert a blank CD-R. Start?", "y"):
            return False
        cmd = [exe, "/MODE", "WRITE", "/SRC", str(bdir / "disc.cue"), "/DEST", device, "/SPEED", f"{speed}x",
               "/TESTMODE", "YES" if simulate else "NO", "/VERIFY", "NO", "/EJECT", "YES", "/START", "/CLOSESUCCESS",
               "/NOIMAGEDETAILS", "/WAITFORMEDIA"]
        say(CD + " ".join(cmd) + C0)
        rc = subprocess.run(cmd).returncode
    if rc:
        err(f"Burning failed (exit code {rc}). See the messages above.")
        return False
    if simulate:
        ok("Simulation OK - the drive accepted the disc layout. Now burn for real.")
        return True
    b = d["status"].get("burned") or {}
    d["status"]["burned"] = {"sig": st["sig"], "at": now_iso(), "count": (b.get("count", 0) + 1) if b.get("sig") == st["sig"] else 1}
    P.save()
    ok(f"CD{n:02d} burned.")
    return True


# ----------------------------------------------------------- verification --
def wav_data(path):
    with open(path, "rb") as f:
        head = f.read(12)
        if head[:4] != b"RIFF" or head[8:12] != b"WAVE":
            raise RuntimeError(f"{path} is not a WAV file")
        pos = 12
        while True:
            f.seek(pos)
            h = f.read(8)
            if len(h) < 8:
                raise RuntimeError(f"no audio data in {path}")
            size = int.from_bytes(h[4:], "little")
            if h[:4] == b"data":
                return pos + 8, min(size, Path(path).stat().st_size - pos - 8)
            pos += 8 + size + (size & 1)


def compare_rip(image, layout, rip):
    """compare a rip of tracks 1..end with the image; returns (offset, compared, mismatches, unchecked)"""
    e_off, _ = wav_data(image)
    r_off, r_len = wav_data(rip)
    with open(image, "rb") as fe, open(rip, "rb") as fr:
        E = mmap.mmap(fe.fileno(), 0, access=mmap.ACCESS_READ)
        R = mmap.mmap(fr.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            r_n = r_len // 4
            pieces, pos = [], 0
            for s in layout["segments"]:
                if s["pregap_s"]:
                    pieces.append((pos, s["pregap_s"] * RATE, None))
                    pos += s["pregap_s"] * RATE
                pieces.append((pos, s["samples"], s["start_sample"]))
                pos += s["samples"]
            exp_n = pos

            def exp_bytes(p, n):
                out = bytearray()
                for start, length, src in pieces:
                    lo, hi = max(p, start), min(p + n, start + length)
                    if lo < hi:
                        if src is None:
                            out += bytes((hi - lo) * 4)
                        else:
                            b = e_off + (src + lo - start) * 4
                            out += E[b:b + (hi - lo) * 4]
                return bytes(out)

            offset = None
            for start, length, src in pieces:
                if src is None:
                    continue
                for frac in (0.3, 0.5, 0.7, 0.1):
                    anchor = start + int(length * frac)
                    needle = exp_bytes(anchor, 8192)
                    if needle.count(0) > len(needle) * 0.9:
                        continue
                    lo, hi = max(0, anchor - 30000), min(r_n, anchor + 30000 + 8192)
                    hay = R[r_off + lo * 4: r_off + hi * 4]
                    i = hay.find(needle)
                    while i != -1 and i % 4:
                        i = hay.find(needle, i + 1)
                    if i != -1:
                        offset = lo + i // 4 - anchor
                        break
                if offset is not None:
                    break
            if offset is None:
                return None, 0, 0, exp_n
            start, end, bad, CH = max(0, -offset), min(exp_n, r_n - offset), 0, 1 << 20
            for p in range(start, end, CH):
                n = min(CH, end - p)
                e = exp_bytes(p, n)
                r = R[r_off + (p + offset) * 4: r_off + (p + offset + n) * 4]
                if e != r:
                    bad += sum(1 for x, y in zip(array.array("I", e), array.array("I", r)) if x != y)
            return offset, end - start, bad, exp_n - (end - start)
        finally:
            E.close()
            R.close()


def verify_disc(P, n, d, readback=None, device=None):
    st = disc_state(P, d)
    if not st["built"]:
        err(f"CD{n:02d}: the image to compare with is missing or outdated (build it again first).")
        return False
    bdir = Path(d["status"]["built"]["dir"])
    layout = json.loads((bdir / "disc.json").read_text(encoding="utf-8"))
    rip = Path(readback) if readback else bdir / "readback.wav"
    if not readback:
        if not have("cdparanoia"):
            err("cdparanoia is needed to read the disc back.")
            say("  Install:  " + install_hint("cdparanoia"))
            if WINDOWS:
                say("  On Windows: rip the whole disc as one WAV (e.g. EAC 'Copy Image') and give that file instead.")
            return False
        device = device or current_device()
        info(f"Reading the disc in {device} with cdparanoia (secure mode, stops on unreadable sectors)…")
        r = subprocess.run(["cdparanoia", "-d", device, "-X", "-w", "1-", str(rip)])
        if r.returncode:
            err("cdparanoia could not read the disc cleanly. Clean it and retry, or re-burn at a lower speed.")
            rip.unlink(missing_ok=True)
            return False
    info("Comparing every sample with the image…")
    try:
        off, cmp_n, bad, skipped = compare_rip(bdir / "disc.wav", layout, rip)
    finally:
        if not readback:
            rip.unlink(missing_ok=True)
    if off is None:
        err("The rip does not match this image at all (another disc in the drive?).")
        return False
    say(f"  drive offset {off:+d} samples · compared {cmp_n / RATE / 60:.1f} min · not readable at the disc edges: {skipped} samples")
    if bad:
        err(f"{bad:,} samples differ. Try reading it again; if it persists, re-burn at a lower speed.")
        return False
    d["status"]["verified"] = {"sig": st["sig"], "at": now_iso()}
    P.save()
    ok(f"CD{n:02d} is bit-identical to the prepared image.")
    return True


# ------------------------------------------------------------------ labels --
def label_data(P):
    out, total = [], len(P.discs)
    for n, d in enumerate(P.discs, 1):
        entries = disc_entries(P, d)
        albums = []
        for si, s in enumerate(d["segments"]):
            a = P.album(s["album"])
            if not a:
                continue
            es = [e for e in entries if e["seg"] == si]
            ts = [a["tracks"][i] for i in s["tracks"] if i < len(a["tracks"])]
            albums.append({"artist": a["artist"], "title": a["title"], "year": a["year"], "part": s["part"],
                           "quality": quality_label(ts) if ts else "",
                           "tracks": [{"n": e["n"], "title": (f"{e['artist']} – " if a.get("va") else "") + e["title"],
                                       "dur": mmss(e["duration"])} for e in es]})
        out.append({"id": f"CD{n:02d}", "number": n, "total": total, "duration": mmss(disc_duration(P, d)), "albums": albums})
    return out


def write_labels(P):
    html = LABEL_TEMPLATE.replace("/*__DISCS__*/[]", json.dumps(label_data(P), ensure_ascii=False))
    html = html.replace("<title>CD Labels</title>", f"<title>CD Labels · {P.dir.parent.name}</title>")
    f = P.dir / "labels.html"
    f.write_text(html, encoding="utf-8")
    lines = []
    for n, d in enumerate(P.discs, 1):
        lines.append(f"CD{n:02d}  ({mmss(disc_duration(P, d))})")
        entries = disc_entries(P, d)
        for si, s in enumerate(d["segments"]):
            a = P.album(s["album"])
            if not a:
                continue
            ts = [a["tracks"][i] for i in s["tracks"] if i < len(a["tracks"])]
            lines.append(f"   {a['artist']} – {a['title']}" + (f" ({a['year']})" if a.get("year") else "") + (f" – {s['part']}" if s["part"] else "")
                         + f"   [{quality_label(ts)}]")
            for e in entries:
                if e["seg"] == si:
                    lines.append(f"      {e['n']:2d}. {e['title']}  {mmss(e['duration'])}")
        lines.append("")
    (P.dir / "tracklists.txt").write_text("\n".join(lines), encoding="utf-8")
    return f


# --------------------------------------------------------------------- TUI --
def term_size():
    s = shutil.get_terminal_size((80, 24))
    return s.lines, s.columns


def vlen(s): return len(ANSI.sub("", s))


def clip(s, w):
    if vlen(s) <= w:
        return s
    out, n, i = [], 0, 0
    while i < len(s) and n < w - 1:
        m = ANSI.match(s, i)
        if m:
            out.append(m.group())
            i = m.end()
            continue
        out.append(s[i])
        n += 1
        i += 1
    return "".join(out) + "…" + C0


def pad(s, w):
    s = clip(s, w)
    return s + " " * max(0, w - vlen(s))


def cls():
    if TTY:
        sys.stdout.write("\x1b[H\x1b[2J\x1b[3J")
        sys.stdout.flush()


def cursor(on):
    if TTY:
        sys.stdout.write("\x1b[?25h" if on else "\x1b[?25l")
        sys.stdout.flush()


def frame(text):
    h, w = term_size()
    lines = [clip(x, w - 1) for x in text.split("\n")][: h - 1]
    sys.stdout.write("\x1b[H" + "\x1b[K\n".join(lines) + "\x1b[K\x1b[J")
    sys.stdout.flush()


def read_key():
    if WINDOWS:
        ch = msvcrt.getwch()
        if ch in ("\x00", "\xe0"):
            c = msvcrt.getwch()
            return {"H": "k", "P": "j", "K": "h", "M": "l", "G": "g", "O": "G", "I": "pgup", "Q": "pgdn"}.get(c, "none")
        if ch == "\x03":
            raise KeyboardInterrupt
        return {"\r": "enter", "\n": "enter", " ": "space", "\t": "tab", "\x08": "bs", "\x1b": "esc",
                "\x04": "pgdn", "\x15": "pgup"}.get(ch, ch)
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        b = os.read(fd, 1)
        if b == b"\x1b":
            if not select.select([fd], [], [], 0.04)[0]:
                return "esc"
            b2 = os.read(fd, 1)
            if b2 not in (b"[", b"O"):
                return "esc"
            b3 = os.read(fd, 1)
            m = {b"A": "k", b"B": "j", b"C": "l", b"D": "h", b"H": "g", b"F": "G", b"Z": "btab"}
            if b3 in m:
                return m[b3]
            if b3.isdigit():
                seq = b3
                while True:
                    c = os.read(fd, 1)
                    if not c.isdigit():
                        break
                    seq += c
                return {b"5": "pgup", b"6": "pgdn", b"1": "g", b"7": "g", b"4": "G", b"8": "G", b"3": "del"}.get(seq, "none")
            return "none"
        if b and b[0] >= 0xC0:
            b += os.read(fd, 1 if b[0] < 0xE0 else 2 if b[0] < 0xF0 else 3)
        ch = b.decode("utf-8", "replace")
        return {"\n": "enter", "\r": "enter", " ": "space", "\t": "tab", "\x7f": "bs", "\x08": "bs",
                "\x04": "pgdn", "\x15": "pgup"}.get(ch, ch)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def pause():
    sys.stdout.write(f"\n{CD}press any key…{C0}")
    sys.stdout.flush()
    read_key()


def yesno(q, default="n"):
    hint = "[Y/n]" if default == "y" else "[y/N]"
    sys.stdout.write(f"{q} {CD}{hint}{C0} ")
    sys.stdout.flush()
    if not TTY:
        say(default)
        return default == "y"
    while True:
        k = read_key()
        if k in ("y", "Y"):
            say("y")
            return True
        if k in ("n", "N", "q", "esc"):
            say("n")
            return False
        if k == "enter":
            say(default)
            return default == "y"


def _path_completer(text, state):
    import glob
    t = os.path.expanduser(text)
    m = [x + (os.sep if os.path.isdir(x) else "") for x in glob.glob(glob.escape(t) + "*")]
    return m[state] if state < len(m) else None


def ask(prompt, default="", path=False):
    cursor(True)
    try:
        if not WINDOWS:
            try:
                import readline
                readline.set_startup_hook(lambda: readline.insert_text(str(default)))
                if path:
                    readline.set_completer_delims("\t\n")
                    readline.set_completer(_path_completer)
                    readline.parse_and_bind("tab: complete")
                try:
                    return input(prompt).strip()
                finally:
                    readline.set_startup_hook(None)
                    readline.set_completer(None)
            except ImportError:
                pass
        v = input(f"{prompt}{f'[{default}] ' if default != '' else ''}").strip()
        return v if v else str(default)
    except (EOFError, KeyboardInterrupt):
        say()
        return None
    finally:
        cursor(False)


MENU_POS = {}


def run_menu(header, items, key="menu"):
    """items: (key, label, description). returns the chosen key or 'q'."""
    i = MENU_POS.get(key, 0)
    i = i if i < len(items) else 0
    cursor(False)
    while True:
        h = header() if callable(header) else header
        buf = h + "\n"
        for j, (k, label, desc) in enumerate(items):
            if j == i:
                buf += f" {CC}{CB}› {k:<2} {label:<13}{C0} {desc}\n"
            else:
                buf += f"   {CC}{k:<2}{C0} {label:<13} {CD}{desc}{C0}\n"
        buf += f"\n {CD}j/k move · enter select · shortcut key · q back{C0}"
        frame(buf)
        k = read_key()
        if k == "j":
            i = (i + 1) % len(items)
        elif k == "k":
            i = (i - 1) % len(items)
        elif k == "g":
            i = 0
        elif k == "G":
            i = len(items) - 1
        elif k in ("enter", "l"):
            MENU_POS[key] = i
            return items[i][0]
        elif k in ("q", "esc", "h", "bs"):
            return "q"
        else:
            for j, it in enumerate(items):
                if k == it[0]:
                    MENU_POS[key] = j
                    return k


def list_view(header, rows, pos=0, footer="", keys=(), multi=None):
    """scrollable list. rows: formatted strings. multi: set of selected indices (space toggles, a = all/none).
    returns (key, index); key is 'enter', 'q' or one of `keys`."""
    top = 0
    cursor(False)
    while True:
        h, w = term_size()
        head = header() if callable(header) else header
        hl = head.count("\n") + 1
        vis = max(3, h - hl - 3)
        n = len(rows)
        pos = max(0, min(pos, n - 1)) if n else 0
        if pos < top:
            top = pos
        if pos >= top + vis:
            top = pos - vis + 1
        buf = head + "\n"
        for i in range(top, min(n, top + vis)):
            mark = ""
            if multi is not None:
                mark = f"{CG}[x]{C0} " if i in multi else f"{CD}[ ]{C0} "
            if i == pos:
                buf += f" {CC}{CB}›{C0} {mark}{rows[i]}\n"
            else:
                buf += f"   {mark}{rows[i]}\n"
        if not n:
            buf += f"   {CD}(empty){C0}\n"
        more = f"{top + 1}-{min(n, top + vis)}/{n}" if n > vis else ""
        base = "j/k move · " + ("space select · a all/none · " if multi is not None else "")
        buf += f"\n {CD}{more + '  ' if more else ''}{base}{footer + ' · ' if footer else ''}q back{C0}"
        frame(buf)
        k = read_key()
        if k == "j" and n:
            pos = (pos + 1) % n
        elif k == "k" and n:
            pos = (pos - 1) % n
        elif k == "g":
            pos = 0
        elif k == "G":
            pos = max(0, n - 1)
        elif k == "pgdn":
            pos = min(n - 1, pos + vis // 2)
        elif k == "pgup":
            pos = max(0, pos - vis // 2)
        elif k in ("q", "esc", "h", "bs"):
            return "q", pos
        elif multi is not None and k == "space" and "space" not in keys and n:
            multi.symmetric_difference_update({pos})
            pos = min(n - 1, pos + 1)
        elif multi is not None and k == "a" and "a" not in keys:
            if len(multi) == n:
                multi.clear()
            else:
                multi.update(range(n))
        elif k in ("enter", "l"):
            return "enter", pos
        elif k in keys:
            return k, pos


def pager(title, lines):
    top = 0
    cursor(False)
    while True:
        h, w = term_size()
        vis = max(1, h - 3)
        n = len(lines)
        top = max(0, min(top, n - vis))
        buf = f" {CB}{title}{C0}  {CD}{(top + 1) if n else 0}-{min(n, top + vis)}/{n}{C0}\n"
        for i in range(top, min(n, top + vis)):
            buf += " " + lines[i] + "\n"
        buf += f" {CD}j/k scroll · ctrl-d/u page · g/G top/bottom · q back{C0}"
        frame(buf)
        k = read_key()
        if k == "j":
            top += 1
        elif k == "k":
            top -= 1
        elif k in ("pgdn", "space"):
            top += vis // 2
        elif k == "pgup":
            top -= vis // 2
        elif k == "g":
            top = 0
        elif k == "G":
            top = n
        elif k in ("q", "esc", "h", "enter"):
            return


def choose(title, options, current=None):
    """pick one value from [(value, label)]"""
    pos = next((i for i, (v, _) in enumerate(options) if v == current), 0)
    rows = [(f"{CG}●{C0} " if v == current else "  ") + lab for v, lab in options]
    k, i = list_view(f" {CB}{title}{C0}\n", rows, pos=pos, footer="enter choose")
    return options[i][0] if k == "enter" else None


# --------------------------------------------------------------- the menus --
P = None


def bar(sec, budget, w=12):
    f = max(0.0, min(1.0, sec / budget)) * w
    full = int(f)
    part = " ▏▎▍▌▋▊▉"[int((f - full) * 8)].strip() if full < w else ""
    col = CR if sec > budget else CG if sec > budget * 0.75 else CC
    return col + "█" * full + part + C0 + CD + "·" * (w - full - (1 if part else 0)) + C0


def main_hdr():
    s = [f" {CB}{CC}cdburn{C0} {CD}v{VERSION} · music folders → gapless Audio CDs{C0}", ""]
    if P:
        inc = [a for a in P.albums if a.get("include")]
        st = [disc_state(P, d) for d in P.discs]
        s.append(f" {'Project':<8} {tildify(P.dir)}")
        s.append(f" {'Music':<8} {', '.join(tildify(x) for x in P.sources) or '-'}")
        s.append(f" {'Albums':<8} {len(inc)} included of {len(P.albums)} found")
        line = (f" {'Discs':<8} {len(P.discs)} planned · {sum(x['built'] for x in st)} built · "
                f"{sum(x['burned'] for x in st)} burned · {sum(x['verified'] for x in st)} verified")
        if plan_stale(P):
            line += f"   {CY}plan out of date → Plan › r{C0}"
        s.append(line)
    eng = engine() or f"{CR}none installed{C0}"
    s.append(f" {'Burner':<8} {current_device()} · {CFG.get('speed', 16)}x · {eng}")
    return "\n".join(s) + "\n"


def need_project():
    if not P:
        err("No project open.")
        pause()
        return False
    return True


def first_run():
    global P
    cls()
    cursor(True)
    say(f"\n {CB}{CC}cdburn{C0} - burn folders of music to gapless, bit-perfect Audio CDs (with printable labels)\n")
    say(" A project is a set of music folders plus the CD plan, the burn-ready images and the labels.")
    default = Path.cwd() if any(Path.cwd().glob("*/*.flac")) or any(Path.cwd().glob("*.flac")) else Path.home() / "Music"
    srcs = []
    while True:
        v = ask(" Music folder (Tab completes, empty = done): " if srcs else " Music folder (Tab completes): ",
                "" if srcs else tildify(default), path=True)
        if v is None:
            return False
        if not v:
            if srcs:
                break
            continue
        p = Path(os.path.expanduser(v)).resolve()
        if not p.is_dir():
            err(f"{p} is not a folder")
            continue
        srcs.append(str(p))
        if not yesno(" Add another music folder?", "n"):
            break
    pdir = ask(" Project folder (plan, images, labels): ", tildify(Path(srcs[0]) / "_CD_Burning"), path=True)
    if not pdir:
        return False
    return open_or_create(Path(os.path.expanduser(pdir)), srcs)


def open_or_create(pdir, srcs=None):
    global P
    pdir = pdir.resolve()
    if (pdir / PROJECT_FILE).exists():
        P = Project.load(pdir)
        for s in srcs or []:
            if s not in P.sources:
                P.sources.append(s)
        info(f"Opened existing project {tildify(pdir)}")
    else:
        P = Project(pdir)
        P.data["sources"] = list(srcs or [])
        P.save()
        ok(f"Created project {tildify(pdir)}")
    remember_project(pdir)
    if srcs:
        do_scan()
    return True


def do_scan():
    cls()
    say(f" {CB}Scanning{C0} {', '.join(tildify(s) for s in P.sources)}")

    def prog(i, n):
        sys.stdout.write(f"\r   reading tags {i}/{n}")
        sys.stdout.flush()
    before = {a["id"] for a in P.albums}
    albums = scan_project(P, prog)
    say("")
    new = [a for a in albums if a["id"] not in before]
    dups = [a for a in albums if a.get("dup_of")]
    ok(f"{len(albums)} albums found ({len(new)} new), {sum(len(a['tracks']) for a in albums)} tracks.")
    for a in dups:
        b = P.album(a["dup_of"])
        if b:
            info(f"Duplicate: kept {quality_label(b['tracks'])} '{b['title']}', skipped {quality_label(a['tracks'])} copy in {tildify(a['folder'])}")
    if not P.discs:
        try:
            auto_plan(P)
            ok(f"Planned {len(P.discs)} CDs.")
        except ValueError as e:
            err(str(e))
    else:
        # never touch an existing plan here: its CDs may be burned and their labels printed
        broken = [n for n, d in enumerate(P.discs, 1) if disc_problems(P, d)]
        if broken:
            warn("Albums on " + ", ".join(f"CD{n:02d}" for n in broken) + " changed or are missing - see Plan.")
        elif plan_stale(P):
            info("Your plan is unchanged. (Albums or settings differ from when it was made; re-plan only if you want to.)")
    pause()


# ---- sources / projects
def sources_menu():
    pos = 0
    while True:
        rows = [tildify(s) + ("" if Path(s).is_dir() else f"  {CR}(missing){C0}") for s in P.sources]
        hdr = f" {CB}Music folders{C0}  {CD}every album below these folders is found automatically{C0}\n"
        k, pos = list_view(hdr, rows, pos, footer="a add · d remove · r rescan", keys=("a", "d", "r", "enter"))
        if k == "q":
            return
        if k == "a":
            cls()
            v = ask(" Add music folder: ", tildify(Path(P.sources[0]).parent if P.sources else Path.home()), path=True)
            if v:
                p = str(Path(os.path.expanduser(v)).resolve())
                if Path(p).is_dir() and p not in P.sources:
                    P.sources.append(p)
                    P.save()
                    do_scan()
        elif k == "d" and P.sources:
            cls()
            if yesno(f" Remove {tildify(P.sources[pos])} from this project? (files are not touched)", "n"):
                P.sources.pop(pos)
                P.save()
                do_scan()
        elif k in ("r", "enter"):
            do_scan()


def projects_menu():
    global P
    while True:
        rec = [r for r in CFG.get("recent", []) if (Path(r) / PROJECT_FILE).exists()]
        rows = [(f"{CG}●{C0} " if P and str(P.dir) == r else "  ") + tildify(r) for r in rec]
        k, pos = list_view(f" {CB}Projects{C0}  {CD}enter opens{C0}\n", rows, footer="n new · o open folder · x forget",
                           keys=("n", "o", "x"))
        if k == "q":
            return
        if k == "enter" and rec:
            P = Project.load(rec[pos])
            remember_project(rec[pos])
            return
        if k == "n":
            if first_run():
                return
        if k == "o":
            cls()
            v = ask(" Project folder: ", "", path=True)
            if v and (Path(os.path.expanduser(v)) / PROJECT_FILE).exists():
                P = Project.load(Path(os.path.expanduser(v)))
                remember_project(P.dir)
                return
            if v:
                err("No cdburn project there.")
                pause()
        if k == "x" and rec:
            CFG["recent"] = [r for r in CFG["recent"] if r != rec[pos]]
            save_cfg()


# ---- albums
def album_row(a, w):
    inc = f"{CG}✔{C0}" if a.get("include") else f"{CD}·{C0}"
    q = quality_label([a["tracks"][i] for i in inc_tracks(a)] or a["tracks"])
    qcol = CY if "lossy" in q else CD
    n_inc, n_all = len(inc_tracks(a)), len(a["tracks"])
    trk = f"{n_inc}/{n_all}" if n_inc != n_all else f"{n_all}"
    name = f"{a['artist']} – {a['title']}" + (f" ({a['year']})" if a.get("year") else "")
    dup = f"  {CY}duplicate{C0}" if a.get("dup_of") else ""
    parts = f" {CD}[{len(a['parts'])} discs]{C0}" if len([x for x in a["parts"] if x]) > 1 else ""
    left = max(20, w - 46)
    return f"{inc} {pad(name, left)} {mmss(album_duration(a)):>6} {trk:>6} trk  {qcol}{q}{C0}{parts}{dup}"


def albums_menu():
    pos = 0
    while True:
        h, w = term_size()
        rows = [album_row(a, w) for a in P.albums]
        inc = [a for a in P.albums if a.get("include")]
        hdr = (f" {CB}Albums{C0}  {len(inc)} of {len(P.albums)} included · "
               f"{mmss(sum(album_duration(a) for a in inc))} of music\n")
        k, pos = list_view(hdr, rows, pos, footer="space include/exclude · enter details · r rescan",
                           keys=("space", "r"))
        if k == "q":
            return
        if k == "r":
            do_scan()
        elif k == "space" and P.albums:
            a = P.albums[pos]
            a["include"] = not a.get("include")
            P.save()
            pos = min(len(P.albums) - 1, pos + 1)
        elif k == "enter" and P.albums:
            album_detail(P.albums[pos])


def album_detail(a):
    while True:
        def hdr():
            q = quality_label(a["tracks"])
            return (f" {CB}{a['artist']} – {a['title']}{C0} {CD}({a.get('year') or '?'}){C0}\n\n"
                    f" {'Folder':<8} {tildify(a['folder'])}\n"
                    f" {'Length':<8} {mmss(album_duration(a))} · {len(inc_tracks(a))}/{len(a['tracks'])} tracks"
                    + (f" · {len(a['parts'])} discs" if len([x for x in a['parts'] if x]) > 1 else "") + "\n"
                    f" {'Source':<8} {q}" + (f"  {CY}lossy - can't be bit-perfect{C0}" if "lossy" in q else "") + "\n"
                    f" {'Status':<8} " + (f"{CG}included{C0}" if a.get("include") else f"{CD}excluded{C0}")
                    + (f"  {CY}(a better copy of this album is in the library){C0}" if a.get("dup_of") else "") + "\n")
        k = run_menu(hdr, [
            ("i", "Include", "include / exclude this album"),
            ("t", "Tracks", "choose tracks, rename titles"),
            ("a", "Artist", "edit the artist name"),
            ("e", "Title", "edit the album title"),
            ("y", "Year", "edit the year"),
            ("v", "Compilation", "various artists: " + ("on" if a.get("va") else "off")),
            ("o", "Open folder", "show the files"),
            ("r", "Reset", "undo your edits (back to the tags)"),
        ], key="album")
        if k == "q":
            return
        cls()
        if k == "i":
            a["include"] = not a.get("include")
        elif k in ("a", "e", "y"):
            field = {"a": "artist", "e": "title", "y": "year"}[k]
            v = ask(f" {field.capitalize()}: ", a.get(field, ""))
            if v is not None and v != "":
                a[field] = int(v) if field == "year" and v.isdigit() else v
                a["edited"] = sorted(set(a.get("edited", [])) | {field})
        elif k == "v":
            a["va"] = not a.get("va")
            a["edited"] = sorted(set(a.get("edited", [])) | {"va"})
        elif k == "t":
            tracks_menu(a)
        elif k == "o":
            open_path(a["folder"])
        elif k == "r":
            a.update(a["guess"])
            a["edited"] = []
            for t in a["tracks"]:
                t["title"] = None
                t["include"] = True
        P.save()


def tracks_menu(a):
    pos = 0
    while True:
        rows = []
        for i, t in enumerate(a["tracks"]):
            inc = f"{CG}✔{C0}" if t.get("include", True) else f"{CD}·{C0}"
            part = f"{CD}{a['parts'][t['part']]}{C0} " if len([x for x in a['parts'] if x]) > 1 else ""
            edited = f" {CM}✎{C0}" if t.get("title") else ""
            rows.append(f"{inc} {part}{i + 1:2d}  {pad(track_title(P, t), 50)} {mmss(t['duration']):>6}  {CD}{quality_of(t)}{C0}{edited}")
        hdr = (f" {CB}{a['artist']} – {a['title']}{C0}  {mmss(album_duration(a))} selected\n"
               f" {CD}excluded tracks are left off the CD (e.g. drop bonus tracks to fit one disc){C0}\n")
        k, pos = list_view(hdr, rows, pos, footer="space include/exclude · e rename · a all", keys=("space", "e", "a"))
        if k == "q":
            return
        t = a["tracks"][pos]
        if k == "space":
            t["include"] = not t.get("include", True)
            pos = min(len(rows) - 1, pos + 1)
        elif k == "a":
            allon = all(x.get("include", True) for x in a["tracks"])
            for x in a["tracks"]:
                x["include"] = not allon
        elif k in ("e", "enter"):
            cls()
            v = ask(" Title (empty = from tags): ", track_title(P, t))
            if v is not None:
                t["title"] = v if v and v != (clean_title(t["tag_title"]) if P.S["clean_titles"] else t["tag_title"]) else None
        P.save()


# ---- plan
def plan_rows(w):
    rows = []
    for n, d in enumerate(P.discs, 1):
        dur = disc_duration(P, d)
        prob = disc_problems(P, d)
        warn_s = f" {CR}⚠ {prob[0]}{C0}" if prob else ""
        badge = state_badge(P, d)
        left = max(20, w - 42 - vlen(badge))
        rows.append(f"{CB}CD{n:02d}{C0} {mmss(dur):>6} {bar(dur, P.budget())} {pad(disc_name(P, d), left)} {badge}{warn_s}")
    return rows


def plan_hdr():
    tot = sum(disc_duration(P, d) for d in P.discs)
    s = (f" {CB}Plan{C0}  {len(P.discs)} CDs · {mmss(tot)} of music · max {mmss(P.budget())} per {P.S['capacity_min']}-min CD"
         f" · combine: {P.S['combine']}\n")
    if P.data.get("plan_locked"):
        s += f" {CG}🔒 locked{C0} {CD}- labels printed: the CDs and their numbers can't change (L unlocks){C0}\n"
    elif plan_stale(P):
        s += f" {CY}Albums or settings changed since this plan was made.{C0} {CD}It still works; r re-plans only if you want to.{C0}\n"
    if P.data.get("plan_undo") and not P.data.get("plan_locked"):
        s += f" {CD}u undoes the last re-plan ({P.data['plan_undo'].get('at', '')}){C0}\n"
    return s


def plan_locked_msg():
    cls()
    warn("The plan is locked (labels printed), so CDs can't be regrouped or renumbered.")
    say("   Unlock it with L in the Plan menu if you really want to change it.")
    pause()


def plan_menu():
    pos = 0
    while True:
        if not P.discs:
            cls()
            if not P.albums:
                err("No albums yet - add music folders first.")
                pause()
                return
            try:
                auto_plan(P)
            except ValueError as e:
                err(str(e))
                pause()
                return
        h, w = term_size()
        k, pos = list_view(plan_hdr, plan_rows(w), pos,
                           footer="enter disc · r re-plan · u undo re-plan · L lock · J/K move disc · b build · w burn · v verify · i label",
                           keys=("r", "u", "L", "J", "K", "b", "w", "i", "v"))
        if k == "q":
            return
        d = P.discs[pos] if P.discs else None
        locked = P.data.get("plan_locked")
        if k in ("r", "u", "J", "K") and locked:
            plan_locked_msg()
        elif k == "L":
            P.data["plan_locked"] = not locked
            P.save()
        elif k == "u":
            cls()
            u = P.data.get("plan_undo")
            if not u:
                info("Nothing to undo.")
                pause()
            elif yesno(f" Go back to the plan from before the last re-plan ({len(u['discs'])} CDs, {u.get('at', '')})?", "y"):
                undo_plan(P)
                ok("Previous plan restored (u again switches back).")
                pause()
        elif k == "r":
            cls()
            nb = burned_count(P)
            say(" Re-planning regroups and renumbers the CDs from scratch (Settings › combine: "
                f"{P.S['combine']}, max {P.S['max_per_disc']} per CD).")
            if nb:
                warn(f"{nb} CD(s) are already burned: if their number or contents change, labels you printed won't match.")
            if P.data.get("plan_manual"):
                warn("Your manual changes to the plan will be lost.")
            say(f" {CD}You can undo it afterwards with u.{C0}")
            if yesno(" Re-plan now?", "n" if nb else "y"):
                try:
                    auto_plan(P)
                except ValueError as e:
                    err(str(e))
                    pause()
        elif k in ("J", "K") and d:
            j = pos + (1 if k == "J" else -1)
            if 0 <= j < len(P.discs):
                P.discs[pos], P.discs[j] = P.discs[j], P.discs[pos]
                pos = j
                P.data["plan_manual"] = True
                P.save()
        elif k == "enter" and d:
            disc_menu(pos)
        elif k == "b" and d:
            cls()
            build_discs(P, [(pos + 1, d)])
            pause()
        elif k == "w" and d:
            burn_flow(pos + 1, d)
        elif k == "v" and d:
            verify_flow(pos + 1, d)
        elif k == "i":
            labels_open(f"CD{pos + 1:02d}")


def disc_menu(pos):
    while True:
        if pos >= len(P.discs):
            return
        d = P.discs[pos]
        n = pos + 1

        def hdr():
            entries = disc_entries(P, d)
            s = f" {CB}CD{n:02d}{C0}  {mmss(disc_duration(P, d))} of {mmss(P.budget())}  {state_badge(P, d)}\n"
            for si, sg in enumerate(d["segments"]):
                a = P.album(sg["album"])
                if a:
                    s += f"   {CC}{a['artist']} – {a['title']}{C0} {CD}{sg['part']}{C0}  ({sum(1 for e in entries if e['seg'] == si)} tracks)\n"
            for p in disc_problems(P, d):
                s += f"   {CR}⚠ {p}{C0}\n"
            return s
        items = [("t", "Track list", "what will be on this CD"),
                 ("m", "Move album", "move an album of this CD to another CD"),
                 ("c", "Combine", "put this whole CD together with another one")]
        if len(d["segments"]) > 1:
            items.append(("s", "Separate", "give each album its own CD"))
        items += [("b", "Build", "make the burn-ready image"), ("w", "Burn", "burn this CD"),
                  ("v", "Verify", "check a burned copy is bit-identical"), ("i", "Label", "open this CD's label")]
        k = run_menu(hdr, items, key="disc")
        if k == "q":
            return
        if k == "t":
            lines = []
            entries = disc_entries(P, d)
            for si, sg in enumerate(d["segments"]):
                a = P.album(sg["album"])
                if not a:
                    continue
                if si:
                    lines.append(f"{CD}   — {P.S['gap_s']} s gap —{C0}")
                ts = [a["tracks"][i] for i in sg["tracks"] if i < len(a["tracks"])]
                lines.append(f"{CB}{a['artist']} – {a['title']}{C0} {a['year'] or ''} {sg['part']}  {CD}{quality_label(ts)}{C0}")
                for e in entries:
                    if e["seg"] == si:
                        lines.append(f"  {e['n']:2d}. {pad(e['title'], 60)} {mmss(e['duration']):>6}")
            pager(f"CD{n:02d} track list", lines)
        elif k in ("m", "c", "s") and P.data.get("plan_locked"):
            plan_locked_msg()
        elif k in ("m", "c"):
            move_flow(pos, whole=(k == "c"))
        elif k == "s":
            segs = d["segments"]
            d["segments"] = segs[:1]
            for i, sg in enumerate(segs[1:], 1):
                P.discs.insert(pos + i, {"uid": "%08x" % random.getrandbits(32), "segments": [sg], "status": {}})
            P.data["plan_manual"] = True
            P.save()
        elif k == "b":
            cls()
            build_discs(P, [(n, d)])
            pause()
        elif k == "w":
            burn_flow(n, d)
        elif k == "v":
            verify_flow(n, d)
        elif k == "i":
            labels_open(f"CD{n:02d}")


def move_flow(pos, whole):
    d = P.discs[pos]
    segs = list(range(len(d["segments"])))
    if not whole and len(segs) > 1:
        rows = [f"{P.album(s['album'])['artist']} – {P.album(s['album'])['title']} {s['part']}" for s in d["segments"]]
        k, si = list_view(f" {CB}Which album?{C0}\n", rows)
        if k != "enter":
            return
        segs = [si]
    moving = [d["segments"][i] for i in segs]
    seg_dur = sum(sum(P.album(s["album"])["tracks"][i]["duration"] for i in s["tracks"]) for s in moving)
    gap, budget = P.S["gap_s"], P.budget()
    targets, rows = [], []
    for j, t in enumerate(P.discs):
        if j == pos:
            continue
        new = disc_duration(P, t) + gap * len(moving) + seg_dur
        targets.append(j)
        note = f"{CG}fits ({mmss(new)}){C0}" if new <= budget else f"{CR}too long ({mmss(new)}){C0}"
        rows.append(f"CD{j + 1:02d} {pad(disc_name(P, t), 60)} {note}")
    if not whole:
        targets.append(None)
        rows.append(f"{CC}+ a new CD of its own{C0}")
    k, i = list_view(f" {CB}Move to…{C0}  {mmss(seg_dur)} to place\n", rows, footer="enter choose")
    if k != "enter":
        return
    tj = targets[i]
    if tj is not None and disc_duration(P, P.discs[tj]) + gap * len(moving) + seg_dur > budget:
        cls()
        err("That doesn't fit on one CD.")
        pause()
        return
    for s in moving:
        d["segments"].remove(s)
    if tj is None:
        P.discs.insert(pos + 1, {"uid": "%08x" % random.getrandbits(32), "segments": moving, "status": {}})
    else:
        P.discs[tj]["segments"] += moving
        P.discs[tj]["segments"].sort(key=lambda s: album_sort(P.album(s["album"])))
    if not d["segments"]:
        P.discs.remove(d)
    P.data["plan_manual"] = True
    P.save()


# ---- build / burn / verify
def pick_discs(title, preselect):
    sel = {i for i, d in enumerate(P.discs) if preselect(d)}
    h, w = term_size()
    k, _ = list_view(f" {CB}{title}{C0}\n", plan_rows(w), multi=sel, footer="enter start")
    if k != "enter":
        return []
    return [(i + 1, P.discs[i]) for i in sorted(sel)]


def build_menu():
    if not P.discs:
        auto_plan(P)
    which = pick_discs("Build images - select CDs (pre-selected: not built yet)", lambda d: not disc_state(P, d)["built"])
    if not which:
        return
    cls()
    say(f" {CB}Building {len(which)} CD image(s){C0}, {P.S['jobs']} at a time · {tildify(P.build_dir)}\n")
    build_discs(P, which)
    pause()


def single_disc(title, pre=None):
    h, w = term_size()
    start = next((i for i, d in enumerate(P.discs) if pre and pre(d)), 0)
    k, i = list_view(f" {CB}{title}{C0}\n", plan_rows(w), pos=start, footer="enter choose")
    return (i + 1, P.discs[i]) if k == "enter" and P.discs else (None, None)


def burn_flow(n=None, d=None):
    if d is None:
        n, d = single_disc("Burn - choose a CD", lambda x: disc_state(P, x)["built"] and not disc_state(P, x)["burned"])
        if d is None:
            return
    cls()
    if not disc_state(P, d)["built"]:
        if not yesno(f" CD{n:02d} has no up-to-date image. Build it now?", "y"):
            return
        if not build_discs(P, [(n, d)]):
            pause()
            return
        say()
    first = not any(x.get("status", {}).get("burned") for x in P.discs)
    simulate = first and yesno(" First burn with this setup: do a simulation (laser off) first?", "y")
    if simulate:
        if not burn_disc(P, n, d, simulate=True):
            pause()
            return
        say()
        if not yesno(" Burn for real now?", "y"):
            return
    if burn_disc(P, n, d):
        say()
        if yesno(" Verify the disc now (re-insert it after it ejects)?", "y"):
            say(" Insert the burned disc and press any key…")
            read_key()
            verify_disc(P, n, d)
    pause()


def verify_flow(n=None, d=None):
    if d is None:
        n, d = single_disc("Verify - choose the CD that is in the drive",
                           lambda x: disc_state(P, x)["burned"] and not disc_state(P, x)["verified"])
        if d is None:
            return
    cls()
    readback = None
    if WINDOWS or not have("cdparanoia"):
        say(" Give a WAV rip of the whole disc (tracks 1 to end as one file).")
        readback = ask(" Rip file: ", "", path=True)
        if not readback:
            return
    else:
        say(f" Insert CD{n:02d} into {current_device()} and press any key…")
        read_key()
    verify_disc(P, n, d, readback=readback)
    pause()


def labels_open(anchor=""):
    f = write_labels(P)
    url = f.as_uri() + (f"#{anchor}" if anchor else "")
    if WINDOWS:
        import webbrowser
        webbrowser.open(url)
    else:
        try:
            import webbrowser
            webbrowser.open(url)
        except Exception:
            open_path(f)


def labels_menu():
    while True:
        k = run_menu(lambda: (f" {CB}Labels{C0}\n\n {CD}labels.html: tick discs, print at 100% / no margins, 2 per sheet."
                              f"\n Standard CD labels are 117 mm with a 41 mm hole (adjustable on the page).{C0}\n"
                              f"\n {'File':<8} {tildify(P.dir / 'labels.html')}\n"), [
            ("o", "Open labels", "write labels.html and open it in the browser"),
            ("t", "Track lists", "write tracklists.txt (all CDs, plain text) and view it"),
            ("f", "Folder", "open the project folder"),
            ("p", "Lock plan", ("on" if P.data.get("plan_locked") else "off")
             + " - once labels are printed, lock so CDs are never regrouped or renumbered"),
        ], key="labels")
        if k == "q":
            return
        if k == "p":
            P.data["plan_locked"] = not P.data.get("plan_locked")
            P.save()
        elif k == "o":
            labels_open()
        elif k == "t":
            write_labels(P)
            pager("tracklists.txt", (P.dir / "tracklists.txt").read_text(encoding="utf-8").splitlines())
        elif k == "f":
            open_path(P.dir)


def cleanup_menu():
    while True:
        items = []
        known = set()
        for n, d in enumerate(P.discs, 1):
            b = d.get("status", {}).get("built")
            if b and Path(b["dir"]).is_dir():
                known.add(Path(b["dir"]).resolve())
                size = sum(f.stat().st_size for f in Path(b["dir"]).glob("*") if f.is_file())
                s = disc_state(P, d)
                tag = f"{CG}verified{C0}" if s["verified"] else f"{CG}burned{C0}" if s["burned"] else f"{CY}outdated{C0}" if s["stale"] else "not burned"
                items.append((Path(b["dir"]), f"CD{n:02d} {pad(disc_name(P, d), 50)} {hsize(size):>8}  {tag}", s["burned"] or s["stale"]))
        if P.build_dir.is_dir():
            for x in sorted(P.build_dir.iterdir()):
                if x.is_dir() and x.resolve() not in known:
                    size = sum(f.stat().st_size for f in x.rglob("*") if f.is_file())
                    items.append((x, f"{pad(x.name, 55)} {hsize(size):>8}  {CD}not in the plan{C0}", True))
        if not items:
            cls()
            info("Nothing to clean up.")
            pause()
            return
        sel = {i for i, it in enumerate(items) if it[2]}
        total = sum(sum(f.stat().st_size for f in it[0].rglob("*") if f.is_file()) for it in items)
        k, _ = list_view(f" {CB}Clean up{C0}  built images use {hsize(total)} in {tildify(P.build_dir)}\n"
                         f" {CD}pre-selected: burned, outdated or unused images. They can be rebuilt any time.{C0}\n",
                         [it[1] for it in items], multi=sel, footer="enter delete selected")
        if k != "enter" or not sel:
            return
        cls()
        if yesno(f" Delete {len(sel)} image folder(s)?", "n"):
            for i in sel:
                shutil.rmtree(items[i][0], ignore_errors=True)
            ok("Deleted.")
            pause()
        return


def drive_menu():
    while True:
        def hdr():
            dr = list_drives()
            s = f" {CB}Burner{C0}\n\n"
            s += f" {'Drives':<9} " + (", ".join(f"{a} ({b})" for a, b in dr) if dr else f"{CY}none detected{C0}") + "\n"
            s += f" {'Using':<9} {current_device()}\n"
            s += f" {'Program':<9} {engine() or CR + 'none - install ' + ('ImgBurn' if WINDOWS else 'cdrdao') + C0}\n"
            s += f" {'Verify':<9} {'cdparanoia' if have('cdparanoia') else 'rip file (cdparanoia not installed)'}\n"
            return s
        k = run_menu(hdr, [
            ("d", "Device", f"which drive to use ({current_device()})"),
            ("s", "Speed", f"write speed ({CFG.get('speed', 16)}x - 16x suits 52x CD-R in a slim USB drive)"),
            ("e", "Program", f"burning program ({CFG.get('engine', 'auto')})"),
            ("r", "Driver", f"cdrdao driver ({CFG.get('driver') or 'auto'}) - try generic-mmc-raw if CD-Text is missing"),
            ("i", "Drive info", "what the drive and the disc report"),
            ("p", "Install", "install missing programs"),
        ], key="drive")
        if k == "q":
            return
        if k == "d":
            dr = list_drives()
            opts = [(a, f"{a}  {b}") for a, b in dr] + [("", "auto (first drive found)"), ("?", "type a device…")]
            v = choose("Device", opts, CFG.get("device", ""))
            if v == "?":
                cls()
                v = ask(" Device: ", current_device())
            if v is not None:
                CFG["device"] = v
        elif k == "s":
            v = choose("Write speed", [(s, f"{s}x" + ("  (recommended)" if s == 16 else "")) for s in (4, 8, 10, 16, 24, 32, 48)],
                       CFG.get("speed", 16))
            if v:
                CFG["speed"] = v
        elif k == "e":
            v = choose("Burning program", [("auto", "auto"), ("cdrdao", "cdrdao (Linux, also Windows builds)"),
                                           ("imgburn", "ImgBurn (Windows)")], CFG.get("engine", "auto"))
            if v:
                CFG["engine"] = v
                if v == "imgburn" and not find_imgburn():
                    cls()
                    p = ask(" Path to ImgBurn.exe: ", "", path=True)
                    if p:
                        CFG["imgburn"] = p
        elif k == "r":
            v = choose("cdrdao driver", [("", "auto"), ("generic-mmc", "generic-mmc"), ("generic-mmc-raw", "generic-mmc-raw")],
                       CFG.get("driver", ""))
            if v is not None:
                CFG["driver"] = v
        elif k == "i":
            cls()
            if have("cdrdao"):
                subprocess.run(["cdrdao", "drive-info", "--device", current_device()])
                subprocess.run(["cdrdao", "disk-info", "--device", current_device()])
            else:
                for a, b in list_drives():
                    say(f" {a}  {b}")
            pause()
        elif k == "p":
            cls()
            install_deps()
            pause()
        save_cfg()


def install_deps():
    missing = [x for x in ("ffmpeg",) if not FFMPEG]
    if not WINDOWS:
        missing += [x for x in ("cdrdao", "cdparanoia") if not have(x)]
    elif not find_imgburn():
        missing.append("imgburn")
    if not missing:
        ok("Everything is installed.")
        return
    cmd = install_hint(*missing)
    say(f" Missing: {', '.join(missing)}\n   {cmd}")
    if pkg_manager() and yesno(" Run it now?", "y"):
        subprocess.run(cmd, shell=True)


def settings_menu():
    while True:
        S = P.S

        def val(k):
            v = S[k]
            return "yes" if v is True else "no" if v is False else str(v)
        items = [(str(i + 1) if i < 9 else chr(ord("a") + i - 9), SETTING_INFO[k].split(" (")[0][:13], f"{val(k):<12} {CD}{SETTING_INFO[k]}{C0}")
                 for i, k in enumerate(SETTING_INFO)]
        keys = list(SETTING_INFO)
        k = run_menu(lambda: f" {CB}Settings{C0}  {CD}(this project){C0}\n", items, key="settings")
        if k == "q":
            return
        key = keys[[it[0] for it in items].index(k)]
        cls()
        if key == "combine":
            v = choose("Put short albums on the same CD", [("any", "any albums that fit"), ("artist", "only albums by the same artist"),
                                                            ("off", "never - one album per CD")], S[key])
        elif key == "dither":
            v = choose("Dither", [("triangular", "TPDF / triangular (recommended, flat)"), ("triangular_hp", "TPDF high-pass"),
                                  ("shibata", "Shibata noise shaping"), ("f_weighted", "F-weighted noise shaping")], S[key])
        elif key == "capacity_min":
            v = choose("Blank CD length", [(80, "80 min / 700 MB (standard)"), (74, "74 min / 650 MB"),
                                           (90, "90 min (overburn, many players can't read)"), (99, "99 min (overburn)")], S[key])
        elif key == "precision":
            v = choose("Resampler precision", [(20, "20 - high"), (28, "28 - very high (recommended)"), (33, "33 - maximum")], S[key])
        elif isinstance(S[key], bool):
            v = not S[key]
        else:
            r = ask(f" {SETTING_INFO[key]}: ", S[key])
            try:
                v = type(S[key])(r) if r not in (None, "") else None
            except ValueError:
                v = None
        if v is not None:
            S[key] = v
            P.save()


def help_text():
    return f"""cdburn {VERSION}

Keys
  j/k or arrows  move      enter / l  open/select     h / esc / q  back
  space          tick      a          all / none       g/G          top/bottom

How it works
  1 Music     add one or more folders. Every folder holding audio becomes an album;
              "CD 1"/"Disc 2" subfolders, multi-disc tags and single-file FLAC+CUE
              rips are understood. If an album exists twice, the best copy is used
              (lossless over lossy, then higher resolution) and the other is skipped.
  2 Albums    include/exclude albums or single tracks, fix artist/title/year.
  3 Plan      albums are packed onto CDs: albums too long for one CD are split
              (at their own disc boundaries when possible, else balanced by tracks);
              short albums share a CD when they fit (Settings: combine). Move
              albums between CDs, combine or separate CDs, reorder with J/K.
  4 Build     each CD becomes one gapless image (disc.wav + disc.toc + disc.cue):
               - 16-bit/44.1 kHz lossless sources are copied bit for bit
               - everything else: decoded to float, resampled with SoX VHQ (libsoxr),
                 constant gain only if peaks would clip, TPDF dither to 16 bit once
               - albums are processed as one stream: gapless albums stay gapless
               - 2 s of silence between albums on the same CD
  5 Burn      Disc-At-Once with CD-Text (cdrdao on Linux, ImgBurn on Windows).
              16x is the sweet spot for 52x-rated CD-R in a slim USB drive.
  6 Verify    the CD is read back with cdparanoia and compared sample by sample.
  7 Labels    labels.html: 117 mm disc labels with every track, print at 100%.

Files
  Project     {tildify(P.dir) if P else '-'}  (cdburn.json, build/, labels.html)
  Settings    {tildify(CFG_FILE)}  (burner, speed)

Command line:  cdburn status | scan | plan | build CD01 | burn CD01 | verify CD01 | labels
""".splitlines()


def main_menu():
    while True:
        items = [("m", "Music", "music folders · rescan"),
                 ("a", "Albums", "include/exclude, names, tracks"),
                 ("p", "Plan", "which albums go on which CD"),
                 ("b", "Build", "make burn-ready images"),
                 ("w", "Burn", "burn a CD"),
                 ("v", "Verify", "check a burned CD is bit-identical"),
                 ("i", "Labels", "printable disc labels · track lists"),
                 ("x", "Clean up", "delete built images"),
                 ("d", "Burner", "drive, speed, program"),
                 ("c", "Settings", "CD length, combining albums, quality"),
                 ("o", "Projects", "switch / new project"),
                 ("?", "Help", "keys and how it works")]
        k = run_menu(main_hdr, items, key="main")
        cls()
        if k == "q":
            return
        if k == "o":
            projects_menu()
            continue
        if k == "d":
            drive_menu()
            continue
        if k == "?":
            pager("Help", help_text())
            continue
        if not need_project():
            continue
        {"m": sources_menu, "a": albums_menu, "p": plan_menu, "b": build_menu, "w": burn_flow, "v": verify_flow,
         "i": labels_menu, "x": cleanup_menu, "c": settings_menu}[k]()


# -------------------------------------------------------------- install ---
def launcher_path():
    if WINDOWS:
        return Path(os.environ.get("LOCALAPPDATA", Path.home())) / "Microsoft" / "WindowsApps" / "cdburn.cmd"
    return Path.home() / ".local" / "bin" / "cdburn"


def install():
    lp = launcher_path()
    lp.parent.mkdir(parents=True, exist_ok=True)
    if WINDOWS:
        lp.write_text(f'@echo off\r\ncall "{SELF.with_name("cdburn.cmd")}" %*\r\n', encoding="utf-8")
    else:
        if lp.exists() or lp.is_symlink():
            lp.unlink()
        lp.symlink_to(SELF)
        SELF.chmod(SELF.stat().st_mode | 0o111)
    ok(f"Installed {tildify(lp)} → {tildify(SELF)}")
    if str(lp.parent) not in os.environ.get("PATH", "").split(os.pathsep):
        warn(f"{lp.parent} is not in your PATH.")


def uninstall():
    lp = launcher_path()
    if lp.exists() or lp.is_symlink():
        lp.unlink()
        ok(f"Removed {tildify(lp)}")
    if CFG_FILE.parent.is_dir() and (not TTY or yesno(f" Also remove settings in {tildify(CFG_FILE.parent)}?", "n")):
        shutil.rmtree(CFG_FILE.parent, ignore_errors=True)
        ok("Removed settings.")
    say(" Projects (cdburn.json, build/, labels.html) are left where they are.")


# ------------------------------------------------------------------- main ---
def resolve_project(arg):
    for cand in ([arg] if arg else []) + [os.getcwd(), CFG.get("last_project", "")]:
        if cand and (Path(cand).expanduser() / PROJECT_FILE).exists():
            return Project.load(Path(cand).expanduser())
    return None


def print_status(P):
    say(f"{CB}{tildify(P.dir)}{C0}  {len(P.albums)} albums · {len(P.discs)} CDs · max {mmss(P.budget())} per CD"
        + ("  🔒 plan locked" if P.data.get("plan_locked") else ""))
    if plan_stale(P) and not P.data.get("plan_locked"):
        info("albums or settings changed since the plan was made; it still works ('cdburn plan' re-plans)")
    w = term_size()[1]
    for r in plan_rows(w if TTY else 140):
        say("  " + r)


def main(argv=None):
    global P
    ap = argparse.ArgumentParser(prog="cdburn", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--project")
    ap.add_argument("-V", "--version", action="version", version=VERSION)
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("new"); s.add_argument("dirs", nargs="+")
    sub.add_parser("scan"); sub.add_parser("status"); sub.add_parser("menu")
    s = sub.add_parser("plan"); s.add_argument("--undo", action="store_true"); s.add_argument("--force", action="store_true")
    s.add_argument("--lock", action="store_true"); s.add_argument("--unlock", action="store_true")
    s = sub.add_parser("build"); s.add_argument("discs", nargs="+"); s.add_argument("-j", "--jobs", type=int)
    s = sub.add_parser("burn"); s.add_argument("disc"); s.add_argument("--simulate", action="store_true")
    s.add_argument("--speed", type=int); s.add_argument("--device"); s.add_argument("-y", "--yes", action="store_true")
    s = sub.add_parser("verify"); s.add_argument("disc"); s.add_argument("--readback"); s.add_argument("--device")
    s = sub.add_parser("labels"); s.add_argument("--no-open", action="store_true")
    sub.add_parser("install"); sub.add_parser("uninstall")
    a = ap.parse_args(argv)
    load_cfg()
    cmd = a.cmd or "menu"

    if cmd == "install":
        return install()
    if cmd == "uninstall":
        return uninstall()
    if cmd == "new":
        need_ffmpeg()
        srcs = [str(Path(x).expanduser().resolve()) for x in a.dirs]
        for x in srcs:
            if not Path(x).is_dir():
                raise SystemExit(f"not a folder: {x}")
        pdir = Path(a.project).expanduser() if a.project else Path(srcs[0]) / "_CD_Burning"
        P = Project.load(pdir) if (pdir / PROJECT_FILE).exists() else Project(pdir)
        for x in srcs:
            if x not in P.sources:
                P.sources.append(x)
        P.save()
        remember_project(P.dir)
        say(f"Scanning {len(srcs)} folder(s)…")
        albums = scan_project(P, lambda i, n: (sys.stdout.write(f"\r  reading tags {i}/{n}"), sys.stdout.flush()))
        say(f"\n{len(albums)} albums found.")
        for al in albums:
            if al.get("dup_of"):
                info(f"skipped duplicate (lower quality): {tildify(al['folder'])}")
        if not P.discs:
            auto_plan(P)
        print_status(P)
        return
    if cmd == "menu":
        if not TTY:
            raise SystemExit("The menu needs a terminal. Try: cdburn status")
        try:
            P = resolve_project(a.project)
            if P:
                remember_project(P.dir)
            elif not first_run():
                return
            main_menu()
        except KeyboardInterrupt:
            pass
        finally:
            cursor(True)
            cls()
        return
    P = resolve_project(a.project)
    if not P:
        raise SystemExit("No project here. Start one with:  cdburn new ~/Music/albums  (or just run cdburn)")
    if cmd == "scan":
        albums = scan_project(P, lambda i, n: (sys.stdout.write(f"\r  reading tags {i}/{n}"), sys.stdout.flush()))
        say(f"\n{len(albums)} albums.")
        if plan_stale(P):
            warn("the plan is out of date - run: cdburn plan")
    elif cmd == "plan":
        if a.lock or a.unlock:
            P.data["plan_locked"] = bool(a.lock)
            P.save()
            ok("Plan locked." if a.lock else "Plan unlocked.")
        elif P.data.get("plan_locked") and not a.force:
            raise SystemExit("The plan is locked (labels printed). Use --unlock first, or --force.")
        elif a.undo:
            if not undo_plan(P):
                raise SystemExit("Nothing to undo.")
            ok("Previous plan restored.")
        else:
            nb = burned_count(P)
            if nb and not a.force:
                raise SystemExit(f"{nb} CD(s) are already burned - re-planning may renumber them. Add --force to do it anyway.")
            auto_plan(P)
        print_status(P)
    elif cmd == "status":
        print_status(P)
    elif cmd == "build":
        which = list(enumerate(P.discs, 1)) if a.discs == ["all"] else [find_disc(P, x) for x in a.discs]
        sys.exit(0 if build_discs(P, which, a.jobs) else 1)
    elif cmd == "burn":
        n, d = find_disc(P, a.disc)
        sys.exit(0 if burn_disc(P, n, d, a.simulate, a.speed, a.device, a.yes) else 1)
    elif cmd == "verify":
        n, d = find_disc(P, a.disc)
        sys.exit(0 if verify_disc(P, n, d, a.readback, a.device) else 1)
    elif cmd == "labels":
        f = write_labels(P)
        ok(f"Wrote {tildify(f)} and tracklists.txt")
        if not a.no_open:
            labels_open()


LABEL_TEMPLATE = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>CD Labels</title>
<style id="page-size">@page { size: A4; margin: 0; }</style>
<style>
  :root {
    --ink: #161616;
    --muted: #5d5d5d;
    --panel: #f4f2ee;
    --line: #d9d5cd;
    --accent-ui: #1f5f99;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; background: #e9e6e0; color: var(--ink);
    font: 14px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  .controls { max-width: 210mm; margin: 0 auto; padding: 20px 16px 8px; }
  .controls h1 { font-size: 22px; margin: 0 0 4px; letter-spacing: -0.01em; }
  .controls p { margin: 0 0 12px; color: var(--muted); max-width: 70ch; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; margin-bottom: 12px; }
  .card h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); margin: 0 0 10px; }
  .discs { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 4px 14px; }
  .discs label { display: flex; gap: 8px; align-items: baseline; cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .discs label b { font-variant-numeric: tabular-nums; }
  .row { display: flex; flex-wrap: wrap; gap: 10px 18px; align-items: center; }
  .row label { display: flex; gap: 6px; align-items: center; }
  input[type=number] { width: 72px; padding: 3px 6px; border: 1px solid var(--line); border-radius: 6px; font: inherit; }
  select { padding: 3px 6px; border: 1px solid var(--line); border-radius: 6px; font: inherit; background: #fff; }
  button { font: inherit; padding: 6px 14px; border-radius: 8px; border: 1px solid var(--line); background: #fff; cursor: pointer; }
  button.primary { background: var(--accent-ui); border-color: var(--accent-ui); color: #fff; font-weight: 600; }
  .hint { font-size: 12.5px; color: var(--muted); margin-top: 8px; }
  .pages { overflow-x: auto; padding: 8px 16px 40px; }
  .page { position: relative; width: 210mm; height: 297mm; background: #fff; margin: 0 auto 18px;
          box-shadow: 0 2px 14px rgba(0,0,0,.18); overflow: hidden; }
  .label { position: absolute; display: block; }
  .empty { text-align: center; color: var(--muted); padding: 40px; }
  @media print {
    html, body { background: #fff; }
    .controls { display: none; }
    .pages { padding: 0; overflow: visible; }
    .page { margin: 0; box-shadow: none; break-after: page; page-break-after: always; }
    .page:last-child { break-after: auto; page-break-after: auto; }
  }
</style>
</head>
<body>
<div class="controls">
  <h1>CD labels</h1>
  <p>Pick the discs to print and press <b>Print</b>. In the print dialog set scale to <b>100% / Actual size</b>
     and margins to <b>None</b>. Print one sheet on plain paper first and hold it against a CD to check alignment.</p>

  <div class="card">
    <h2>Discs</h2>
    <div class="row" style="margin-bottom:8px">
      <button type="button" id="all">Select all</button>
      <button type="button" id="none">Select none</button>
    </div>
    <div class="discs" id="disc-list"></div>
  </div>

  <div class="card">
    <h2>Paper &amp; label</h2>
    <div class="row">
      <label>Paper <select id="paper"><option value="A4">A4</option><option value="Letter">US Letter</option></select></label>
      <label>Label Ø <input type="number" id="outer" step="0.5" min="100" max="120"> mm</label>
      <label>Hole Ø <input type="number" id="hole" step="0.5" min="10" max="45"> mm</label>
      <label>Nudge X <input type="number" id="nx" step="0.5" min="-20" max="20"> mm</label>
      <label>Nudge Y <input type="number" id="ny" step="0.5" min="-20" max="20"> mm</label>
    </div>
    <div class="row" style="margin-top:10px">
      <label><input type="checkbox" id="guides"> Cut guides</label>
      <label><input type="checkbox" id="color"> Colour accents</label>
      <button type="button" class="primary" id="print">Print</button>
    </div>
    <div class="hint">Standard self-adhesive CD labels are 117&nbsp;mm with a 41&nbsp;mm hole; "full-face" ones are about 118&nbsp;mm with a 17&nbsp;mm hole.
      If you use pre-cut label sheets, turn the cut guides off and use Nudge X/Y to line the print up with the sheet.</div>
  </div>
</div>

<div class="pages" id="pages"></div>

<script>
const DISCS = /*__DISCS__*/[];
const NS = 'http://www.w3.org/2000/svg';
const FONT = "'Roboto Condensed','Arial Narrow','DejaVu Sans Condensed','Liberation Sans Narrow',sans-serif";
const PALETTE = ['#B03A2E','#1F618D','#7D3C98','#B9770E','#1E8449','#A04000','#2C3E50','#922B21','#117A65','#6C3483','#1A5276','#7E5109','#5B2C6F'];
const artistColor = (() => {
  const order = [];
  DISCS.forEach(d => d.albums.forEach(a => { if (!order.includes(a.artist)) order.push(a.artist); }));
  return a => PALETTE[order.indexOf(a) % PALETTE.length];
})();

const DEFAULTS = { paper: 'A4', outer: 117, hole: 41, nx: 0, ny: 0, guides: true, color: true, selected: DISCS.map(d => d.id) };
let S = { ...DEFAULTS };
try { S = { ...DEFAULTS, ...JSON.parse(localStorage.getItem('cdLabelSettings') || '{}') }; } catch (e) {}
const save = () => { try { localStorage.setItem('cdLabelSettings', JSON.stringify(S)); } catch (e) {} };

/* ---------- text measurement ---------- */
const measurer = (() => {
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('width', '10'); svg.setAttribute('height', '10');
  svg.style.cssText = 'position:absolute;left:-9999px;top:0;visibility:hidden';
  const t = document.createElementNS(NS, 'text');
  t.setAttribute('font-family', FONT); t.setAttribute('font-size', '10');
  svg.appendChild(t); document.body.appendChild(svg);
  const cache = new Map();
  return (txt, size, weight = 400) => {
    const k = weight + '|' + txt;
    let w = cache.get(k);
    if (w === undefined) { t.setAttribute('font-weight', weight); t.textContent = txt; w = t.getComputedTextLength(); cache.set(k, w); }
    return w * size / 10;
  };
})();

/* ---------- geometry ---------- */
function chord(yTop, yBot, g) {
  const c = g.c;
  const dyOut = Math.max(Math.abs(yTop - c), Math.abs(yBot - c));
  if (dyOut >= g.ro) return [];
  const ho = Math.sqrt(g.ro * g.ro - dyOut * dyOut);
  const dyIn = (yTop <= c && yBot >= c) ? 0 : Math.min(Math.abs(yTop - c), Math.abs(yBot - c));
  if (dyIn >= g.rh) return [[c - ho, c + ho]];
  const hh = Math.sqrt(g.rh * g.rh - dyIn * dyIn);
  return [[c - ho, c - hh], [c + hh, c + ho]];
}

const COMPRESS = 0.80;   // max horizontal squeeze before shrinking the font

function fitLine(text, size, weight, avail, minSize, allowTruncate) {
  // returns {text,size,textLength|null} or null
  for (let s = size; s >= minSize - 1e-9; s -= 0.1) {
    const w = measurer(text, s, weight);
    if (w <= avail) return { text, size: s, tl: null };
    if (w * COMPRESS <= avail) return { text, size: s, tl: avail };
  }
  if (!allowTruncate) return null;
  let t = text;
  while (t.length > 1 && measurer(t + '…', minSize, weight) * COMPRESS > avail) t = t.slice(0, -1);
  t = t.trimEnd() + '…';
  const w = measurer(t, minSize, weight);
  return { text: t, size: minSize, tl: w > avail ? avail : null };
}

function el(name, attrs, text) {
  const e = document.createElementNS(NS, name);
  for (const k in attrs) if (attrs[k] !== null && attrs[k] !== undefined) e.setAttribute(k, attrs[k]);
  if (text !== undefined) e.textContent = text;
  return e;
}

/* ---------- header ---------- */
function buildHeader(disc, g, accent) {
  const out = [];
  const artists = [...new Set(disc.albums.map(a => a.artist))];
  const titles = disc.albums.map(a => a.title);
  const meta = disc.albums.length === 1
    ? [disc.albums[0].year, disc.albums[0].part].filter(Boolean).join('  ·  ')
    : disc.albums.map(a => a.year).filter(Boolean).join('  ·  ');

  let y = g.edge + 8.2;
  const place = (text, size, weight, fill, minSize, gapAfter, trunc = true) => {
    const ch = chord(y - size * 0.74, y + size * 0.22, g)[0];
    const avail = ch[1] - ch[0] - 2.4;
    const f = fitLine(text, size, weight, avail, minSize, trunc);
    if (!f) return false;
    out.push(el('text', { x: g.c, y, 'text-anchor': 'middle', 'font-size': f.size.toFixed(2), 'font-weight': weight, fill,
      textLength: f.tl ? f.tl.toFixed(2) : null, lengthAdjust: f.tl ? 'spacingAndGlyphs' : null }, f.text));
    y += f.size * gapAfter;
    return true;
  };

  place(artists.join('  ·  ').toUpperCase(), 4.7, 700, accent, 3.0, 1.30);

  // album title(s): wrap into at most 2 lines
  const full = titles.join('  ·  ');
  let tSize = 3.7;
  const ch1 = chord(y - tSize * 0.74, y + tSize * 0.22, g)[0];
  const avail1 = ch1[1] - ch1[0] - 2.4;
  if (measurer(full, tSize, 500) * COMPRESS <= avail1) {
    place(full, tSize, 500, '#161616', 2.8, 1.25);
  } else {
    let lines;
    if (titles.length > 1) lines = titles.map((t, i) => i < titles.length - 1 ? t + '  ·' : t);
    else {
      const words = full.split(' ');
      let best = 1, bestDiff = 1e9;
      for (let i = 1; i < words.length; i++) {
        const a = measurer(words.slice(0, i).join(' '), tSize, 500), b = measurer(words.slice(i).join(' '), tSize, 500);
        const diff = Math.max(a, b);
        if (diff < bestDiff) { bestDiff = diff; best = i; }
      }
      lines = [words.slice(0, best).join(' '), words.slice(best).join(' ')];
    }
    lines.slice(0, 2).forEach(l => place(l, tSize, 500, '#161616', 2.6, 1.18));
    y += tSize * 0.07;
  }
  place(meta, 2.65, 400, '#5d5d5d', 2.2, 0.0);
  y += 2.2;
  // short accent rule
  out.push(el('line', { x1: g.c - 7, x2: g.c + 7, y1: y - 0.9, y2: y - 0.9, stroke: accent, 'stroke-width': 0.35, 'stroke-linecap': 'round' }));
  return { nodes: out, bottom: y };
}

/* ---------- track list ---------- */
function makeItems(disc) {
  const items = [];
  const multi = disc.albums.length > 1;
  const mixedArtists = new Set(disc.albums.map(a => a.artist)).size > 1;
  disc.albums.forEach(a => {
    if (multi) {
      const pre = mixedArtists ? a.artist.toUpperCase() + ' — ' : '';
      const yr = a.year ? '  ·  ' + a.year : '';
      items.push({ kind: 'head', artist: a.artist,
        variants: [pre + a.title + yr, pre + a.title, a.title + yr, a.title] });
    }
    a.tracks.forEach(t => items.push({ kind: 'track', n: String(t.n).padStart(2, '0'), title: t.title, dur: t.dur, artist: a.artist }));
  });
  return items;
}

function buildSlots(f, yStart, yEnd, g) {
  const lh = f * 1.34;
  const groups = { top: [], left: [], right: [], bottom: [] };
  for (let top = yStart; top + lh <= yEnd + 1e-6; top += lh) {
    const iv = chord(top, top + lh, g).filter(([a, b]) => b - a >= 13);
    const base = top + f * 0.96;
    if (iv.length === 2) { groups.left.push({ x0: iv[0][0], x1: iv[0][1], y: base }); groups.right.push({ x0: iv[1][0], x1: iv[1][1], y: base }); }
    else if (iv.length === 1) {
      const slot = { x0: iv[0][0], x1: iv[0][1], y: base, full: true };
      (top + lh / 2 < g.c ? groups.top : groups.bottom).push(slot);
    }
  }
  return groups;
}

// try to lay items into a sequence of slot-columns; returns array of draw ops or null
function layColumns(items, columns, f, allowTrunc) {
  const ops = [];
  const pad = 0.9;
  const numW = measurer('00', f, 700) + f * 0.42;
  let ci = 0, si = 0;
  const next = () => {
    while (ci < columns.length && si >= columns[ci].length) { ci++; si = 0; }
    if (ci >= columns.length) return null;
    return { slot: columns[ci][si++], col: ci, idx: si - 1 };
  };
  for (const it of items) {
    const p = next(); if (!p) return null;
    const { slot } = p;
    const x0 = slot.x0 + pad, x1 = slot.x1 - pad;
    if (it.kind === 'head') {
      let fl = null;
      for (const v of it.variants) { fl = fitLine(v, f * 0.92, 700, x1 - x0, f * 0.92 * 0.85, false); if (fl) break; }
      if (!fl) fl = fitLine(it.variants[it.variants.length - 1], f * 0.92, 700, x1 - x0, f * 0.92 * 0.85, true);
      if (slot.full) ops.push({ t: 'head', x: (x0 + x1) / 2, anchor: 'middle', y: slot.y, ...fl, artist: it.artist });
      else ops.push({ t: 'head', x: x0, y: slot.y, ...fl, artist: it.artist });
      continue;
    }
    const ds = f * 0.86;
    const durW = measurer(it.dur, ds, 400) + f * 0.45;
    const tx = x0 + numW;
    const avail = x1 - durW - tx;
    const w = measurer(it.title, f, 400);
    if (w * COMPRESS <= avail && slot.full) {
      // full-width band: centre the row instead of spreading it edge to edge
      const tw = Math.min(w, avail), cw = numW + tw + f * 1.1 + durW;
      const nx = (x0 + x1) / 2 - cw / 2;
      ops.push({ t: 'num', x: nx, y: slot.y, text: it.n, size: f, artist: it.artist });
      ops.push({ t: 'title', x: nx + numW, y: slot.y, text: it.title, size: f, tl: w > avail ? avail : null });
      ops.push({ t: 'dur', x: nx + cw, y: slot.y, text: it.dur, size: ds });
      continue;
    }
    ops.push({ t: 'num', x: x0, y: slot.y, text: it.n, size: f, artist: it.artist });
    if (w * COMPRESS <= avail) {
      ops.push({ t: 'title', x: tx, y: slot.y, text: it.title, size: f, tl: w > avail ? avail : null });
      ops.push({ t: 'dur', x: x1, y: slot.y, text: it.dur, size: ds });
      continue;
    }
    // wrap over up to 3 consecutive slots of the same column; duration goes on the last line
    const col = columns[ci], first = si - 1, words = it.title.split(' ');
    const lines = [];
    let wi = 0;
    for (let li = 0; li < 3 && wi < words.length; li++) {
      const sl = col[first + li]; if (!sl) break;
      const lx0 = sl.x0 + pad + numW, lx1 = sl.x1 - pad;
      const rest = words.slice(wi).join(' '), wr = measurer(rest, f, 400), withDur = lx1 - durW - lx0;
      if (wr * COMPRESS <= withDur) { lines.push({ sl, x: lx0, text: rest, w: wr, avail: withDur, end: lx1 }); wi = words.length; break; }
      let cut = wi;
      for (let i = wi + 1; i <= words.length; i++) {
        if (measurer(words.slice(wi, i).join(' '), f, 400) * COMPRESS <= lx1 - lx0) cut = i; else break;
      }
      if (cut === words.length) cut--;            // leave a word for the line that carries the duration
      if (cut <= wi) break;
      const tx = words.slice(wi, cut).join(' ');
      lines.push({ sl, x: lx0, text: tx, w: measurer(tx, f, 400), avail: lx1 - lx0, end: lx1 });
      wi = cut;
    }
    if (wi === words.length && lines.length) {
      si = first + lines.length;
      lines.forEach(l => ops.push({ t: 'title', x: l.x, y: l.sl.y, text: l.text, size: f, tl: l.w > l.avail ? l.avail : null }));
      const last = lines[lines.length - 1];
      ops.push({ t: 'dur', x: last.end, y: last.sl.y, text: it.dur, size: ds });
      continue;
    }
    if (!allowTrunc) return null;
    const fl = fitLine(it.title, f, 400, avail, f, true);
    ops.push({ t: 'title', x: tx, y: slot.y, text: fl.text, size: f, tl: fl.tl });
    ops.push({ t: 'dur', x: x1, y: slot.y, text: it.dur, size: ds });
  }
  return ops;
}

function centerColumn(col, used) {
  // shift used rows to the vertical middle of the column
  const off = Math.floor((col.length - used) / 2);
  return col.slice(off);
}

function layoutTracks(items, yStart, yEnd, g) {
  // three strategies, each searched for the largest font that fits:
  //   A = two columns beside the hole, balanced and vertically centred (preferred look)
  //   B = left column, right column, then the band below the hole
  //   C = band above the hole, left, right, then below
  const sizes = [];
  for (let f = 3.4; f >= 1.8 - 1e-9; f -= 0.05) sizes.push(+f.toFixed(2));
  const tryA = (f, G) => {
    let k = Math.ceil(items.length / 2);
    if (items[k - 1] && items[k - 1].kind === 'head') k--;
    const L = items.slice(0, k), R = items.slice(k);
    const rows = (arr, col) => { const ops = layColumns(arr, [col], f, false); return ops ? new Set(ops.map(o => o.y)).size : null; };
    const nl = rows(L, G.left), nr = rows(R, G.right);
    if (nl === null || nr === null) return null;
    const n = Math.max(nl, nr);
    const a = layColumns(L, [centerColumn(G.left, n)], f, false), b = layColumns(R, [centerColumn(G.right, n)], f, false);
    return a && b ? a.concat(b) : null;
  };
  const strategies = [
    tryA,
    (f, G) => layColumns(items, [G.left, G.right, G.bottom], f, false),
    (f, G) => layColumns(items, [G.top, G.left, G.right, G.bottom], f, false),
  ];
  const best = strategies.map(fn => {
    for (const f of sizes) { const ops = fn(f, buildSlots(f, yStart, yEnd, g)); if (ops) return { ops, f }; }
    return null;
  });
  const [A, B, C] = best;
  const top = Math.max(...best.filter(Boolean).map(b => b.f), 0);
  if (A && A.f >= top * 0.86) return A;
  if (B && B.f >= top * 0.92) return B;
  if (C) return C;
  const f = 1.8, G = buildSlots(f, yStart, yEnd, g);
  return { ops: layColumns(items, [G.top, G.left, G.right, G.bottom], f, true) || [], f };
}

/* ---------- label ---------- */
function renderLabel(disc) {
  const D = +S.outer, holeR = +S.hole / 2;
  const g = { c: D / 2, ro: D / 2 - 3.6, rh: holeR + 2.4, edge: 3.6 };
  const accent = S.color ? artistColor(disc.albums[0].artist) : '#161616';
  const svg = el('svg', { xmlns: NS, viewBox: `0 0 ${D} ${D}`, width: D + 'mm', height: D + 'mm', class: 'label',
    'font-family': FONT, 'text-rendering': 'geometricPrecision' });

  // background + accents
  svg.appendChild(el('circle', { cx: g.c, cy: g.c, r: D / 2, fill: '#fff' }));
  if (S.color) {
    svg.appendChild(el('circle', { cx: g.c, cy: g.c, r: D / 2 - 1.5, fill: 'none', stroke: accent, 'stroke-width': 0.9 }));
    svg.appendChild(el('circle', { cx: g.c, cy: g.c, r: holeR + 1.1, fill: 'none', stroke: accent, 'stroke-width': 0.5 }));
  }
  if (S.guides) {
    svg.appendChild(el('circle', { cx: g.c, cy: g.c, r: D / 2 - 0.05, fill: 'none', stroke: '#9a9a9a', 'stroke-width': 0.12, 'stroke-dasharray': '1.2 0.8' }));
    svg.appendChild(el('circle', { cx: g.c, cy: g.c, r: holeR, fill: 'none', stroke: '#9a9a9a', 'stroke-width': 0.12, 'stroke-dasharray': '1.2 0.8' }));
  }

  const head = buildHeader(disc, g, accent);
  head.nodes.forEach(n => svg.appendChild(n));

  // footer
  const fy = D - g.edge - 3.0;
  svg.appendChild(el('text', { x: g.c, y: fy, 'text-anchor': 'middle', 'font-size': 2.5, fill: '#5d5d5d', 'font-weight': 400 },
    `CD ${String(disc.number).padStart(2, '0')} / ${disc.total}  ·  ${disc.duration}`));

  const items = makeItems(disc);
  const { ops } = layoutTracks(items, head.bottom + 0.4, fy - 3.0, g);
  for (const o of ops) {
    const common = { y: o.y.toFixed(2), 'font-size': o.size.toFixed(2) };
    if (o.t === 'num') svg.appendChild(el('text', { ...common, x: o.x.toFixed(2), 'font-weight': 700, fill: S.color ? artistColor(o.artist) : '#161616' }, o.text));
    else if (o.t === 'head') svg.appendChild(el('text', { ...common, x: o.x.toFixed(2), 'text-anchor': o.anchor || null, 'font-weight': 700, fill: S.color ? artistColor(o.artist) : '#161616',
      textLength: o.tl ? o.tl.toFixed(2) : null, lengthAdjust: o.tl ? 'spacingAndGlyphs' : null }, o.text));
    else if (o.t === 'title') svg.appendChild(el('text', { ...common, x: o.x.toFixed(2), fill: '#161616',
      textLength: o.tl ? o.tl.toFixed(2) : null, lengthAdjust: o.tl ? 'spacingAndGlyphs' : null }, o.text));
    else if (o.t === 'dur') svg.appendChild(el('text', { ...common, x: o.x.toFixed(2), 'text-anchor': 'end', fill: '#5d5d5d', 'font-variant-numeric': 'tabular-nums' }, o.text));
  }
  return svg;
}

/* ---------- pages ---------- */
function render() {
  document.getElementById('page-size').textContent = `@page { size: ${S.paper}; margin: 0; }`;
  const [W, H] = S.paper === 'Letter' ? [215.9, 279.4] : [210, 297];
  const host = document.getElementById('pages');
  host.innerHTML = '';
  const chosen = DISCS.filter(d => S.selected.includes(d.id));
  if (!chosen.length) { host.innerHTML = '<div class="empty">No discs selected.</div>'; return; }
  const D = +S.outer;
  for (let i = 0; i < chosen.length; i += 2) {
    const page = document.createElement('div');
    page.className = 'page';
    page.style.width = W + 'mm'; page.style.height = H + 'mm';
    chosen.slice(i, i + 2).forEach((d, j) => {
      const svg = renderLabel(d);
      const cx = W / 2 + (+S.nx), cy = (j === 0 ? H / 4 : 3 * H / 4) + (+S.ny);
      svg.style.left = (cx - D / 2) + 'mm';
      svg.style.top = (cy - D / 2) + 'mm';
      page.appendChild(svg);
    });
    host.appendChild(page);
  }
}

function initControls() {
  const list = document.getElementById('disc-list');
  DISCS.forEach(d => {
    const lab = document.createElement('label');
    const cb = document.createElement('input');
    cb.type = 'checkbox'; cb.checked = S.selected.includes(d.id);
    cb.addEventListener('change', () => {
      S.selected = DISCS.map(x => x.id).filter(id => id === d.id ? cb.checked : S.selected.includes(id));
      save(); render();
    });
    const name = d.albums.map(a => `${a.artist} – ${a.title}` + (a.part ? ` (${a.part.split(' · ')[0]})` : '')).join(' + ');
    lab.title = name;
    lab.append(cb, Object.assign(document.createElement('b'), { textContent: String(d.number).padStart(2, '0') }), document.createTextNode(' ' + name));
    list.appendChild(lab);
  });
  const setAll = v => { S.selected = v ? DISCS.map(d => d.id) : []; list.querySelectorAll('input').forEach(c => c.checked = v); save(); render(); };
  document.getElementById('all').onclick = () => setAll(true);
  document.getElementById('none').onclick = () => setAll(false);
  for (const k of ['paper', 'outer', 'hole', 'nx', 'ny']) {
    const e = document.getElementById(k); e.value = S[k];
    e.addEventListener('change', () => { S[k] = e.value; save(); render(); });
  }
  for (const k of ['guides', 'color']) {
    const e = document.getElementById(k); e.checked = S[k];
    e.addEventListener('change', () => { S[k] = e.checked; save(); render(); });
  }
  document.getElementById('print').onclick = () => window.print();
}

// optional: labels.html#CD03,CD07 shows only those discs (not saved)
const hashSel = decodeURIComponent(location.hash.slice(1)).split(',').filter(x => DISCS.some(d => d.id === x));
if (hashSel.length) S.selected = hashSel;
initControls();
if (hashSel.length) document.querySelector('.controls').style.display = 'none';
(document.fonts && document.fonts.ready ? document.fonts.ready : Promise.resolve()).then(render);
</script>
</body>
</html>
'''

if __name__ == "__main__":
    main()
