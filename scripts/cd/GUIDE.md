# 💿 cdburn - music folders → gapless, bit-perfect Audio CDs

Pick any folders of music (FLAC, hi-res, WAV, ALAC, MP3…). `cdburn` finds the albums, decides which go on which CD, makes the best possible 16-bit/44.1 kHz image of each, burns it, checks the burned copy is bit-identical, and prints labels.

## Setup (one time)

**Linux (Arch)**
```bash
sudo pacman -S --needed python ffmpeg cdrdao cdparanoia   # apt/dnf: same package names
~/dev/scripts/cd/cdburn.py install                         # adds the 'cdburn' command (~/.local/bin)
```

**Windows**
```powershell
winget install Python.Python.3.12 Gyan.FFmpeg LIGHTNINGUK.ImgBurn
.\cdburn.cmd install        # adds 'cdburn' to your PATH (WindowsApps folder)
```

The **Burner → Install** menu shows (and can run) the right command for what's missing.

**USB burner:** plug it straight into the computer, not into a hub. If it has a Y-cable, plug in both ends. Slim drives are bus-powered, and a power dip ruins the disc.

## Basic usage

```bash
cdburn            # menus: j/k move · enter/l open · space tick · h/esc back · q quit
```

The first run asks for your music folder(s) and a project folder (default `<music>/_CD_Burning`). After that:

1. **Albums** (`a`): check what was found. Untick albums or single tracks, and fix artist, title or year.
2. **Plan** (`p`): CDs are planned automatically. Use `enter` on a CD to move or combine albums, `J`/`K` to reorder, and `r` to re-plan.
3. **Build** (`b`): makes the images (several CDs in parallel).
4. **Burn** (`w`): the first time, it offers a simulation first (laser off). Afterwards it offers to verify.
5. **Labels** (`i`): opens `labels.html`. Tick the CDs you want, then print at **100% / no margins**. You get 2 labels per A4 sheet (117 mm label, 41 mm hole, adjustable).
6. **Clean up** (`x`): delete images of CDs you've already burned (about 0.4–0.85 GB each).

The menus remember everything. A CD whose albums or settings changed shows **outdated** and is rebuilt.

## What gets found

| In your folders | Becomes |
|---|---|
| a folder with audio files | one album |
| `Album/CD 1`, `Album/Disc 02`, … | one album with natural split points |
| one folder with disc tags 1, 2, … | same |
| one big `.flac` + `.cue` | one album, tracks from the CUE |
| different track artists, no album artist | *Various Artists* (artist shown per track) |
| the same album twice (e.g. MP3 and FLAC) | the best copy is used and the other is skipped |

Artist, title and year come from the tags, then from the folder name. Remaster and edition notes such as "(2017 Remastered)" or "(Deluxe Edition)" are dropped from album titles. Track titles also lose "(2019 Mix)"-style notes; you can turn that off in Settings.

## How CDs are planned

- An 80-minute CD-R is used up to **79:30** (a 30 s margin). Only playing time matters, not file size.
- **Too long for one CD:** the album is split at its own disc boundaries when that doesn't cost an extra CD. Otherwise it's split by tracks into balanced halves.
- **Short albums share a CD** when they fit. Same artist first, then the closest release year (Settings: *any / same artist / never*, and the max albums per CD).
- There are 2 s of silence between albums. Inside an album nothing is added.
- Tracks shorter than 4 s (the CD minimum) are joined to the next track.

## Quality

- 16-bit/44.1 kHz lossless sources are copied **bit for bit**.
- Everything else is decoded to float and resampled with **SoX VHQ** (libsoxr), then dithered to 16 bit **once** (TPDF). If, and only if, peaks would clip, one small constant gain is applied to the whole album; the result is reported.
- Each album is processed as one stream, so gapless albums stay gapless.
- Burning is Disc-At-Once with CD-Text (names on the car display). **16x** is the default, the sweet spot for 52x-rated CD-R.
- **Verify** reads the CD back (cdparanoia), finds the drive offset by itself, and compares every sample.
- Lossy sources (MP3, AAC…) are flagged in yellow. They burn fine but can't be lossless.

## Command line

```bash
cdburn new ~/Music/albums [-p ~/Music/albums/_CD_Burning]
cdburn status                 # plan + state of every CD
cdburn scan | plan
cdburn build CD01 CD02 | all [-j 4]
cdburn burn CD05 [--simulate] [--speed 16] [--device /dev/sr0]
cdburn verify CD05            # Windows: --readback rip.wav (whole-disc WAV, e.g. from EAC)
cdburn labels
```

`-p DIR` picks a project. Without it, cdburn uses the current folder if it's a project, otherwise the last project you used.

## Files

| Where | What |
|---|---|
| `<project>/cdburn.json` | albums, your edits, the plan, the state of each CD |
| `<project>/build/CDxx_…/` | `disc.wav` + `disc.toc` (cdrdao) + `disc.cue` (ImgBurn/K3b) + `info.txt` |
| `<project>/labels.html`, `tracklists.txt` | labels and plain-text track lists |
| `~/.config/cdburn/config.json` (`%APPDATA%\cdburn` on Windows) | burner, speed, recent projects |

## Troubleshooting

| Problem | Fix |
|---|---|
| No names on the car display | Not every car reads CD-Text. If yours does: **Burner → Driver → generic-mmc-raw** and burn again. |
| Burn fails or the drive disconnects | Use a rear USB port and the Y-cable, without a hub. Try a lower speed (Burner → Speed). |
| Verify reports differences | Read it again first. If it persists, re-burn at 8x or use another disc batch. |
| Wrong year or artist (affects order and pairing) | **Albums** → `enter` → `y`/`a`, then **Plan** → `r` |
| Permission denied on `/dev/sr0` | `sudo usermod -aG optical $USER`, then log out and back in. |
| Stick-on labels in a slot-loading car player | Apply them perfectly centred, with no bubbles. A peeling label can jam the player in summer heat. |
