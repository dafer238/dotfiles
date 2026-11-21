# pacman Quick Reference

> How the flags fit together: **`-S`** = sync (remote repos), **`-Q`** = query (local, installed),
> **`-R`** = remove, **`-U`** = install a local package file, **`-F`** = search which package holds a file.
> Lowercase modifiers stack on top: `s` = search, `i` = info, `y` = refresh database, `u` = upgrade.
> Anything that changes the system needs `sudo`. Queries don't.

---

## Update the system
| Command | What it does |
|---|---|
| `sudo pacman -Syu` | Refresh package databases **and** upgrade everything. Run this regularly. |
| `sudo pacman -Syyu` | Same, but forces the database refresh (useful after changing mirrors). |
| `checkupdates` | Lists pending updates without touching the system (*pacman-contrib*). |

⚠️ **Never run `sudo pacman -Sy <pkg>`.** It refreshes the database without upgrading, so the new
package is built against libraries you don't have yet (a "partial upgrade"), which can break things.
Use `-Syu <pkg>` or plain `-S <pkg>` instead.

## Search
| Command | What it does |
|---|---|
| `pacman -Ss <term>` | Search the **repositories** (names + descriptions; regex works). |
| `pacman -Si <pkg>` | Details of a repo package (version, deps, size). |
| `pacman -Qs <term>` | Search **installed** packages. |
| `pacman -Qi <pkg>` | Details of an installed package (install date, reason, what requires it). |
| `pacman -Q` | List all installed packages. |
| `pacman -Qe` | List packages **you** installed explicitly. |
| `pacman -Qm` | List "foreign" packages (not from the repos, e.g. AUR). |
| `pacman -Qdt` | List **orphans** (installed as deps, no longer needed). |

## Install
| Command | What it does |
|---|---|
| `sudo pacman -S <pkg>` | Install a package (and its dependencies). |
| `sudo pacman -S <pkg1> <pkg2>` | Install several at once. |
| `sudo pacman -S --needed <pkg>` | Skip packages that are already up to date. |
| `sudo pacman -U ./file.pkg.tar.zst` | Install a local package file. |
| `sudo pacman -Sw <pkg>` | Download only, don't install. |

## Remove
| Command | What it does |
|---|---|
| `sudo pacman -R <pkg>` | Remove the package only; its dependencies stay. |
| `sudo pacman -Rs <pkg>` | Remove the package **and** its dependencies that nothing else needs. |
| `sudo pacman -Rns <pkg>` | Same as `-Rs`, and also skips `.pacsave` backups of its config files. **Usual choice.** |
| `sudo pacman -Rns $(pacman -Qdtq)` | Remove all orphans. (`-q` prints names only.) |
| `sudo pacman -Rsc <pkg>` | ⚠️ Also removes packages that **depend on** `<pkg>`. Read the list before you confirm. |

## Files & ownership
| Command | What it does |
|---|---|
| `pacman -Ql <pkg>` | List the files an installed package owns. |
| `pacman -Qo /path/to/file` | Which installed package owns this file? |
| `sudo pacman -Fy` | Refresh the file database (do this once before using `-F`). |
| `pacman -F <filename>` | Which repo package provides this file? (e.g. `pacman -F ifconfig`) |

## Cache cleanup
Downloaded packages pile up in `/var/cache/pacman/pkg/`.

| Command | What it does |
|---|---|
| `sudo paccache -r` | Keep the last 3 versions of each package, delete the rest (*pacman-contrib*). |
| `sudo paccache -rk1` | Keep only 1 version. |
| `sudo pacman -Sc` | Remove cached versions of packages that are no longer installed. |
| `sudo pacman -Scc` | ⚠️ Empty the whole cache. You lose the ability to downgrade offline. |

## Install reason
| Command | What it does |
|---|---|
| `sudo pacman -D --asexplicit <pkg>` | Mark as explicitly installed, so it won't show up as an orphan. |
| `sudo pacman -D --asdeps <pkg>` | Mark as a dependency, so it gets cleaned up once unneeded. |

## Troubleshooting
| Command / file | Use |
|---|---|
| `less /var/log/pacman.log` | History of everything installed, upgraded or removed. |
| `pacman -Qkk <pkg>` | Check an installed package's files for changes or missing files. |
| `sudo rm /var/lib/pacman/db.lck` | Clears a stale lock. **Only** if no pacman is running. |
| `sudo pacman -Sy archlinux-keyring && sudo pacman -Su` | Fixes "invalid or corrupted package (PGP signature)" errors. |
| `/etc/pacman.conf` | Uncomment `Color` and `ParallelDownloads = 5` for color and faster downloads. |

---

### Extras worth knowing
- **pacman-contrib**: `sudo pacman -S pacman-contrib` gives you `paccache` and `checkupdates`.
  `sudo systemctl enable --now paccache.timer` cleans the cache weekly.
- **AUR**: pacman can't install AUR packages. Use a helper like `yay` or `paru`. They accept the same
  flags (`yay -Syu`, `yay -Ss <term>`).
- **Before a big update**, check https://archlinux.org/news/ for manual steps.
- **Docs**: `man pacman`, or https://wiki.archlinux.org/title/Pacman
