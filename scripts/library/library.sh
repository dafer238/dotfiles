#!/usr/bin/env bash
# library.sh - interactive Google Drive <-> local library sync (books, papers, sioyek and KOReader annotations)
#
#   library               interactive menu (vim keys: j/k move, enter/l open, h/esc back, q quit)
#   library status        print sync status and exit
#   library pull|push|merge [-y] [--force]
#   library setup         re-run first-time setup
#   library uninstall     remove the tool from this device (asks before touching your files)
#
# Everything is driven by rclone. Per-device settings live in
# ${XDG_CONFIG_HOME:-~/.config}/library-sync/ (never synced).

set -uo pipefail

VERSION=1.3.0
SELF=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
CFG_DIR=${LIBRARY_SYNC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/library-sync}
CFG_FILE=$CFG_DIR/config
STATE_FILE=$CFG_DIR/state
FILTER_FILE=$CFG_DIR/filters.rclone
MANIFEST_FILE=$CFG_DIR/manifest
ANNOT_DIR=sioyek
KO_DIR=koreader
KO_STATE=$CFG_DIR/koreader-state
MARKER_DIR=.library-sync
COMMON_EXTS=(pdf epub djvu mobi azw3 cbz cbr fb2 txt md)
MIN_RCLONE_MINOR=60
TERMUX=0
[[ -n ${TERMUX_VERSION:-} || ${PREFIX:-} == */com.termux/* ]] && TERMUX=1
HOST=$(uname -n 2>/dev/null)
# Every Android device calls itself "localhost"; use the model name instead.
((TERMUX)) && have_getprop=$(getprop ro.product.model 2>/dev/null) && [[ -n $have_getprop ]] && HOST=$have_getprop
HOST=${HOST//[^A-Za-z0-9._-]/_}; HOST=${HOST:-unknown}
unset have_getprop
export RCLONE_ASK_PASSWORD=false

umask 077

# ---------------------------------------------------------------- defaults --
LIBRARY_ROOT=$HOME/library
# On Android the library must be in shared storage so reader apps can open the books:
# Documents/library in internal storage (/storage/emulated/0/Documents/library).
termux_root() { printf '%s/Documents/library' "$(readlink -f -- "$HOME/storage/shared")"; }
((TERMUX)) && [[ -d $HOME/storage/shared ]] && LIBRARY_ROOT=$(termux_root)
CHECKSUM=  # 1 = this filesystem can't keep modification times: compare by MD5 (see checksum_mode)
REMOTE=gdrive
REMOTE_PATH=library
REMOTE_TRASH=library-trash
FOLDERS=(content "$ANNOT_DIR")
FILTER_MODE=none
FILTER_EXT=()
TRANSFERS=4
CHECKERS=8
TPSLIMIT=10
BWLIMIT=
SIOYEK_ASKED=0
KOREADER_DIR=
KO_CONFLICT=newer
KO_POLICY=newer KO_ALL=
LAST_PULL= LAST_PUSH= LAST_MERGE=
DIFF_READY=0
REMOTE_MISSING=0
declare -A CNT=() MENU_POS=() DIRCACHE=() KS_LIVE=() KS_STAGE=() KS_MARK=()
LIST_DIR= LIST_AT=0 LIST_SIG=
LIST_PIDS=()

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  TTY=1
  C0=$'\e[0m' CB=$'\e[1m' CD=$'\e[2m' CR=$'\e[31m' CG=$'\e[32m' CY=$'\e[33m'
  CBL=$'\e[34m' CM=$'\e[35m' CC=$'\e[36m' CRV=$'\e[7m'
else
  TTY=0 C0= CB= CD= CR= CG= CY= CBL= CM= CC= CRV=
fi

CAT_KEYS=(changes radd rnew ladd lnew ren size same)
declare -A CAT_LABEL=([changes]="All changes" [radd]="New on remote" [rnew]="Newer on remote"
  [ladd]="New locally" [lnew]="Newer locally" [ren]="Renamed" [size]="Conflicts" [same]="In sync")
declare -A CAT_SYM=([radd]="↓+" [rnew]="↓~" [ladd]="↑+" [lnew]="↑~" [ren]=" »" [size]="!≠" [same]=" =")
declare -A CAT_COL=([radd]=$CG [rnew]=$CC [ladd]=$CY [lnew]=$CM [ren]=$CBL [size]=$CR [same]=$CD)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/library.XXXXXX") || exit 1
cleanup() { ((TTY)) && printf '\e[?25h'; rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- helpers --
say()  { printf '%s\n' "$*"; }
info() { printf '%s::%s %s\n' "$CBL" "$C0" "$*"; }
ok()   { printf '%s✔%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '%s!%s %s\n' "$CY" "$C0" "$*" >&2; }
err()  { printf '%s✘%s %s\n' "$CR" "$C0" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
cls()  { ((TTY)) && printf '\e[H\e[2J\e[3J'; }
# frame TEXT: redraw in place (home, overwrite each line, clear the rest) - no flicker.
frame() { local b=${1//$'\n'/$'\e[K\n'}; printf '\e[H%s\e[K\e[J' "$b"; }
cursor() { ((TTY)) && { [[ $1 == on ]] && printf '\e[?25h' || printf '\e[?25l'; }; }
tildify() { [[ $1 == "$HOME"* ]] && printf '~%s' "${1#"$HOME"}" || printf '%s' "$1"; }
now_iso() { date -Iseconds; }

term_size() {
  local s; s=$(stty size 2>/dev/null) || s=
  TH=${s%% *} TW=${s##* }
  [[ $TH =~ ^[0-9]+$ ]] || TH=24
  [[ $TW =~ ^[0-9]+$ ]] || TW=80
}

# hs VAR BYTES  -> human readable size into VAR
hs() {
  local -n _out=$1; local _b=$2 _i=0 _x _u=(B KB MB GB TB)
  [[ $_b =~ ^[0-9]+$ ]] || { _out=-; return; }
  if ((_b < 1024)); then _out="${_b}B"; return; fi
  _x=$((_b * 10))
  while ((_x >= 10240 && _i < 4)); do _x=$((_x / 1024)); ((_i++)); done
  _out="$((_x / 10)).$((_x % 10))${_u[_i]}"
}

# ago ISO -> "2026-10-21 18:03 (5h ago)" | "never"
ago() {
  local t now d rel
  [[ -z ${1:-} || $1 == - ]] && { printf 'never'; return; }
  t=$(date -d "$1" +%s 2>/dev/null) || { printf '%s' "$1"; return; }
  printf -v now '%(%s)T' -1; d=$((now - t))
  if ((d < 60)); then rel='just now'
  elif ((d < 3600)); then rel="$((d / 60))m ago"
  elif ((d < 86400)); then rel="$((d / 3600))h ago"
  else rel="$((d / 86400))d ago"; fi
  printf '%s (%s)' "$(date -d "@$t" '+%Y-%m-%d %H:%M')" "$rel"
}

epoch() { [[ -n ${1:-} && $1 != - ]] && date -d "$1" +%s 2>/dev/null || echo 0; }

# read_key -> KEY (normalised: j k h l g G enter esc space tab btab bs ctrl-d ctrl-u or the char)
read_key() {
  local k r
  IFS= read -rsn1 k || { KEY=q; return; }
  case $k in
    $'\e')
      IFS= read -rsn1 -t 0.03 r || { KEY=esc; return; }
      if [[ $r == '[' || $r == O ]]; then
        IFS= read -rsn1 -t 0.03 k
        case $k in
          A) KEY=k ;; B) KEY=j ;; C) KEY=l ;; D) KEY=h ;; H) KEY=g ;; F) KEY=G ;; Z) KEY=btab ;;
          5) IFS= read -rsn1 -t 0.03 r; KEY=ctrl-u ;;
          6) IFS= read -rsn1 -t 0.03 r; KEY=ctrl-d ;;
          *) KEY=none ;;
        esac
      else KEY=esc; fi ;;
    '') KEY=enter ;;
    ' ') KEY=space ;;
    $'\t') KEY=tab ;;
    $'\x7f' | $'\b') KEY=bs ;;
    $'\x04') KEY=ctrl-d ;;
    $'\x15') KEY=ctrl-u ;;
    *) KEY=$k ;;
  esac
}

pause() { printf '\n%spress any key…%s' "$CD" "$C0"; read_key; }

# yesno QUESTION [y|n]   (returns 0 for yes)
yesno() {
  local def=${2:-n} hint='[y/N]'; [[ $def == y ]] && hint='[Y/n]'
  printf '%s %s%s%s ' "$1" "$CD" "$hint" "$C0"
  while :; do
    read_key
    case $KEY in
      y | Y) say y; return 0 ;;
      n | N | q | esc) say n; return 1 ;;
      enter) say "$def"; [[ $def == y ]]; return ;;
    esac
  done
}

# ask PROMPT [DEFAULT] -> REPLY (readline editing)
ask() { cursor on; IFS= read -e -r -p "$1" -i "${2:-}" REPLY; cursor off; }

# logs/ and .trash/ are per-device: never selectable as a synced folder.
sync_folder_ok() { local t=${1%%/*}; t=${t,,}; [[ $t != logs && $t != .trash ]]; }

valid_relpath() {
  local p=$1
  [[ $p != /* && $p != */ && $p != *\\* && $p != *:* && $p != *$'\n'* && /$p/ != */../* && /$p/ != */./* ]]
}

glob_escape() {
  local s=$1 o= c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in '\' | '*' | '?' | '[' | ']' | '{' | '}') o+="\\$c" ;; *) o+=$c ;; esac
  done
  printf '%s' "$o"
}

rpath() { local p=$REMOTE_PATH; [[ -n ${1:-} ]] && p=${p:+$p/}$1; printf '%s:%s' "$REMOTE" "$p"; }

# ----------------------------------------------------------------- config --
apply_kv() {
  local k=$1 v=$2 f; local -a a
  case $k in
    LIBRARY_ROOT) [[ $v == /* ]] && LIBRARY_ROOT=$v ;;
    REMOTE) [[ $v =~ ^[A-Za-z0-9_.][A-Za-z0-9_.\ -]*$ ]] && REMOTE=$v ;;
    REMOTE_PATH) valid_relpath "$v" && REMOTE_PATH=$v ;;
    REMOTE_TRASH) [[ -n $v ]] && valid_relpath "$v" && REMOTE_TRASH=$v ;;
    FOLDERS)
      FOLDERS=(); IFS='|' read -r -a a <<<"$v"
      for f in "${a[@]}"; do [[ -n $f ]] && valid_relpath "$f" && sync_folder_ok "$f" && FOLDERS+=("$f"); done ;;
    FILTER_MODE) [[ $v =~ ^(none|exclude|include)$ ]] && FILTER_MODE=$v ;;
    FILTER_EXT)
      FILTER_EXT=(); read -r -a a <<<"$v"
      for f in "${a[@]}"; do [[ $f =~ ^[A-Za-z0-9]{1,10}$ ]] && FILTER_EXT+=("${f,,}"); done ;;
    TRANSFERS | CHECKERS | TPSLIMIT) [[ $v =~ ^[0-9]{1,3}$ ]] && printf -v "$k" '%s' "$v" ;;
    BWLIMIT) [[ $v =~ ^[0-9A-Za-z.:,\ -]*$ ]] && BWLIMIT=$v ;;
    SIOYEK_ASKED) [[ $v == 1 ]] && SIOYEK_ASKED=1 ;;
    KOREADER_DIR) [[ -z $v || $v == /* ]] && KOREADER_DIR=$v ;;
    KO_CONFLICT) [[ $v =~ ^(newer|local|remote|ask)$ ]] && KO_CONFLICT=$v ;;
    LAST_PULL | LAST_PUSH | LAST_MERGE) [[ $v =~ ^[0-9T:+.-]*$ ]] && printf -v "$k" '%s' "$v" ;;
  esac
}

# Parsed line by line with an allow-list - the file is never sourced.
load_kv() {
  local k v
  [[ -f $1 ]] || return 1
  while IFS='=' read -r k v || [[ -n $k ]]; do
    v=${v%$'\r'}
    [[ -z $k || $k == \#* ]] && continue
    apply_kv "$k" "$v"
  done <"$1"
  return 0  # the file exists; don't leak the status of the last apply_kv (e.g. SIOYEK_ASKED=0)
}

write_atomic() { # FILE  (content on stdin)
  mkdir -p -- "$(dirname -- "$1")" || return 1
  cat >"$1.tmp.$$" && mv -f -- "$1.tmp.$$" "$1"
}

save_config() {
  local folders exts
  folders=$(IFS='|'; printf '%s' "${FOLDERS[*]}")
  exts=$(IFS=' '; printf '%s' "${FILTER_EXT[*]}")
  write_atomic "$CFG_FILE" <<EOF
# library.sh per-device config - edit through the menu
LIBRARY_ROOT=$LIBRARY_ROOT
REMOTE=$REMOTE
REMOTE_PATH=$REMOTE_PATH
REMOTE_TRASH=$REMOTE_TRASH
FOLDERS=$folders
FILTER_MODE=$FILTER_MODE
FILTER_EXT=$exts
TRANSFERS=$TRANSFERS
CHECKERS=$CHECKERS
TPSLIMIT=$TPSLIMIT
BWLIMIT=$BWLIMIT
SIOYEK_ASKED=$SIOYEK_ASKED
KOREADER_DIR=$KOREADER_DIR
KO_CONFLICT=$KO_CONFLICT
EOF
}

save_state() {
  write_atomic "$STATE_FILE" <<EOF
LAST_PULL=$LAST_PULL
LAST_PUSH=$LAST_PUSH
LAST_MERGE=$LAST_MERGE
EOF
}

filter_desc() {
  local e; e=$(IFS=','; printf '%s' "${FILTER_EXT[*]}"); e=${e//,/, }
  if [[ $FILTER_MODE == none || ${#FILTER_EXT[@]} -eq 0 ]]; then printf 'all file types'
  elif [[ $FILTER_MODE == exclude ]]; then printf 'excluding %s' "$e"
  else printf 'only %s' "$e"; fi
}

folders_desc() { local s; s=$(IFS='|'; printf '%s' "${FOLDERS[*]}"); printf '%s' "${s//|/, }"; }

# ---------------------------------------------------------------- rclone --
base_flags() {
  BASE=(--drive-skip-gdocs --tpslimit "$TPSLIMIT" --checkers "$CHECKERS"
    --contimeout 20s --timeout 5m --retries 3 --low-level-retries 10)
}

# One filter file selects the synced folders and applies the per-device type filter.
# rclone uses first-match-wins, which gives "folder AND type" semantics.
build_filters() {
  local f ef e use_types=1
  ((${#FOLDERS[@]})) || { err "No folders selected. Use 'Folders' to pick some."; return 1; }
  [[ $FILTER_MODE == none || ${#FILTER_EXT[@]} -eq 0 ]] && use_types=0
  {
    say "# generated by library.sh - do not edit (rebuilt before every run)"
    say "- /.trash/**"
    say "- /logs/**"
    printf '%s\n' '- desktop.ini' '- Thumbs.db' '- .DS_Store' '- ~$*' '- .~lock.*#' '- *.partial'
    for f in "${FOLDERS[@]}"; do
      ef=$(glob_escape "$f")
      if [[ $f == "$ANNOT_DIR" || $f == "$ANNOT_DIR"/* ]]; then
        printf '%s\n' "- /$ef/**.db-journal" "- /$ef/**.db-wal" "- /$ef/**.db-shm" "+ /$ef/**"
      elif [[ $f == "$KO_DIR" || $f == "$KO_DIR"/* ]]; then
        printf '%s\n' "- /$ef/**.old" "- /$ef/**.tmp" "+ /$ef/**"
      elif ((use_types)) && [[ $FILTER_MODE == exclude ]]; then
        for e in "${FILTER_EXT[@]}"; do say "- /$ef/**.$e"; done
        say "+ /$ef/**"
      elif ((use_types)); then
        for e in "${FILTER_EXT[@]}"; do say "+ /$ef/**.$e"; done
      else
        say "+ /$ef/**"
      fi
    done
    say "- **"
  } | write_atomic "$FILTER_FILE"
}

rclone_minor() { rclone version 2>/dev/null | sed -n '1s/^rclone v1\.\([0-9]*\).*/\1/p'; }

rclone_error() { # ERRFILE
  grep -E 'ERROR|NOTICE|Failed|error' "$1" 2>/dev/null | tail -n 8 >&2
  if grep -qiE 'invalid_grant|token.*(expired|revoked)|couldn.t fetch token|oauth2' "$1" 2>/dev/null; then
    warn "Google Drive authorisation looks expired. Use Settings → Reconnect Google Drive."
  elif grep -qiE 'no such host|dial tcp|timeout|network is unreachable' "$1" 2>/dev/null; then
    warn "Network problem - check your connection."
  elif grep -qiE "didn.t find section in config file|not found in config" "$1" 2>/dev/null; then
    warn "Remote '$REMOTE' is not configured. Use Settings → Google Drive connection."
  fi
}

unlock_rclone() {
  local f pw try
  [[ -n ${RCLONE_CONFIG_PASS:-} || -n ${RCLONE_PASSWORD_COMMAND:-} ]] && return 0
  f=$(rclone config file 2>/dev/null | tail -n 1)
  [[ -f $f ]] && head -c 32 -- "$f" | grep -q 'RCLONE_ENCRYPT_V0' || return 0
  for try in 1 2 3; do
    cursor on; printf 'rclone config password: '; IFS= read -rs pw; say; cursor off
    if RCLONE_CONFIG_PASS=$pw rclone listremotes >/dev/null 2>&1; then
      export RCLONE_CONFIG_PASS=$pw; return 0
    fi
    err "Wrong password ($try/3)"
  done
  exit 1
}

remote_type() { rclone listremotes --long 2>/dev/null | awk -v r="$REMOTE:" '$1==r {print $2}'; }

# ------------------------------------------------------------------ diff --
# Some Android shared storage refuses to set modification times, so every sync would see every
# file as changed. Probe once per run; if times can't be kept, compare files by MD5 instead.
checksum_mode() {
  local f
  if [[ -z $CHECKSUM ]]; then
    CHECKSUM=0
    if ((TERMUX)) && [[ -d $LIBRARY_ROOT ]]; then
      f=$LIBRARY_ROOT/.mtime-probe
      if : >"$f" 2>/dev/null; then
        { touch -d '2001-01-01 00:00:00 UTC' -- "$f" 2>/dev/null && [[ $(date -r "$f" +%s 2>/dev/null) == 978307200 ]]; } || CHECKSUM=1
        rm -f -- "$f"
      fi
    fi
  fi
  ((CHECKSUM))
}

# What a listing depends on; a prefetched listing is only used if this is unchanged.
list_sig() { printf '%s|%s|%s' "$LIBRARY_ROOT" "$(rpath)" "$(cat -- "$FILTER_FILE" 2>/dev/null)"; }

# start_listings DIR: the four Status listings, in the background (build_filters must have run).
start_listings() {
  local d=$1
  mkdir -p -- "$d"; base_flags
  local -a lf=(lsf -R --files-only --fast-list --format pst --separator $'\t'
    --filter-from "$FILTER_FILE" --ignore-case "${BASE[@]}")
  checksum_mode && lf+=(--format psth --hash MD5)
  LIST_DIR=$d LIST_AT=$(date +%s) LIST_SIG=$(list_sig) LIST_PIDS=()
  if [[ -d $LIBRARY_ROOT ]]; then
    { rclone "${lf[@]}" -- "$LIBRARY_ROOT" >"$d/local.lst" 2>"$d/local.lst.err"; echo $? >"$d/local.rc"; } &
    LIST_PIDS+=($!)
  else : >"$d/local.lst"; echo 0 >"$d/local.rc"; fi
  { rclone "${lf[@]}" -- "$(rpath)" >"$d/remote.lst" 2>"$d/remote.lst.err"; echo $? >"$d/remote.rc"; } &
  LIST_PIDS+=($!)
  rclone cat "${BASE[@]}" -- "$(rpath "$MARKER_DIR")" >"$d/markers" 2>/dev/null </dev/null & LIST_PIDS+=($!)
  rclone about --json "${BASE[@]}" -- "$REMOTE:" >"$d/about" 2>/dev/null </dev/null & LIST_PIDS+=($!)
}

# Called while the main menu waits for a key, so Status (or a sync preview) is usually instant.
prefetch() {
  ((DIFF_READY)) && return 0
  ((${#FOLDERS[@]})) && have rclone || return 0
  [[ -n $LIST_DIR ]] && (($(date +%s) - LIST_AT < 60)) && return 0
  build_filters || return 0
  koreader_import quiet
  start_listings "$TMP/ls.$RANDOM$RANDOM"
}

compute_diff() {
  local lo ro d lrc rrc k n
  DIFF_READY=0 REMOTE_MISSING=0
  build_filters || return 1
  if [[ -z $LIST_DIR ]] || (($(date +%s) - LIST_AT > 120)) || [[ $LIST_SIG != "$(list_sig)" ]]; then
    koreader_import
    printf '%sListing %s and %s …%s\n' "$CD" "$(tildify "$LIBRARY_ROOT")" "$(rpath)" "$C0"
    start_listings "$TMP/ls.$RANDOM$RANDOM"
  else
    ko_ready >/dev/null  # the prefetch imported quietly: still say why KOReader isn't synced, if it isn't
  fi
  wait "${LIST_PIDS[@]}" 2>/dev/null
  d=$LIST_DIR LIST_DIR=
  lo=$d/local.lst ro=$d/remote.lst
  lrc=$(cat -- "$d/local.rc" 2>/dev/null || echo 1) rrc=$(cat -- "$d/remote.rc" 2>/dev/null || echo 1)
  mv -f -- "$d/markers" "$TMP/markers"; mv -f -- "$d/about" "$TMP/about"
  if ((lrc)); then err "Listing local files failed:"; rclone_error "$lo.err"; return 1; fi
  if ((rrc)); then
    if grep -q 'directory not found' "$ro.err"; then : >"$ro"; REMOTE_MISSING=1
    else err "Listing $(rpath) failed:"; rclone_error "$ro.err"; return 1; fi
  fi
  # A file only on the remote and one only here with the same size and modification time is
  # one file renamed or moved; the manifest (paths after the last sync) tells which side did it.
  # Renames go to $TMP/renames as: remote-path TAB local-path TAB remote|local|(unknown).
  : >"$TMP/renames"
  awk -F'\t' -v OFS='\t' -v man="$MANIFEST_FILE" -v ren="$TMP/renames" '
    BEGIN { while ((getline l < man) > 0) inman[l] = 1 }
    FILENAME == ARGV[1] { ls[$1] = $2; lt[$1] = $3; lh[$1] = $4; next }
    {
      p = $1
      if (p in ls) {
        if (ls[p] == $2 && (lt[p] == $3 || ($4 != "" && lh[p] == $4))) c = "same"
        else if (lt[p] > $3) c = "lnew"
        else if (lt[p] < $3) c = "rnew"
        else c = "size"
        print c, p, ls[p], lt[p], $2, $3, p, p; delete ls[p]
      } else { rs[p] = $2; rt[p] = $3 }
    }
    END {
      for (p in ls) if (ls[p] != 0) { k = ls[p] SUBSEP lt[p]; lc[k]++; lp[k] = p }
      for (p in rs) if (rs[p] != 0) { k = rs[p] SUBSEP rt[p]; rc[k]++; rp[k] = p }
      for (k in rp) if (rc[k] == 1 && lc[k] == 1) {
        r = rp[k]; l = lp[k]
        d = ((l in inman) && !(r in inman)) ? "remote" : (((r in inman) && !(l in inman)) ? "local" : "")
        if (d == "remote") s = l " → " r "  (renamed on remote)"
        else if (d == "local") s = r " → " l "  (renamed here)"
        else s = "here: " l "  remote: " r
        print "ren", s, ls[l], lt[l], rs[r], rt[r], r, l
        print r, l, d > ren
        delete ls[l]; delete rs[r]
      }
      for (p in rs) print "radd", p, "-", "-", rs[p], rt[p], p, "-"
      for (p in ls) print "ladd", p, ls[p], lt[p], "-", "-", "-", p
    }' "$lo" "$ro" |
    LC_ALL=C sort -t $'\t' -k2,2 >"$TMP/diff"
  CNT=([same]=0 [radd]=0 [rnew]=0 [ladd]=0 [lnew]=0 [ren]=0 [size]=0)
  while read -r k n; do CNT[$k]=$n; done < <(awk -F'\t' '{c[$1]++} END {for (k in c) print k, c[k]}' "$TMP/diff")
  read -r LOCAL_N LOCAL_B < <(awk -F'\t' '{n++; b += $2} END {printf "%d %.0f\n", n, b}' "$lo")
  read -r REMOTE_N REMOTE_B < <(awk -F'\t' '{n++; b += $2} END {printf "%d %.0f\n", n, b}' "$ro")
  DIFF_TIME=$(date -d "@$LIST_AT" +%H:%M:%S 2>/dev/null || date +%H:%M:%S) DIFF_READY=1
}

# Paths present after the last successful sync.
save_manifest() {
  [[ -d $LIBRARY_ROOT ]] && build_filters || return 0
  rclone lsf -R --files-only --filter-from "$FILTER_FILE" --ignore-case -- "$LIBRARY_ROOT" >"$MANIFEST_FILE.tmp" 2>/dev/null &&
    mv -f -- "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
}

# Merge: give each renamed file the same name on both sides ($1: l|r|b for undecided ones).
apply_renames() {
  local r l d side
  base_flags
  while IFS=$'\t' read -r r l d; do
    case $d in remote) side=r ;; local) side=l ;; *) side=$1 ;; esac
    if [[ $side == r ]]; then
      [[ -e $LIBRARY_ROOT/$r ]] && continue
      { mkdir -p -- "$(dirname -- "$LIBRARY_ROOT/$r")" && mv -n -- "$LIBRARY_ROOT/$l" "$LIBRARY_ROOT/$r"; } ||
        { err "Could not rename $l"; return 1; }
      printf '  %s»%s here: %s → %s\n' "$CBL" "$C0" "$l" "$r"; log_line "rename local $l -> $r"
    elif [[ $side == l ]]; then
      rclone moveto "${BASE[@]}" -- "$(rpath "$r")" "$(rpath "$l")" </dev/null 2>"$TMP/mv.err" ||
        { err "Could not rename $(rpath "$r")"; rclone_error "$TMP/mv.err"; return 1; }
      printf '  %s»%s remote: %s → %s\n' "$CBL" "$C0" "$r" "$l"; log_line "rename remote $r -> $l"
    fi
  done <"$TMP/renames"
}

set_last() { printf -v "LAST_${1^^}" '%s' "$(now_iso)"; save_state; save_manifest; save_sioyek_base; save_koreader_base; write_marker; }

devices_lines() {
  local h pu pl mark lp
  if [[ ! -s $TMP/markers ]]; then printf ' %sNo device history on the remote yet%s\n' "$CD" "$C0"; return; fi
  lp=$(epoch "$LAST_PULL")
  while IFS=$'\t' read -r h pu pl; do
    mark=
    if [[ $h == "$HOST" ]]; then mark=" ${CD}(this device)${C0}"
    elif (($(epoch "$pu") > lp)); then mark=" ${CY}← pushed after your last pull${C0}"; fi
    printf ' %s%-16s%s push %-28s pull %s%s\n' "$CB" "$h" "$C0" "$(ago "$pu")" "$(ago "$pl")" "$mark"
  done < <(awk -F= '
      /^host=/ { if (h != "") print h "\t" pu "\t" pl; h = $2; pu = "-"; pl = "-" }
      /^last_push=/ { pu = $2 } /^last_pull=/ { pl = $2 }
      END { if (h != "") print h "\t" pu "\t" pl }' "$TMP/markers")
}

status_header() {
  local lb rb used total u t
  hs lb "$LOCAL_B"; hs rb "$REMOTE_B"
  printf ' %sStatus%s  %s ⇄ %s  %s(listed %s)%s\n' "$CB" "$C0" "$(rpath)" "$(tildify "$LIBRARY_ROOT")" "$CD" "$DIFF_TIME" "$C0"
  printf ' %s↓+ %d new on remote%s  %s↓~ %d newer on remote%s  %s↑+ %d new locally%s  %s↑~ %d newer locally%s  %s» %d renamed%s  %s!≠ %d conflicts%s  %s= %d in sync%s\n' \
    "$CG" "${CNT[radd]}" "$C0" "$CC" "${CNT[rnew]}" "$C0" "$CY" "${CNT[ladd]}" "$C0" \
    "$CM" "${CNT[lnew]}" "$C0" "$CBL" "${CNT[ren]}" "$C0" "$CR" "${CNT[size]}" "$C0" "$CD" "${CNT[same]}" "$C0"
  used=$(grep -o '"used":[0-9]*' "$TMP/about" 2>/dev/null | cut -d: -f2)
  total=$(grep -o '"total":[0-9]*' "$TMP/about" 2>/dev/null | cut -d: -f2)
  printf ' Local %d files (%s) · Remote %d files (%s)' "$LOCAL_N" "$lb" "$REMOTE_N" "$rb"
  if [[ -n $used ]]; then hs u "$used"; hs t "${total:-0}"; printf ' · Drive %s / %s used' "$u" "$t"; fi
  printf '   %s[%s]%s\n' "$CD" "$(filter_desc)" "$C0"
  ((REMOTE_MISSING)) && printf ' %s%s does not exist yet - it will be created on the first push%s\n' "$CY" "$(rpath)" "$C0"
  devices_lines
}

print_status() {
  local c p ls lt rs rt a b n=0
  status_header; say
  while IFS=$'\t' read -r c p ls lt rs rt _; do
    [[ $c == same ]] && continue
    hs a "$ls"; hs b "$rs"
    printf ' %s%s%s %s  %s(local %s %s · remote %s %s)%s\n' "${CAT_COL[$c]}" "${CAT_SYM[$c]}" "$C0" "$p" \
      "$CD" "$a" "${lt:0:16}" "$b" "${rt:0:16}" "$C0"
    ((++n))
  done <"$TMP/diff"
  ((n)) || ok "Everything is in sync."
}

# --------------------------------------------------------------- widgets --
# run_menu HEADER_FN "key|Label|Description" ...   -> MENU_KEY ("q" on back)
run_menu() {
  local hdr=$1; shift
  local -a items=("$@"); local n=$# i=${MENU_POS[$hdr]:-0} j k l d buf line htxt
  ((i >= n)) && i=0
  cursor off
  htxt=$($hdr)  # may run rclone: render once, not on every keypress
  while :; do
    buf="$htxt"$'\n'
    for ((j = 0; j < n; j++)); do
      IFS='|' read -r k l d <<<"${items[j]}"
      if ((j == i)); then printf -v line ' %s› %-2s %-14s%s %s' "$CC$CB" "$k" "$l" "$C0" "$d"
      else printf -v line '   %s%-2s%s %-14s %s%s%s' "$CC" "$k" "$C0" "$l" "$CD" "$d" "$C0"; fi
      buf+="$line"$'\n'
    done
    buf+=$'\n'" ${CD}j/k move · enter select · shortcut key · q back${C0}"
    frame "$buf"
    read_key
    case $KEY in
      j) i=$(((i + 1) % n)) ;;
      k) i=$(((i - 1 + n) % n)) ;;
      g) i=0 ;;
      G) i=$((n - 1)) ;;
      enter | l) MENU_POS[$hdr]=$i; MENU_KEY=${items[i]%%|*}; return ;;
      q | esc | h | bs) MENU_KEY=q; return ;;
      *)
        for ((j = 0; j < n; j++)); do
          if [[ $KEY == "${items[j]%%|*}" ]]; then MENU_POS[$hdr]=$j; MENU_KEY=$KEY; return; fi
        done ;;
    esac
  done
}

# pager TITLE FILE [top|end]
pager() {
  local title=$1 top=0 h n i buf line; local -a L
  mapfile -t L < <(tail -n 5000 -- "$2" 2>/dev/null)
  n=${#L[@]}; term_size; h=$((TH - 3))
  [[ ${3:-top} == end ]] && top=$((n - h))
  while :; do
    term_size; h=$((TH - 3)); ((h < 1)) && h=1
    ((top > n - h)) && top=$((n - h)); ((top < 0)) && top=0
    buf=" ${CB}$title${C0}  ${CD}$((n ? top + 1 : 0))-$((top + h < n ? top + h : n))/$n${C0}"$'\n'
    for ((i = top; i < top + h && i < n; i++)); do line=${L[i]//$'\t'/    }; buf+=" ${line:0:TW-2}"$'\n'; done
    buf+=" ${CD}j/k scroll · ctrl-d/u page · g/G top/bottom · q back${C0}"
    frame "$buf"
    read_key
    case $KEY in
      j) ((top++)) ;; k) ((top--)) ;;
      ctrl-d | space) top=$((top + h / 2)) ;; ctrl-u) top=$((top - h / 2)) ;;
      g) top=0 ;; G) top=$n ;;
      q | esc | h | enter) return ;;
    esac
  done
}

# open_path PATH|URL: hand it to the desktop's default handler without blocking the menu.
open_path() {
  local o
  if ((TERMUX)); then
    if [[ $1 == https://* ]]; then o=termux-open-url
    elif [[ -d $1 ]]; then MSG="Android can't open folders from Termux - it is $1"; return 1
    else o=termux-open; fi
    have "$o" || { MSG="$o not found (pkg install termux-tools)."; return 1; }
    "$o" "$1" >/dev/null 2>&1 </dev/null
    return
  fi
  for o in xdg-open wslview open; do have "$o" && break; o=; done
  [[ -n $o ]] || { MSG="Nothing to open it with (install xdg-utils)."; return 1; }
  if have setsid; then setsid -f "$o" "$1" >/dev/null 2>&1 </dev/null
  else "$o" "$1" >/dev/null 2>&1 </dev/null & disown; fi
}

# open_row FOLDER(0|1) REMOTE-PATH LOCAL-PATH ("-" = not on that side) -> MSG on failure.
# Opens the file (or its folder) here if it exists locally, otherwise on Google Drive in the browser.
open_row() {
  local folder=$1 rp=$2 lp=$3 f sub id
  if [[ $lp != - ]]; then
    f=$LIBRARY_ROOT/$lp
    [[ -e $f ]] || { MSG="Not found: $f"; return 1; }
    if ((folder)); then open_path "$(dirname -- "$f")"; else open_path "$f"; fi
    return
  fi
  sub=${REMOTE_PATH:+$REMOTE_PATH/}$rp
  if ((folder)); then [[ $sub == */* ]] && sub=${sub%/*} || sub=; fi
  [[ -n $sub ]] || { open_path "https://drive.google.com/drive/my-drive"; return; }
  id=$(drive_id "$sub" "$folder")
  if [[ -z $id ]]; then MSG="Could not find $REMOTE:$sub on Google Drive (browser links need a Drive remote)."; return 1; fi
  if ((folder)); then open_path "https://drive.google.com/drive/folders/$id"; else open_path "https://drive.google.com/file/d/$id/view"; fi
}

# drive_id PATH IS_DIR: Drive item ID of PATH (relative to the remote's root), or nothing.
# A folder's own --stat carries no ID, so folders are looked up in their parent's listing.
drive_id() {
  local path=$1 parent= name en id
  base_flags
  if (($2)); then
    [[ $path == */* ]] && parent=${path%/*}
    name=${path##*/} en=${name//\\/\\\\} en=${en//\"/\\\"}
    id=$(rclone lsjson --dirs-only --no-modtime --no-mimetype "${BASE[@]}" -- "$REMOTE:$parent" 2>/dev/null </dev/null |
      grep -F "\"Name\":\"$en\"," | grep -o '"ID":"[^"]*"' | head -n1 | cut -d'"' -f4)
  else
    id=$(rclone lsjson --stat --no-modtime --no-mimetype "${BASE[@]}" -- "$REMOTE:$path" 2>/dev/null </dev/null |
      grep -o '"ID": *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
  fi
  [[ $id =~ ^[A-Za-z0-9_-]+$ ]] && printf '%s' "$id"
}

# view_diff [CATEGORY]  -> VIEW_ACTION (p|u|m|r|q)
view_diff() {
  local ci=0 sel=0 top=0 q= reload=1 n=0 i j h pw buf line c p ls lt rs rt rp lp a b pad cat tabs MSG=
  local -a ROWS
  for ((j = 0; j < ${#CAT_KEYS[@]}; j++)); do [[ ${CAT_KEYS[j]} == "${1:-changes}" ]] && ci=$j; done
  local hdr; hdr=$(status_header)
  cursor off
  while :; do
    cat=${CAT_KEYS[ci]}
    if ((reload)); then
      mapfile -t ROWS < <(awk -F'\t' -v c="$cat" -v q="${q,,}" '
        (c == "changes" && $1 == "same") || (c != "changes" && $1 != c) { next }
        q != "" && index(tolower($2), q) == 0 { next } { print }' "$TMP/diff")
      n=${#ROWS[@]} sel=0 top=0 reload=0
    fi
    term_size
    h=$((TH - $(wc -l <<<"$hdr") - 5)); ((h < 3)) && h=3
    ((sel >= n)) && sel=$((n - 1)); ((sel < 0)) && sel=0
    ((sel < top)) && top=$sel; ((sel >= top + h)) && top=$((sel - h + 1))
    tabs=
    for ((j = 0; j < ${#CAT_KEYS[@]}; j++)); do
      if ((j == ci)); then tabs+=" $CRV ${CAT_LABEL[${CAT_KEYS[j]}]} $C0"
      else tabs+=" $CD ${CAT_LABEL[${CAT_KEYS[j]}]} $C0"; fi
    done
    buf="$hdr"$'\n'"$tabs"$'\n'
    pw=$((TW - 60)); ((pw < 16)) && pw=16
    printf -v line ' %s   %-*s %8s %-16s %8s %-16s%s' "$CD" "$pw" "path${q:+  (filter: $q)}" "local" "" "remote" "" "$C0"
    buf+="$line"$'\n'
    for ((i = top; i < top + h && i < n; i++)); do
      IFS=$'\t' read -r c p ls lt rs rt rp lp <<<"${ROWS[i]}"
      ((${#p} > pw)) && p="…${p: -$((pw - 1))}"
      printf -v pad '%*s' $((pw - ${#p})) ''
      hs a "$ls"; hs b "$rs"
      if ((i == sel)); then
        printf -v line ' %s%s %s%s %8s %-16s %8s %-16s%s' "$CRV" "${CAT_SYM[$c]}" "$p" "$pad" "$a" "${lt:0:16}" "$b" "${rt:0:16}" "$C0"
      else
        printf -v line ' %s%s%s %s%s %8s %-16s %8s %-16s' "${CAT_COL[$c]}" "${CAT_SYM[$c]}" "$C0" "$p" "$pad" "$a" "${lt:0:16}" "$b" "${rt:0:16}"
      fi
      buf+="$line"$'\n'
    done
    ((n)) || buf+="   ${CD}(nothing here)${C0}"$'\n'
    if [[ -n $MSG ]]; then buf+=$'\n'" ${CY}$MSG${C0}"
    else buf+=$'\n'" ${CD}$((n ? sel + 1 : 0))/$n · j/k move · tab/h/l category · / search · s open · x folder · p pull · u push · m merge · r refresh · q back${C0}"; fi
    frame "$buf"
    read_key; MSG=
    case $KEY in
      j) ((sel++)) ;; k) ((sel--)) ;;
      ctrl-d) sel=$((sel + h / 2)) ;; ctrl-u) sel=$((sel - h / 2)) ;;
      g) sel=0 ;; G) sel=$((n - 1)) ;;
      tab | l | ']') ci=$(((ci + 1) % ${#CAT_KEYS[@]})); reload=1 ;;
      btab | h | '[') ci=$(((ci - 1 + ${#CAT_KEYS[@]}) % ${#CAT_KEYS[@]})); reload=1 ;;
      /) printf '\e[%d;1H\e[2K' "$TH"; ask "search: " "$q"; q=$REPLY; reload=1 ;;
      s | x)
        if ((n)); then
          printf '\e[%d;1H\e[2K %s%s…%s' "$TH" "$CD" "$([[ $KEY == x ]] && echo 'Opening folder' || echo Opening)" "$C0"
          IFS=$'\t' read -r c p ls lt rs rt rp lp <<<"${ROWS[sel]}"
          open_row "$([[ $KEY == x ]] && echo 1 || echo 0)" "$rp" "$lp"
        fi ;;
      p | u | m | r) VIEW_ACTION=$KEY; return ;;
      q | esc) VIEW_ACTION=q; return ;;
    esac
  done
}

# ----------------------------------------------------------------- sync --
sioyek_running() { have pgrep && pgrep -x sioyek >/dev/null 2>&1; }

annot_db_changed() { awk -F'\t' -v p="$ANNOT_DIR/shared.db" '$2 == p && ($1 == "rnew" || $1 == "lnew" || $1 == "size") {f = 1} END {exit !f}' "$TMP/diff"; }

annot_changes() { awk -F'\t' -v d="$ANNOT_DIR/" '$1 != "same" && index($2, d) == 1 {f = 1} END {exit !f}' "$TMP/diff"; }

write_marker() {
  base_flags
  printf 'host=%s\nos=%s\nlast_pull=%s\nlast_push=%s\nlast_merge=%s\n' "$HOST" "$( ((TERMUX)) && echo Android || uname -s)" \
    "${LAST_PULL:--}" "${LAST_PUSH:--}" "${LAST_MERGE:--}" |
    rclone rcat "${BASE[@]}" -- "$(rpath "$MARKER_DIR/$HOST.txt")" 2>/dev/null ||
    warn "Could not update the device marker on the remote (sync itself succeeded)."
}

log_line() { mkdir -p -- "$LIBRARY_ROOT/logs" && printf '%s %s %s\n' "$(date '+%F %T')" "$HOST" "$*" >>"$LIBRARY_ROOT/logs/library.log"; }

run_rclone() { # LOGFILE ARGS...
  local log=$1 rc; shift
  local -a prog=(--stats-one-line --stats 30s)
  ((TTY)) && prog=(-P)
  mkdir -p -- "$(dirname -- "$log")"
  printf '\n==== %s %s: rclone %s\n' "$(date '+%F %T')" "$HOST" "$1" >>"$log"
  # Ctrl-C stops rclone but keeps the menu alive.
  trap ':' INT
  cursor on
  # Android may suspend Termux when the screen turns off; hold a wake lock while transferring.
  ((TERMUX)) && have termux-wake-lock && termux-wake-lock
  rclone "$1" "${prog[@]}" --log-file "$log" --log-level INFO "${@:2}"
  rc=$?
  ((TERMUX)) && have termux-wake-unlock && termux-wake-unlock
  trap 'exit 130' INT
  return $rc
}

# do_sync pull|push|merge [assume_yes] [force]
do_sync() {
  local op=$1 yes=${2:-0} force=${3:-0} a b c d over del dest_n ts log rc=0 title ren unk revert names=b merge_db=0 ko_n=0 ko_new=0
  [[ $DIFF_READY == 1 ]] || compute_diff || return 1
  [[ $op != push ]] && annot_db_changed && merge_db=1
  [[ $op != push ]] && read -r ko_n ko_new < <(ko_pending "$op")
  KO_POLICY=$KO_CONFLICT KO_ALL=
  ren=${CNT[ren]}
  unk=$(awk -F'\t' '$3 == ""' "$TMP/renames" | wc -l)
  case $op in
    pull) revert=$(awk -F'\t' '$3 == "local"' "$TMP/renames" | wc -l) ;;
    push) revert=$(awk -F'\t' '$3 == "remote"' "$TMP/renames" | wc -l) ;;
    *) revert=0 ;;
  esac
  case $op in
    pull)  a=${CNT[radd]} b=$((CNT[rnew] + CNT[size])) over=${CNT[lnew]} del=$((CNT[ladd] - ko_new)) dest_n=$LOCAL_N
           title="Pull  $(rpath) → $(tildify "$LIBRARY_ROOT")" ;;
    push)  a=${CNT[ladd]} b=$((CNT[lnew] + CNT[size])) over=${CNT[rnew]} del=${CNT[radd]} dest_n=$REMOTE_N
           title="Push  $(tildify "$LIBRARY_ROOT") → $(rpath)" ;;
    merge) a=$((CNT[radd] + CNT[rnew] + CNT[size])) b=$((CNT[ladd] + CNT[lnew])) over=0 del=0 dest_n=0
           title="Merge  $(rpath) ⇄ $(tildify "$LIBRARY_ROOT")  (newer wins, nothing is deleted)" ;;
  esac
  while :; do
    ((TTY)) && cls
    printf '\n %s%s%s   %s[%s]%s\n\n' "$CB" "$title" "$C0" "$CD" "$(filter_desc)" "$C0"
    if [[ $op == merge ]]; then
      printf '   %s↓ %5d%s  files to download (new or newer on remote)\n' "$CG" "$a" "$C0"
      printf '   %s↑ %5d%s  files to upload (new or newer locally)\n' "$CY" "$b" "$C0"
      ((ren)) && printf '   %s» %5d%s  renamed files get the same name on both sides (moved, not copied)\n' "$CBL" "$ren" "$C0"
      if ((unk)); then
        case $names in l) d="keep the names on this device" ;; r) d="keep the names on the remote" ;;
          *) d="keep both names (copies the file both ways)" ;; esac
        printf '   %s  %5d%s  of them renamed on an unknown side: %s%s%s  %s(l / r / b to change)%s\n' "$CY" "$unk" "$C0" "$CB" "$d" "$C0" "$CD" "$C0"
      fi
    else
      printf '   %s+ %5d%s  new files to copy\n' "$CG" "$a" "$C0"
      printf '   %s~ %5d%s  changed files to update\n' "$CC" "$b" "$C0"
      if ((ren)); then
        printf '   %s» %5d%s  renamed files take the %s name (moved, not copied)\n' "$CBL" "$ren" "$C0" "$([[ $op == pull ]] && echo remote || echo local)"
        ((revert)) && printf '   %s! %5d%s  of them were renamed %s - %s undoes that; Merge keeps the new names\n' \
          "$CY" "$revert" "$C0" "$([[ $op == pull ]] && echo 'on this device' || echo 'on the remote')" "$op"
      fi
      ((over)) && printf '   %s! %5d%s  destination files are NEWER and will be overwritten (old copy kept in trash)\n' "$CR" "$over" "$C0"
      ((del)) && printf '   %s✘ %5d%s  files missing from the source will be removed (moved to trash)\n' "$CR" "$del" "$C0"
    fi
    ((merge_db)) && have sqlite3 && printf '   %s⇄      %s  sioyek annotations from both sides are merged, not overwritten\n' "$CBL" "$C0"
    ((ko_n)) && printf '   %s⇄ %5d%s  KOReader books changed here are merged with the remote copy; conflicts: %s%s%s  %s(c to change)%s\n' \
      "$CBL" "$ko_n" "$C0" "$CB" "$(ko_policy_desc "$KO_POLICY")" "$C0" "$CD" "$C0"
    ((ko_new)) && printf '   %s↑ %5d%s  KOReader books first opened here are uploaded, not removed\n' "$CY" "$ko_new" "$C0"
    if ((a + b + over + del + ren + ko_new == 0)); then
      ok "Already in sync - nothing to $op."
      set_last "$op"
      return 0
    fi
    if [[ $op != push ]] && sioyek_running && annot_changes; then
      warn "sioyek is running and its annotation database will change - close sioyek first."
    fi
    say
    if ((yes)); then break; fi
    if ((!TTY)) || [[ ! -t 0 ]]; then err "Not interactive: re-run with -y to confirm."; return 1; fi
    printf ' %sy%s run  %sv%s view changes  %sn%s cancel ' "$CB" "$C0" "$CB" "$C0" "$CB" "$C0"
    read_key
    case $KEY in
      y | Y) say; break ;;
      v) view_diff changes ;;
      l | r | b) [[ $op == merge ]] && ((unk)) && names=$KEY || { say; info "Cancelled."; return 1; } ;;
      c) ((ko_n)) && KO_POLICY=$(ko_next_policy "$KO_POLICY") || { say; info "Cancelled."; return 1; } ;;
      *) say; info "Cancelled."; return 1 ;;
    esac
  done
  # Nobody to ask: the newer edit wins.
  [[ $KO_POLICY == ask ]] && { ((yes || !TTY)) || [[ ! -t 0 ]]; } && KO_POLICY=newer
  # Guard against mass deletion (e.g. pushing from an empty or wrongly-configured device).
  if ((del >= 10 && del * 4 > dest_n)); then
    warn "This would remove $del of $dest_n files on the destination."
    if ((yes)); then
      ((force)) || { err "Refusing without --force."; return 1; }
    else
      ask "Type 'delete' to continue: "; [[ $REPLY == delete ]] || { info "Cancelled."; return 1; }
    fi
  fi
  # Replacing shared.db under a running sioyek loses whatever it writes back afterwards.
  if [[ $op != push ]] && annot_changes && sioyek_running; then
    warn "sioyek is still running - replacing its annotation database now can lose annotations."
    if ((yes)); then
      ((force)) || { err "Close sioyek, or re-run with --force."; return 1; }
    else
      yesno " Continue anyway?" n || { info "Cancelled."; return 1; }
    fi
  fi
  build_filters || return 1
  base_flags
  ts=$(date +%Y-%m-%d_%H%M%S)
  log=$LIBRARY_ROOT/logs/rclone-$op-$(date +%Y-%m).log
  local -a X=("${BASE[@]}" --fast-list --transfers "$TRANSFERS" --drive-chunk-size 64M
    --filter-from "$FILTER_FILE" --ignore-case)
  [[ -n $BWLIMIT ]] && X+=(--bwlimit "$BWLIMIT")
  checksum_mode && X+=(--checksum)
  mkdir -p -- "$LIBRARY_ROOT"
  if ((merge_db)) && ! sioyek_merge "$LIBRARY_ROOT/.trash/$ts" "$REMOTE:$REMOTE_TRASH/$ts"; then
    DIFF_READY=0
    err "${op^} cancelled, so neither annotation database gets overwritten."
    return 1
  fi
  if [[ $op != push ]] && ! koreader_merge "$op" "$LIBRARY_ROOT/.trash/$ts" "$REMOTE:$REMOTE_TRASH/$ts"; then
    DIFF_READY=0
    err "${op^} cancelled."
    return 1
  fi
  case $op in
    pull) run_rclone "$log" sync "${X[@]}" --track-renames --backup-dir "$LIBRARY_ROOT/.trash/$ts" -- "$(rpath)" "$LIBRARY_ROOT"; rc=$? ;;
    push) run_rclone "$log" sync "${X[@]}" --track-renames --backup-dir "$REMOTE:$REMOTE_TRASH/$ts" -- "$LIBRARY_ROOT" "$(rpath)"; rc=$? ;;
    merge)
      apply_renames "$names"; rc=$?
      ((rc)) || run_rclone "$log" copy "${X[@]}" --update --backup-dir "$LIBRARY_ROOT/.trash/$ts" -- "$(rpath)" "$LIBRARY_ROOT" || rc=$?
      ((rc)) || { run_rclone "$log" copy "${X[@]}" --update --backup-dir "$REMOTE:$REMOTE_TRASH/$ts" -- "$LIBRARY_ROOT" "$(rpath)"; rc=$?; } ;;
  esac
  DIFF_READY=0
  say
  if ((rc == 0)); then
    set_last "$op"
    log_line "$op ok"
    ok "${op^} finished. Log: $(tildify "$log")"
  else
    log_line "$op FAILED rc=$rc"
    err "${op^} failed (rclone exit $rc). Last errors from $(tildify "$log"):"
    rclone_error "$log"
  fi
  # Whatever did arrive is complete (rclone writes each file whole), so KOReader gets it either way.
  koreader_export
  return $rc
}

# -------------------------------------------------------------- folders --
list_remote_dirs() { # PATH (relative to drive root) -> DIRS
  local key=$1 out d
  DIRS=()
  if [[ -z ${DIRCACHE[$key]+x} ]]; then
    base_flags
    printf '\e[2K\r %sListing %s:%s …%s' "$CD" "$REMOTE" "$key" "$C0"
    out=$(rclone lsf --dirs-only "${BASE[@]}" -- "$REMOTE:$key" 2>"$TMP/ls.err") || return 1
    DIRCACHE[$key]=$out
  fi
  while IFS= read -r d; do
    d=${d%/}; [[ -z $d || $d == "$MARKER_DIR" ]] && continue
    [[ $key == "$REMOTE_PATH" ]] && ! sync_folder_ok "$d" && continue
    DIRS+=("$d")
  done <<<"${DIRCACHE[$key]}"
}

# browse_folders select|root   select: pick FOLDERS under REMOTE_PATH; root: pick REMOTE_PATH
browse_folders() {
  local mode=$1 cwd= base= sel=0 top=0 n i h buf line rel mark f full k
  local -A picked=()
  local -a DIRS
  if [[ $mode == select ]]; then base=$REMOTE_PATH; for f in "${FOLDERS[@]}"; do picked[$f]=1; done
  else cwd=$REMOTE_PATH; fi
  cursor off
  while :; do
    full=${base:+$base${cwd:+/}}$cwd
    if ! list_remote_dirs "$full"; then
      if [[ -n $cwd ]] && grep -q 'directory not found' "$TMP/ls.err"; then cwd=${cwd%/*}; [[ $cwd == "$full" ]] && cwd=; continue; fi
      say; err "Could not list $REMOTE:$full"; rclone_error "$TMP/ls.err"; pause; return 1
    fi
    n=${#DIRS[@]}; term_size; h=$((TH - 8)); ((h < 3)) && h=3
    ((sel >= n)) && sel=$((n - 1)); ((sel < 0)) && sel=0
    ((sel < top)) && top=$sel; ((sel >= top + h)) && top=$((sel - h + 1))
    if [[ $mode == select ]]; then
      buf=" ${CB}Folders to sync${C0}  ${CD}(relative to $(rpath))${C0}"$'\n'
      buf+=" selected: ${CC}$(printf '%s ' "${!picked[@]}")${C0}"$'\n'
    else
      buf=" ${CB}Choose the library root on $REMOTE:${C0}"$'\n'" current choice: ${CC}$REMOTE:$cwd${C0}"$'\n'
    fi
    buf+=" ${CBL}$REMOTE:/$full${C0}"$'\n\n'
    for ((i = top; i < top + h && i < n; i++)); do
      rel=${cwd:+$cwd/}${DIRS[i]} mark='   '
      if [[ $mode == select ]]; then
        mark='[ ]'
        if [[ -n ${picked[$rel]+x} ]]; then mark="[${CG}x${C0}]"
        else
          for k in "${!picked[@]}"; do
            if [[ $rel == "$k"/* ]]; then mark="[${CD}·${C0}]"; break; fi
            [[ $k == "$rel"/* ]] && mark="[${CY}-${C0}]"
          done
        fi
      fi
      if ((i == sel)); then printf -v line ' %s›%s %s %s%s/%s' "$CC" "$C0" "$mark" "$CB" "${DIRS[i]}" "$C0"
      else printf -v line '   %s %s/' "$mark" "${DIRS[i]}"; fi
      buf+="$line"$'\n'
    done
    ((n)) || buf+="   ${CD}(no sub-folders)${C0}"$'\n'
    if [[ $mode == select ]]; then
      buf+=$'\n'" ${CD}j/k move · l/enter open · h back · space toggle · a add path · s save · q cancel${C0}"
    else
      buf+=$'\n'" ${CD}j/k move · l/enter open · h back · s use this folder · a type a path · q cancel${C0}"
    fi
    frame "$buf"
    read_key
    case $KEY in
      j) ((sel++)) ;; k) ((sel--)) ;; g) sel=0 ;; G) sel=$((n - 1)) ;;
      ctrl-d) sel=$((sel + h / 2)) ;; ctrl-u) sel=$((sel - h / 2)) ;;
      l | enter) ((n)) && { cwd=${cwd:+$cwd/}${DIRS[sel]}; sel=0 top=0; } ;;
      h | bs) if [[ $cwd == */* ]]; then cwd=${cwd%/*}; elif [[ -n $cwd ]]; then cwd=; fi; sel=0 top=0 ;;
      space)
        if [[ $mode == select ]] && ((n)); then
          rel=${cwd:+$cwd/}${DIRS[sel]}
          if [[ -n ${picked[$rel]+x} ]]; then unset 'picked[$rel]'; else picked[$rel]=1; fi
        fi ;;
      a)
        printf '\e[%d;1H\e[2K' "$TH"; ask "path: " "$cwd"; REPLY=${REPLY%/}; REPLY=${REPLY#/}
        if [[ -n $REPLY ]] && valid_relpath "$REPLY"; then
          if [[ $mode == select ]]; then sync_folder_ok "$REPLY" && picked[$REPLY]=1; else REMOTE_PATH=$REPLY; return 0; fi
        fi ;;
      s | w)
        if [[ $mode == select ]]; then
          ((${#picked[@]})) || { printf '\n'; warn "Select at least one folder."; pause; continue; }
          mapfile -t FOLDERS < <(printf '%s\n' "${!picked[@]}" | LC_ALL=C sort |
            awk '{ for (i = 1; i <= n; i++) if (index($0, k[i] "/") == 1) next; k[++n] = $0; print }')
        else
          REMOTE_PATH=$cwd
        fi
        DIFF_READY=0; save_config; return 0 ;;
      q | esc) return 1 ;;
    esac
  done
}

# -------------------------------------------------------------- filters --
filters_menu() {
  local sel=0 n i buf line mode=$FILTER_MODE e mark
  local -A on=()
  local -a list=("${COMMON_EXTS[@]}")
  for e in "${FILTER_EXT[@]}"; do on[$e]=1; [[ " ${list[*]} " == *" $e "* ]] || list+=("$e"); done
  cursor off
  while :; do
    n=${#list[@]}
    buf=" ${CB}File-type filter for this device${C0}  ${CD}(sioyek and KOReader annotations are always synced)${C0}"$'\n\n'
    buf+=" mode: "
    for e in none exclude include; do
      local lbl=$e; [[ $e == none ]] && lbl="sync everything"; [[ $e == exclude ]] && lbl="exclude selected"; [[ $e == include ]] && lbl="only selected"
      if [[ $e == "$mode" ]]; then buf+=" $CRV $lbl $C0"; else buf+=" $CD $lbl $C0"; fi
    done
    buf+=$'\n\n'
    for ((i = 0; i < n; i++)); do
      e=${list[i]}; mark='[ ]'; [[ -n ${on[$e]+x} ]] && mark="[${CG}x${C0}]"
      if ((i == sel)); then printf -v line ' %s›%s %s %s.%s%s' "$CC" "$C0" "$mark" "$CB" "$e" "$C0"
      else printf -v line '   %s .%s' "$mark" "$e"; fi
      [[ $mode == none ]] && line="$CD${line//$C0/$C0$CD}$C0"
      buf+="$line"$'\n'
    done
    buf+=$'\n'" ${CD}Files already on this device that become filtered are left alone (not deleted).${C0}"
    buf+=$'\n'" ${CD}j/k move · space toggle · m/tab mode · a add extension · s save · q cancel${C0}"
    frame "$buf"
    read_key
    case $KEY in
      j) ((sel < n - 1 && ++sel)) ;; k) ((sel > 0 && sel--)) ;; g) sel=0 ;; G) sel=$((n - 1)) ;;
      space) e=${list[sel]}; if [[ -n ${on[$e]+x} ]]; then unset 'on[$e]'; else on[$e]=1; fi ;;
      m | tab) case $mode in none) mode=exclude ;; exclude) mode=include ;; *) mode=none ;; esac ;;
      a)
        printf '\e[%d;1H\e[2K' "$TH"; ask "extension (e.g. epub): "; REPLY=${REPLY#.}; REPLY=${REPLY,,}
        if [[ $REPLY =~ ^[a-z0-9]{1,10}$ ]]; then on[$REPLY]=1; [[ " ${list[*]} " == *" $REPLY "* ]] || list+=("$REPLY"); fi ;;
      s | w)
        FILTER_MODE=$mode FILTER_EXT=()
        for e in "${list[@]}"; do [[ -n ${on[$e]+x} ]] && FILTER_EXT+=("$e"); done
        DIFF_READY=0; save_config; return 0 ;;
      q | esc) return 1 ;;
    esac
  done
}

# ---------------------------------------------------------------- trash --
trash_menu() {
  local cutoff name lsz i; local -a ldirs rdirs
  while :; do
    cls; base_flags
    mapfile -t ldirs < <(find "$LIBRARY_ROOT/.trash" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's|.*/||' | sort)
    lsz=$(du -sh -- "$LIBRARY_ROOT/.trash" 2>/dev/null | cut -f1)
    printf ' %sTrash%s - files removed or overwritten by sync are kept here\n\n' "$CB" "$C0"
    printf ' local   %s  %d snapshots, %s\n' "$(tildify "$LIBRARY_ROOT/.trash")" "${#ldirs[@]}" "${lsz:-0}"
    printf ' %sListing remote trash…%s\r' "$CD" "$C0"
    mapfile -t rdirs < <(rclone lsf --dirs-only "${BASE[@]}" -- "$REMOTE:$REMOTE_TRASH" 2>/dev/null | sed 's|/$||' | sort)
    printf '\e[2K remote  %s:%s  %d snapshots\n\n' "$REMOTE" "$REMOTE_TRASH" "${#rdirs[@]}"
    for ((i = ${#ldirs[@]} > 5 ? ${#ldirs[@]} - 5 : 0; i < ${#ldirs[@]}; i++)); do printf '   %slocal  %s%s\n' "$CD" "${ldirs[i]}" "$C0"; done
    for ((i = ${#rdirs[@]} > 5 ? ${#rdirs[@]} - 5 : 0; i < ${#rdirs[@]}; i++)); do printf '   %sremote %s%s\n' "$CD" "${rdirs[i]}" "$C0"; done
    printf '\n %sc%s clean snapshots older than 30 days   %sa%s empty all trash   %sq%s back ' "$CB" "$C0" "$CB" "$C0" "$CB" "$C0"
    read_key; say
    case $KEY in
      c) cutoff=$(date -d '-30 days' +%F) ;;
      a) ask "Type 'empty' to permanently delete all snapshots: "; [[ $REPLY == empty ]] || continue; cutoff=9999-99-99 ;;
      *) return ;;
    esac
    # Only touch directories whose names look like our snapshot stamps.
    for name in "${ldirs[@]}"; do
      [[ $name =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(_[0-9]{6})?$ && ${name:0:10} < $cutoff ]] || continue
      rm -rf -- "$LIBRARY_ROOT/.trash/$name" && ok "local  $name removed"
    done
    for name in "${rdirs[@]}"; do
      [[ $name =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(_[0-9]{6})?$ && ${name:0:10} < $cutoff ]] || continue
      rclone purge "${BASE[@]}" -- "$REMOTE:$REMOTE_TRASH/$name" && ok "remote $name removed (kept 30 days in Google Drive's own bin)"
    done
    pause
  done
}

# ----------------------------------------------------------------- logs --
logs_menu() {
  local -a files items; local f i
  mapfile -t files < <(ls -1t -- "$LIBRARY_ROOT/logs" 2>/dev/null | grep -E '\.log$' | head -n 9)
  ((${#files[@]})) || { cls; info "No logs yet in $(tildify "$LIBRARY_ROOT/logs")."; pause; return; }
  for i in "${!files[@]}"; do f=${files[i]}; items+=("$((i + 1))|${f}|$(du -h -- "$LIBRARY_ROOT/logs/$f" | cut -f1)"); done
  run_menu logs_hdr "${items[@]}"
  [[ $MENU_KEY == q ]] && return
  pager "${files[MENU_KEY - 1]}" "$LIBRARY_ROOT/logs/${files[MENU_KEY - 1]}" end
}
logs_hdr() { printf ' %sLogs%s  %s\n' "$CB" "$C0" "$(tildify "$LIBRARY_ROOT/logs")"; }

# ---------------------------------------------------------- dependencies --
pkg_manager() {
  if ((TERMUX)); then echo termux; elif have pacman; then echo pacman; elif have apt-get; then echo apt; elif have dnf; then echo dnf
  elif have zypper; then echo zypper; else echo none; fi
}

as_root() { if ((EUID == 0)); then "$@"; else sudo "$@"; fi; }

confirm_run() { # shows the exact command before running it
  printf ' will run: %s%s%s\n' "$CC" "$*" "$C0"
  yesno " Proceed?" y || return 1
  "$@"
}

install_rclone() {
  case $(pkg_manager) in
    termux) confirm_run pkg install -y rclone ;;
    pacman) confirm_run as_root pacman -S --needed rclone ;;
    apt) confirm_run as_root apt-get update && confirm_run as_root apt-get install -y rclone ;;
    dnf) confirm_run as_root dnf install -y rclone ;;
    zypper) confirm_run as_root zypper install -y rclone ;;
    *) install_rclone_official ;;
  esac
}

install_rclone_official() {
  have curl || { err "curl is needed to download rclone's official installer."; return 1; }
  info "Downloading the official installer from https://rclone.org/install.sh (HTTPS)…"
  curl -fsSL --proto '=https' --tlsv1.2 https://rclone.org/install.sh -o "$TMP/rclone-install.sh" || return 1
  confirm_run as_root bash "$TMP/rclone-install.sh"
}

sioyek_installed() { have sioyek || { have flatpak && flatpak info com.github.ahrm.sioyek >/dev/null 2>&1; }; }

install_sioyek() {
  case $(pkg_manager) in
    termux) err "sioyek has no Android version; use any PDF reader app (it will open the synced files)."; return 1 ;;
    pacman)
      if pacman -Si sioyek >/dev/null 2>&1; then confirm_run as_root pacman -S --needed sioyek; return; fi
      if have paru; then confirm_run paru -S sioyek; return; fi
      if have yay; then confirm_run yay -S sioyek; return; fi ;;
    apt)
      if apt-cache show sioyek >/dev/null 2>&1; then confirm_run as_root apt-get install -y sioyek; return; fi ;;
    dnf)
      if dnf info sioyek >/dev/null 2>&1; then confirm_run as_root dnf install -y sioyek; return; fi ;;
  esac
  if have flatpak; then
    confirm_run flatpak install -y flathub com.github.ahrm.sioyek; return
  fi
  err "No sioyek package found. See https://sioyek.info for downloads."; return 1
}

check_deps() {
  local m
  if ! have rclone; then
    warn "rclone is required and not installed."
    if ((TERMUX)); then say " detected: Termux on Android · package manager: pkg"
    else say " detected: $(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown distro}") · package manager: $(pkg_manager)"; fi
    install_rclone || true
    have rclone || { err "Cannot continue without rclone (https://rclone.org/install/)."; exit 1; }
  fi
  m=$(rclone_minor)
  if [[ -n $m ]] && ((m < MIN_RCLONE_MINOR)); then
    warn "rclone v1.$m is old (v1.$MIN_RCLONE_MINOR+ recommended; distro packages lag behind)."
    if ((TERMUX)); then yesno " Update it with 'pkg upgrade rclone'?" y && confirm_run pkg upgrade -y rclone
    else yesno " Install the latest rclone with the official installer?" n && install_rclone_official; fi
  fi
  if ((SIOYEK_ASKED == 0 && !TERMUX)); then
    ! sioyek_installed && yesno "sioyek (PDF reader whose annotations this tool syncs) is not installed. Install it?" y && install_sioyek
    ! have sqlite3 &&
      yesno "sqlite3 (lets Pull/Merge combine sioyek annotations made on different devices) is not installed. Install it?" y && install_sqlite
    SIOYEK_ASKED=1; save_config
  fi
}

install_sqlite() {
  case $(pkg_manager) in
    pacman) confirm_run as_root pacman -S --needed sqlite ;;
    apt) confirm_run as_root apt-get install -y sqlite3 ;;
    dnf) confirm_run as_root dnf install -y sqlite ;;
    zypper) confirm_run as_root zypper install -y sqlite3 ;;
    *) err "Install sqlite3 with your package manager."; return 1 ;;
  esac
}

# --------------------------------------------------------------- remote --
headless() {
  ((TERMUX)) && return 1  # the Android browser can reach rclone's local login server
  [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]] || [[ -n ${SSH_CONNECTION:-} ]]
}

remote_hdr() {
  printf ' %sGoogle Drive connection%s\n\n' "$CB" "$C0"
  printf ' rclone remote %s%s:%s is %s\n' "$CC" "$REMOTE" "$C0" "$( [[ -n $(remote_type) ]] && printf 'configured (%s)' "$(remote_type)" || printf '%snot configured%s' "$CY" "$C0")"
  if [[ $(remote_type) == drive ]]; then
    if rclone config show "$REMOTE" 2>/dev/null | grep -q '^client_id = [^ ]'; then printf ' API client  %syour own%s\n' "$CG" "$C0"
    else printf " API client  %srclone's shared one%s %s(i: use your own - private quota, fewer rate limits)%s\n" "$CY" "$C0" "$CD" "$C0"; fi
  fi
  printf ' %sThe OAuth token lives in rclone.conf (%s); consider encrypting it (Settings).%s\n' "$CD" "$(rclone config file 2>/dev/null | tail -n1)" "$C0"
}

# own_client_id: store the user's Google API client and re-authorise (interactive).
own_client_id() {
  local type id secret; local -a args
  type=$(remote_type)
  say " ${CB}Use your own Google API client ID${C0}"; say
  say " rclone's built-in client ID is shared by every rclone user, so it often hits Google's rate"
  say " limits. Your own gives you a private quota. One-time setup (about 10 minutes):"
  say "  1. https://console.cloud.google.com → create a project (any name)"
  say "  2. APIs & Services → Library → enable 'Google Drive API'"
  say "  3. Google Auth Platform → Get started: External, your email; Audience → add yourself"
  say "     as a test user, then 'Publish app' (otherwise the login expires every 7 days)"
  say "  4. Clients → Create client → type 'Desktop app' → copy the client ID and secret"
  say " ${CD}Details: https://rclone.org/drive/#making-your-own-client-id${C0}"; say
  ask " Client ID (blank to cancel): "; id=$REPLY
  [[ -n $id ]] || return 1
  [[ $id =~ ^[0-9A-Za-z-]+\.apps\.googleusercontent\.com$ ]] || { err "That is not a client ID (it ends in .apps.googleusercontent.com)."; pause; return 1; }
  cursor on; printf ' Client secret: '; IFS= read -rs secret; say; cursor off
  [[ $secret =~ ^[A-Za-z0-9_-]{10,}$ ]] || { err "That does not look like a client secret."; pause; return 1; }
  if [[ $type == drive ]]; then
    rclone config update "$REMOTE" "client_id=$id" "client_secret=$secret" --non-interactive >/dev/null 2>"$TMP/cid.err" ||
      { err "Could not save the credentials."; rclone_error "$TMP/cid.err"; pause; return 1; }
    info "Saved. Now authorise again in the browser so the login is issued for your client."
    info "Google's 'app not verified' warning is expected (it is your own app): Advanced → Go to …"
    cursor on; rclone config reconnect "$REMOTE:"; cursor off
  else
    args=(config create "$REMOTE" drive scope=drive "client_id=$id" "client_secret=$secret")
    headless && args+=(config_is_local=false)
    cursor on; rclone "${args[@]}"; cursor off; save_config
  fi
  test_remote
}

setup_remote() {
  local -a items args names; local r i
  while :; do
    items=()
    [[ -n $(remote_type) ]] && items+=("d|Done|use '$REMOTE' and go back")
    items+=("n|New connection|authorise Google Drive in the browser (creates remote '$REMOTE')"
      "w|rclone wizard|full 'rclone config' (own client id, shared drives, …)")
    mapfile -t names < <(rclone listremotes 2>/dev/null | sed 's/:$//')
    ((${#names[@]})) && items+=("e|Use existing|choose one of: ${names[*]}")
    [[ -n $(remote_type) ]] && items+=("t|Test|check the connection and the library root")
    items+=("r|Reconnect|refresh an expired authorisation for '$REMOTE'"
      "i|Own client ID|use your own Google API credentials (private quota, faster)")
    run_menu remote_hdr "${items[@]}"
    cls
    case $MENU_KEY in
      n)
        ask "Name for the new remote: " "$REMOTE"
        [[ $REPLY =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*$ ]] || { err "Invalid name."; pause; continue; }
        REMOTE=$REPLY
        args=(config create "$REMOTE" drive scope=drive)
        headless && args+=(config_is_local=false)
        info "A browser window will open to authorise access (scope: full Drive, needed to see existing files)."
        headless && info "Headless session: run the 'rclone authorize' command it prints on a machine with a browser."
        cursor on; rclone "${args[@]}"; cursor off
        save_config; test_remote && return 0 ;;
      w) cursor on; rclone config; cursor off; test_remote && return 0 ;;
      e)
        items=(); for i in "${!names[@]}"; do ((i < 9)) && items+=("$((i + 1))|${names[i]}|"); done
        run_menu remote_hdr "${items[@]}"
        [[ $MENU_KEY == q ]] && continue
        REMOTE=${names[MENU_KEY - 1]}; save_config; cls; test_remote && return 0 ;;
      t) test_remote && return 0 ;;
      r) cursor on; rclone config reconnect "$REMOTE:"; cursor off; test_remote && return 0 ;;
      i) own_client_id && return 0 ;;
      d | q) [[ -n $(remote_type) ]] && return 0; return 1 ;;
    esac
  done
}

test_remote() {
  base_flags
  info "Testing $REMOTE: …"
  if ! rclone lsf --dirs-only "${BASE[@]}" -- "$REMOTE:" >"$TMP/top" 2>"$TMP/top.err"; then
    err "Cannot reach $REMOTE:"; rclone_error "$TMP/top.err"; pause; return 1
  fi
  ok "Connected. Top-level folders: $(tr '\n' ' ' <"$TMP/top" | cut -c1-200)"
  if rclone lsf --dirs-only --max-depth 1 "${BASE[@]}" -- "$(rpath)" >/dev/null 2>&1; then
    ok "Library root $(rpath) found."
  else
    warn "$(rpath) does not exist."
    if yesno " Browse Drive to choose the library root?" y; then DIRCACHE=(); browse_folders root; fi
  fi
  pause
}

# --------------------------------------------------------------- sioyek --
sioyek_paths() {
  local cfg=${XDG_CONFIG_HOME:-$HOME/.config} data=${XDG_DATA_HOME:-$HOME/.local/share}
  SY_PREFS=$cfg/sioyek/prefs_user.config SY_DB=$data/sioyek/shared.db SY_FLATPAK=0
  if ! have sioyek && have flatpak && flatpak info com.github.ahrm.sioyek >/dev/null 2>&1; then
    SY_PREFS=$HOME/.var/app/com.github.ahrm.sioyek/config/sioyek/prefs_user.config
    SY_DB=$HOME/.var/app/com.github.ahrm.sioyek/data/sioyek/shared.db
    SY_FLATPAK=1
  fi
}

# Run against a copy of the local shared.db, this prints the SQL that merges r (remote) into it,
# given b (the database as it was after the last sync). Rows are compared by content (every column
# but the rowid key): added on the remote = r EXCEPT b, deleted on the remote = b EXCEPT r. On a
# unique-key clash the local row wins, except in opened_books, where the latest reading position
# wins. Keep identical to $SioyekMergeSql in library.ps1.
read -r -d '' SIOYEK_MERGE_SQL <<'EOF'
WITH c AS (
  SELECT t.name AS tbl,
    group_concat('"' || p.name || '"', ',') AS cols,
    group_concat('x."' || p.name || '" IS d."' || p.name || '"', ' AND ') AS eq
  FROM sqlite_master AS t, pragma_table_info(t.name) AS p
  WHERE t.type = 'table' AND t.name NOT LIKE 'sqlite%' AND p.pk = 0
  GROUP BY t.name)
SELECT
  printf('CREATE TABLE IF NOT EXISTS b."%s" AS SELECT * FROM main."%s" WHERE 0;', tbl, tbl) || char(10) ||
  printf('DELETE FROM main."%s" AS x WHERE EXISTS (SELECT 1 FROM (SELECT %s FROM b."%s" EXCEPT SELECT %s FROM r."%s") AS d WHERE %s);',
    tbl, cols, tbl, cols, tbl, eq) || char(10) ||
  printf('INSERT OR IGNORE INTO main."%s" (%s) SELECT %s FROM r."%s" EXCEPT SELECT %s FROM b."%s" EXCEPT SELECT %s FROM main."%s";',
    tbl, cols, cols, tbl, cols, tbl, cols, tbl) ||
  CASE WHEN tbl = 'opened_books' AND cols LIKE '%"path"%' AND cols LIKE '%"last_access_time"%' THEN char(10) ||
    printf('UPDATE main.opened_books AS x SET (%s) = (SELECT %s FROM r.opened_books AS d WHERE d.path IS x.path) WHERE EXISTS (SELECT 1 FROM r.opened_books AS d WHERE d.path IS x.path AND d.last_access_time > x.last_access_time);',
      cols, cols)
  ELSE '' END
FROM c;
EOF

db_schema() { sqlite3 -bail -batch "$1" "SELECT type || ' ' || name || ' ' || sql FROM sqlite_master WHERE name NOT LIKE 'sqlite%' ORDER BY name;" 2>/dev/null; }
sql_string() { local s=$1; printf "'%s'" "${s//\'/\'\'}"; }
sioyek_base() { printf '%s/sioyek-base.db' "$CFG_DIR"; }

# After every successful sync the local shared.db equals the remote one: keep it as the merge base.
save_sioyek_base() {
  [[ " ${FOLDERS[*]} " == *" $ANNOT_DIR "* && -f $LIBRARY_ROOT/$ANNOT_DIR/shared.db ]] || return 0
  cp -p -- "$LIBRARY_ROOT/$ANNOT_DIR/shared.db" "$(sioyek_base)"
}

# sioyek_merge LOCAL_TRASH REMOTE_TRASH
# Pull/Merge with shared.db changed: merge the remote database into the local one and upload the
# result, so the following rclone run finds both sides identical. Returns 1 only on failure; when
# it can't merge, the newer shared.db wins as before.
sioyek_merge() {
  local rel=$ANNOT_DIR/shared.db ldb=$LIBRARY_ROOT/$ANNOT_DIR/shared.db base b schema gen
  local remote=$TMP/remote-shared.db merged=$TMP/merged-shared.db
  base=$(sioyek_base) b=$TMP/base-shared.db
  # sioyek doesn't run on Android, so its copy never has changes of its own.
  ((TERMUX)) && return 0
  [[ -f $ldb ]] || return 0
  # Unchanged here since the last sync: the remote copy already holds everything.
  [[ -f $base ]] && cmp -s -- "$ldb" "$base" && return 0
  if ! have sqlite3; then
    warn "sqlite3 is not installed, so the newer shared.db replaces the other (Settings → Dependencies installs it)."
    return 0
  fi
  info "Merging sioyek annotations from both sides…"
  base_flags
  rclone copyto "${BASE[@]}" -- "$(rpath "$rel")" "$remote" </dev/null 2>"$TMP/merge.err" ||
    { err "Could not download $rel from the remote:"; rclone_error "$TMP/merge.err"; return 1; }
  schema=$(db_schema "$ldb")
  if [[ -z $schema || $schema != "$(db_schema "$remote")" ]]; then
    warn "The two shared.db files come from different sioyek versions and cannot be merged - the newer one wins."
    return 0
  fi
  # Without a usable base every row on either side counts as new: nothing gets deleted.
  [[ -f $base ]] && cp -- "$base" "$b" && [[ $(db_schema "$b") == "$schema" ]] || b=:memory:
  cp -- "$ldb" "$merged"
  if ! gen=$(sqlite3 -bail -batch "$merged" <<<"$SIOYEK_MERGE_SQL" 2>"$TMP/merge.err") ||
    ! printf 'ATTACH %s AS r;\nATTACH %s AS b;\nBEGIN;\n%s\nCOMMIT;\n' "$(sql_string "$remote")" "$(sql_string "$b")" "$gen" |
    sqlite3 -bail -batch "$merged" 2>"$TMP/merge.err"; then
    err "Merging the annotation databases failed: $(cat -- "$TMP/merge.err")"; return 1
  fi
  mkdir -p -- "$1/$ANNOT_DIR" && cp -p -- "$ldb" "$1/$ANNOT_DIR/shared.db" && cp -- "$merged" "$ldb" ||
    { err "Could not replace $(tildify "$ldb")."; return 1; }
  rclone copyto "${BASE[@]}" --backup-dir "$2/$ANNOT_DIR" -- "$ldb" "$(rpath "$rel")" </dev/null 2>"$TMP/merge.err" ||
    { err "Merged locally, but uploading $rel failed:"; rclone_error "$TMP/merge.err"; return 1; }
  ok "Merged sioyek annotations (previous copies kept in trash)."; log_line "merged sioyek annotations"
}

# The flatpak sandbox can't see the library unless allowed to; sioyek would then silently fall
# back to an empty database. Idempotent, so it is safe to run on every setup.
sioyek_flatpak_access() {
  ((SY_FLATPAK)) || return 0
  if flatpak override --user --filesystem="$LIBRARY_ROOT" com.github.ahrm.sioyek 2>/dev/null; then
    ok "Allowed the sioyek flatpak to access $(tildify "$LIBRARY_ROOT")"
  else
    warn "Could not grant the sioyek flatpak access - run: flatpak override --user --filesystem=$LIBRARY_ROOT com.github.ahrm.sioyek"
  fi
}

sioyek_setup() {
  local target=$LIBRARY_ROOT/$ANNOT_DIR/shared.db current f
  sioyek_paths; cls
  current=$(grep -E '^[[:space:]]*shared_database_path' "$SY_PREFS" 2>/dev/null | tail -n1 | sed -E 's/^[[:space:]]*shared_database_path[[:space:]]+//')
  printf ' %sSioyek annotations%s\n\n' "$CB" "$C0"
  say " sioyek stores highlights/bookmarks in shared.db, keyed by file content (works across devices)."
  say " prefs file : $(tildify "$SY_PREFS")"
  say " current db : ${current:-$(tildify "$SY_DB") (default)}"
  say " library db : $(tildify "$target")"
  say
  if [[ $current == "$target" ]]; then ok "Already pointing at the library."; sioyek_flatpak_access; pause; return; fi
  yesno " Point sioyek's shared.db at the library folder?" y || return
  if sioyek_running; then warn "Close sioyek first."; pause; return; fi
  mkdir -p -- "$(dirname -- "$target")" "$(dirname -- "$SY_PREFS")"
  if [[ ! -f $target ]]; then
    base_flags
    if rclone lsf "${BASE[@]}" -- "$(rpath "$ANNOT_DIR/shared.db")" 2>/dev/null | grep -q .; then
      info "The remote already has $ANNOT_DIR/shared.db - pull to get it (not copying the local one)."
    elif [[ -f ${current:-$SY_DB} ]] && yesno " Copy your existing annotations ($(tildify "${current:-$SY_DB}")) into the library?" y; then
      cp -p -- "${current:-$SY_DB}" "$target" && ok "Copied."
    fi
  fi
  [[ -f $SY_PREFS ]] && cp -p -- "$SY_PREFS" "$SY_PREFS.bak"
  { grep -vE '^[[:space:]]*shared_database_path' "$SY_PREFS" 2>/dev/null; say "shared_database_path $target"; } | write_atomic "$SY_PREFS"
  ok "Updated $(tildify "$SY_PREFS") (backup: .bak)"
  sioyek_flatpak_access
  if [[ " ${FOLDERS[*]} " != *" $ANNOT_DIR "* ]]; then FOLDERS+=("$ANNOT_DIR"); save_config; ok "Added '$ANNOT_DIR' to synced folders."; fi
  if have sqlite3; then info "Pull and Merge combine annotations made on different devices; Push overwrites the remote shared.db with this one."
  else warn "sqlite3 is not installed: if two devices annotate before syncing, the newer shared.db wins (Settings → Dependencies installs it)."; fi
  pause
}

# ------------------------------------------------------------- koreader --
# KOReader keeps each book's highlights, notes, bookmarks and reading position in a metadata file.
# Set to its hash-based folder (koreader/hashdocsettings/<xx>/<partial md5>.sdr/), these files are
# named by the book's content, so they match on every device, like sioyek's database. Before every
# listing, what KOReader changed is copied into $KO_DIR/ in the library (the synced copy); after
# every sync, what the sync changed is copied back. On Pull and Merge, files changed on both sides
# are merged by the Lua program below.
#
# koreader-state (KS_*) remembers per file what was last copied either way: the MD5 of KOReader's
# file, the MD5 of the synced copy it matched, and the marker last written into KOReader's file.
# KOReader keeps unknown keys, so a file it saves still carries the marker it was loaded with: a
# different one means it was saved from a book left open since before the last sync, and is merged
# in rather than copied over newer data.
read -r -d '' KO_LUA <<'EOF'
-- komerge.lua - KOReader book-metadata helper for library.sh (Lua 5.1-5.4 / LuaJIT)
--   canon IN OUT HEADER         rewrite a sidecar canonically without this device's flags; prints its marker or -
--   stamp IN OUT HEADER MARKER  write a synced sidecar into KOReader's folder, tagged with MARKER and
--                               keeping the layout settings OUT already has on this device
--   merge OUT HEADER L R B LTIME RTIME POLICY [ANSWERS]
--                               three-way merge of L (here) and R (remote) given B (last sync, "-" = none);
--                               POLICY newer|local|remote|ask. With ask and no ANSWERS the conflicts are
--                               printed (id TAB what TAB here TAB remote) and the exit status is 3.
--   get IN KEY                  print a top-level value (reads settings.reader.lua)
-- Files are written the way KOReader's dump() writes them, so unchanged data gives identical bytes.

local MARK, FLAG = "library_sync", "annotations_externally_modified"
-- Reading progress and book status follow the reader from device to device; every other key
-- (fonts, margins, zoom, page counts, statistics) stays as each device has it.
local SYNCED = { last_xpointer = true, last_epubcfi = true, last_page = true, page_positions = true,
  percent_finished = true, summary = true }
-- Recomputed by KOReader from each device's layout, so they are ignored when comparing annotations.
local DERIVED = { pageno = true, pageref = true }

local function fail(msg) io.stderr:write("komerge: ", tostring(msg), "\n"); os.exit(1) end

local function read_table(path)
  local f = io.open(path, "rb")
  if not f then return nil, "cannot read " .. path end
  local s = f:read("*a"); f:close()
  if s:byte(1) == 27 then return nil, path .. ": precompiled chunk refused" end
  -- No globals: the file can build its table and nothing else.
  local fn, err
  if setfenv then
    fn, err = loadstring(s, "=" .. path)
    if fn then setfenv(fn, {}) end
  else
    fn, err = load(s, "=" .. path, "t", {})
  end
  if not fn then return nil, err end
  local ok, t = pcall(fn)
  if not ok then return nil, tostring(t) end
  if type(t) ~= "table" then return nil, path .. ": not a KOReader metadata file" end
  return t
end

local function load_table(path)
  local t, err = read_table(path)
  if not t then fail(err) end
  return t
end

local function num(n) return string.format("%.14g", n) end -- LuaJIT's tostring() for numbers

-- string.format("%q") as LuaJIT does it: control characters as decimal escapes.
local function quote(s)
  return '"' .. s:gsub('([%c"\\])(%d?)', function(c, d)
    local b = c:byte()
    if b == 34 or b == 92 or b == 10 then return "\\" .. c .. d end
    if b >= 100 or d ~= "" then return string.format("\\%03d", b) .. d end
    return "\\" .. b .. d
  end) .. '"'
end

local function key_str(k) return type(k) == "number" and num(k) or tostring(k) end

local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b)
    local ta, tb = type(a), type(b)
    if ta == tb and (ta == "number" or ta == "string") then return a < b end
    return key_str(a) < key_str(b)
  end)
  return ks
end

local function dump(v, indent, out)
  local t = type(v)
  if t == "table" then
    local ks = sorted_keys(v)
    out[#out + 1] = "{"
    for _, k in ipairs(ks) do
      out[#out + 1] = "\n" .. string.rep("    ", indent + 1) .. "["
      dump(k, indent + 1, out)
      out[#out + 1] = "] = "
      dump(v[k], indent + 1, out)
      out[#out + 1] = ","
    end
    if #ks > 0 then out[#out + 1] = "\n" .. string.rep("    ", indent) end
    out[#out + 1] = "}"
  elseif t == "string" then out[#out + 1] = quote(v)
  elseif t == "number" then out[#out + 1] = num(v)
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  else out[#out + 1] = "nil" end
end

local function write_table(path, header, t)
  local out = { header, "\nreturn " }
  dump(t, 0, out)
  out[#out + 1] = "\n"
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then fail("cannot write " .. path) end
  f:write(table.concat(out)); f:close()
  local ok, err = os.rename(tmp, path) -- atomic: KOReader never sees a half-written file
  if not ok then fail(err) end
end

local function eq(a, b, skip)
  if a == b then return true end
  local ta, tb = type(a), type(b)
  if ta == "number" and tb == "number" then return num(a) == num(b) end
  if ta ~= "table" or tb ~= "table" then return false end
  for k, v in pairs(a) do
    if not (skip and skip[k]) and not eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if not (skip and skip[k]) and a[k] == nil then return false end
  end
  return true
end

-- ----------------------------------------------------------------- describe --
local function clip(s, n)
  s = tostring(s or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #s > n then s = s:sub(1, n):gsub("[\192-\255][\128-\191]*$", "") .. "…" end
  return s
end

local function title_of(t)
  local p = type(t.doc_props) == "table" and t.doc_props.title or type(t.stats) == "table" and t.stats.title
  if type(p) == "string" and p ~= "" then return p end
  return type(t.doc_path) == "string" and t.doc_path:match("[^/]*$") or "?"
end

local function where(a)
  local p = a.pageno or (type(a.page) == "number" and a.page)
  if p then return "p. " .. key_str(p) end
  return a.chapter and clip(a.chapter, 30) or "?"
end

local function describe_ann(a)
  local s = a.drawer and ('"' .. clip(a.text, 50) .. '"') or "bookmark"
  if a.note and a.note ~= "" then s = s .. "  note: " .. clip(a.note, 50) end
  if a.color then s = s .. "  " .. tostring(a.color) end
  return s .. "  (" .. tostring(a.datetime_updated or a.datetime or "?") .. ")"
end

local function describe_progress(t)
  local s = {}
  if type(t.percent_finished) == "number" then s[#s + 1] = string.format("%.0f%%", t.percent_finished * 100) end
  if type(t.last_page) == "number" then s[#s + 1] = "page " .. key_str(t.last_page) end
  if type(t.summary) == "table" and t.summary.status then s[#s + 1] = tostring(t.summary.status) end
  return #s > 0 and table.concat(s, ", ") or "-"
end

-- -------------------------------------------------------------------- merge --
-- Annotations are matched the way KOReader's own import matches them: highlight or bookmark,
-- same page and same start/end position.
local function pos(p)
  if type(p) == "table" then return key_str(p.page) .. ":" .. key_str(p.x) .. ":" .. key_str(p.y) end
  return p == nil and "" or key_str(p)
end

local function index(list)
  local map, order, seen = {}, {}, {}
  for _, a in ipairs(type(list) == "table" and list or {}) do
    if type(a) == "table" then
      local k = (a.drawer and "h" or "b") .. "|" .. pos(a.page) .. "|" .. pos(a.pos0) .. "|" .. pos(a.pos1)
      seen[k] = (seen[k] or 0) + 1
      if seen[k] > 1 then k = k .. "#" .. seen[k] end
      map[k] = a; order[#order + 1] = k
    end
  end
  return map, order
end

local function stamp_of(a) return tostring(a.datetime_updated or a.datetime or "") end

local function copy(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return c end

-- Keep both notes, in the newer version of the highlight.
local function both(l, r)
  local remote_newer = stamp_of(r) > stamp_of(l)
  local c = copy(remote_newer and r or l)
  if l.note and r.note and l.note ~= r.note then c.note = l.note .. "\n\n" .. r.note
  else c.note = l.note or r.note end
  c.datetime_updated = remote_newer and r.datetime_updated or l.datetime_updated
  return c
end

local function merge(L, R, B, ltime, rtime, policy, answers, conflicts)
  local has_base = B ~= nil
  B = B or {}
  local title = title_of(L)
  local function decide(id, what, here, remote, l_newer)
    local a = answers[id]
    if policy == "ask" and not a then
      conflicts[#conflicts + 1] = table.concat({ id, title .. " · " .. what, here, remote }, "\t")
    end
    a = a or policy
    if a == "l" or a == "local" then return "l" end
    if a == "r" or a == "remote" then return "r" end
    if a == "b" then return "b" end
    return l_newer and "l" or "r"
  end

  local out = {}
  -- Annotations, one by one.
  if L.annotations ~= nil or R.annotations ~= nil then
    local lm, lo = index(L.annotations)
    local rm, ro = index(R.annotations)
    local bm = index(B.annotations)
    local list = {}
    for _, k in ipairs(lo) do
      local l, r, b = lm[k], rm[k], has_base and bm[k] or nil
      local keep = l
      if r then
        if eq(l, r, DERIVED) or (b and eq(r, b, DERIVED)) then keep = l
        elseif b and eq(l, b, DERIVED) then keep = r
        else
          local c = decide("a:" .. k, where(l), describe_ann(l), describe_ann(r), stamp_of(l) >= stamp_of(r))
          keep = c == "b" and both(l, r) or c == "r" and r or l
        end
      elseif b and eq(l, b, DERIVED) then
        keep = nil -- deleted on the remote; kept when it was also edited here
      end
      if keep then list[#list + 1] = keep end
    end
    for _, k in ipairs(ro) do
      if lm[k] == nil and not (has_base and bm[k] and eq(rm[k], bm[k], DERIVED)) then
        list[#list + 1] = rm[k] -- new on the remote (or edited there and deleted here)
      end
    end
    out.annotations = list
  end

  -- Progress and status: three-way per key; conflicting keys are settled together.
  local pending = {}
  for _, t in ipairs({ L, R }) do
    for k in pairs(t) do
      if SYNCED[k] and out[k] == nil and pending[k] == nil then
        local l, r, b = L[k], R[k], B[k]
        if eq(l, r) or (has_base and eq(r, b)) or (not has_base and r == nil) then out[k] = l
        elseif (has_base and eq(l, b)) or (not has_base and l == nil) then out[k] = r
        else pending[k] = true end
      end
    end
  end
  if next(pending) then
    local c = decide("progress", "reading position and status",
      describe_progress(L), describe_progress(R), ltime >= rtime)
    for k in pairs(pending) do out[k] = (c == "r" and R or L)[k] end
  end

  -- Everything else is this device's; the remote fills in only what this device lacks.
  for _, t in ipairs({ L, R }) do
    for k, v in pairs(t) do
      if k ~= "annotations" and not SYNCED[k] and k ~= MARK and k ~= FLAG and out[k] == nil then out[k] = v end
    end
  end
  return out
end

-- --------------------------------------------------------------------- main --
local mode = arg[1]
if mode == "canon" then
  local t = load_table(arg[2])
  local m = t[MARK]
  t[MARK], t[FLAG] = nil, nil
  write_table(arg[3], arg[4], t)
  print(type(m) == "string" and m or "-")
elseif mode == "stamp" then
  local t = load_table(arg[2])
  -- The synced copy carries the layout of whichever device synced it last; keep this device's.
  local own = read_table(arg[3])
  for k, v in pairs(own or {}) do
    if k ~= "annotations" and not SYNCED[k] and k ~= MARK and k ~= FLAG then t[k] = v end
  end
  t[MARK] = arg[5]
  -- Makes KOReader recompute page numbers and re-sort the annotations when it opens the book.
  if type(t.annotations) == "table" and #t.annotations > 0 then t[FLAG] = true end
  write_table(arg[3], arg[4], t)
elseif mode == "merge" then
  local out_path, header, policy = arg[2], arg[3], arg[9]
  local L, R = load_table(arg[4]), load_table(arg[5])
  local B = arg[6] ~= "-" and load_table(arg[6]) or nil
  local answers = {}
  if arg[10] then
    local f = io.open(arg[10], "rb")
    if f then
      for line in f:lines() do
        local id, a = line:match("^(.-)\t(.*)$")
        if id then answers[id] = a end
      end
      f:close()
    end
  end
  local conflicts = {}
  local out = merge(L, R, B, arg[7] or "", arg[8] or "", policy, answers, conflicts)
  if #conflicts > 0 then
    for _, c in ipairs(conflicts) do print(c) end
    os.exit(3)
  end
  write_table(out_path, header, out)
elseif mode == "get" then
  local v = load_table(arg[2])[arg[3]]
  if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then print(tostring(v)) end
else
  fail("usage: komerge.lua canon|stamp|merge|get ...")
end
EOF

lua_bin() {
  local b
  for b in lua5.4 lua54 lua5.3 lua53 lua luajit lua5.2 lua5.1; do have "$b" && { printf '%s' "$b"; return 0; }; done
  return 1
}

ko_lua() {
  local l; l=$(lua_bin) || return 1
  [[ -f $TMP/komerge.lua ]] || printf '%s\n' "$KO_LUA" >"$TMP/komerge.lua"
  "$l" "$TMP/komerge.lua" "$@"
}

ko_synced() { [[ " ${FOLDERS[*]} " == *" $KO_DIR "* ]]; }
ko_on() { [[ -n $KOREADER_DIR ]] && ko_synced; }
ko_live() { printf '%s/hashdocsettings' "$KOREADER_DIR"; }
ko_base() { printf '%s/koreader-base' "$CFG_DIR"; }
ko_meta() { [[ ${1##*/} == metadata.*.lua ]]; }
ko_location() { ko_lua get "$KOREADER_DIR/settings.reader.lua" document_metadata_folder 2>/dev/null; }
md5_of() { md5sum -- "$1" 2>/dev/null | cut -d' ' -f1; }

ko_policy_desc() {
  case $1 in
    local) printf "this device's copy wins" ;; remote) printf "the remote copy wins" ;;
    ask) printf 'ask for each' ;; *) printf 'the newer edit wins' ;;
  esac
}
ko_next_policy() { case $1 in newer) echo local ;; local) echo remote ;; remote) echo ask ;; *) echo newer ;; esac; }

# ko_ready [quiet]: KOReader is synced on this device and everything it needs is in place.
ko_ready() {
  local why=
  ko_on || return 1
  if ! lua_bin >/dev/null; then why="Lua is not installed (Settings → KOReader installs it)"
  elif [[ ! -r $KOREADER_DIR/settings.reader.lua ]]; then
    why="$(tildify "$KOREADER_DIR")/settings.reader.lua can't be read"
    ((TERMUX)) && why+=" (Android settings → Apps → Termux → Permissions → Files: allow all files)"
  elif [[ $(ko_location) != hash ]]; then
    why="KOReader doesn't keep book metadata in its hash-based folder (Settings → KOReader says how to switch)"
  fi
  [[ -z $why ]] && return 0
  [[ ${1:-} == quiet ]] || warn "KOReader is not synced on this device: $why."
  return 1
}

# ko_sums DIR: "MD5 TAB path" for every file in DIR's .sdr folders (KOReader's .old backups excluded).
ko_sums() {
  [[ -d $1 ]] || return 0
  (cd -- "$1" && find . -path './*.sdr/*' -type f ! -name '*.old' ! -name '*.tmp' -print0 | xargs -0 -r md5sum --) |
    sed -n 's|^\([0-9a-f]\{32\}\)  \./|\1\t|p'
}

ko_state_load() {
  local p a b m
  KS_LIVE=() KS_STAGE=() KS_MARK=()
  [[ -f $KO_STATE ]] || return 0
  while IFS=$'\t' read -r p a b m; do [[ -n $p ]] && KS_LIVE[$p]=$a KS_STAGE[$p]=$b KS_MARK[$p]=$m; done <"$KO_STATE"
}

ko_state_save() {
  local p live; live=$(ko_live)
  for p in "${!KS_LIVE[@]}"; do
    # "-" for empty: read would merge two tabs into one and shift the fields.
    [[ -e $live/$p || -e $LIBRARY_ROOT/$KO_DIR/$p ]] &&
      printf '%s\t%s\t%s\t%s\n' "$p" "${KS_LIVE[$p]:--}" "${KS_STAGE[$p]:--}" "${KS_MARK[$p]:--}"
  done | write_atomic "$KO_STATE"
}

# koreader_import [quiet]: copy what KOReader changed since the last look into the synced folder.
koreader_import() {
  local quiet=${1:-} live stage sum rel l s mark held n=0 m=0
  ko_ready "$quiet" || return 0
  live=$(ko_live) stage=$LIBRARY_ROOT/$KO_DIR
  [[ -d $live ]] || return 0
  ko_state_load
  while IFS=$'\t' read -r sum rel; do
    [[ ${KS_LIVE[$rel]-} == "$sum" ]] && continue
    l=$live/$rel s=$stage/$rel
    mkdir -p -- "${s%/*}" || return 1
    if ! ko_meta "$rel"; then
      { cp -- "$l" "$s.tmp" && mv -f -- "$s.tmp" "$s"; } || continue
      held=$(md5_of "$s")
    elif ! mark=$(ko_lua canon "$l" "$s.in.tmp" "-- $KO_DIR/$rel" 2>"$TMP/ko.err"); then
      [[ -n $quiet ]] || warn "Skipped $(tildify "$l"): $(head -c 300 -- "$TMP/ko.err")"
      rm -f -- "$s.in.tmp"; continue
    else
      held=$(md5_of "$s.in.tmp")
      if [[ ! -f $s ]] ||
        { [[ -n ${KS_STAGE[$rel]+x} && ${KS_MARK[$rel]:--} == "$mark" && $(md5_of "$s") == "${KS_STAGE[$rel]}" ]]; }; then
        mv -f -- "$s.in.tmp" "$s" || continue
      else
        # Saved from an older copy: keep what either side has (the "newer" side is KOReader's file).
        # KOReader's file still holds only its own side, so the next export writes the merge back.
        if ! ko_lua merge "$s" "-- $KO_DIR/$rel" "$s.in.tmp" "$s" - 1 0 newer 2>"$TMP/ko.err"; then
          [[ -n $quiet ]] || warn "Skipped $(tildify "$l"): $(head -c 300 -- "$TMP/ko.err")"
          rm -f -- "$s.in.tmp"; continue
        fi
        rm -f -- "$s.in.tmp"; ((++m))
        log_line "koreader: merged $rel, saved by KOReader from a copy older than the last sync"
      fi
    fi
    touch -r "$l" -- "$s" 2>/dev/null
    KS_LIVE[$rel]=$sum KS_STAGE[$rel]=$held; ((++n))
  done < <(ko_sums "$live")
  ((n)) || return 0
  ko_state_save
  [[ -n $quiet ]] && return 0
  info "KOReader: $n changed file(s) copied into $(tildify "$stage")"
  ((m)) && info "KOReader: $m of them were saved by a book left open during the last sync - merged, nothing lost."
  return 0
}

# koreader_export: after a sync, copy what changed in the synced folder into KOReader's. A file
# KOReader changed in the meantime is left for the next import to merge; one it deleted stays deleted.
koreader_export() {
  local live stage sum rel l s mark n=0
  ko_ready quiet || return 0
  live=$(ko_live) stage=$LIBRARY_ROOT/$KO_DIR
  ko_state_load
  while IFS=$'\t' read -r sum rel; do
    [[ ${KS_STAGE[$rel]-} == "$sum" ]] && continue
    l=$live/$rel s=$stage/$rel
    if [[ -e $l ]]; then
      [[ -n ${KS_LIVE[$rel]+x} && $(md5_of "$l") == "${KS_LIVE[$rel]}" ]] || continue
    else
      [[ -n ${KS_LIVE[$rel]+x} ]] && continue
    fi
    mkdir -p -- "${l%/*}" || continue
    if ko_meta "$rel"; then
      mark=$HOST.$(date +%s).$RANDOM
      if ! ko_lua stamp "$s" "$l" "-- $l" "$mark" 2>"$TMP/ko.err"; then
        warn "Could not update $(tildify "$l"): $(head -c 300 -- "$TMP/ko.err")"; continue
      fi
      KS_MARK[$rel]=$mark
    else
      { cp -- "$s" "$l.tmp" && mv -f -- "$l.tmp" "$l"; } || continue
    fi
    KS_LIVE[$rel]=$(md5_of "$l") KS_STAGE[$rel]=$sum; ((++n))
  done < <(ko_sums "$stage")
  ((n)) || return 0
  ko_state_save
  ok "KOReader: updated $n file(s) in $(tildify "$live") - a book open in KOReader shows the changes once reopened."
  log_line "koreader: updated $n file(s) in KOReader's folder"
}

# ko_pending OP -> "CHANGED NEW": metadata files that differ from the remote and changed here since
# the last sync (merged), and, on Pull, those first created here since then (uploaded, not removed).
ko_pending() {
  local c p b n=0 k=0
  if ko_synced; then
    while IFS=$'\t' read -r c p; do
      ko_meta "$p" || continue
      b=$(ko_base)/${p#"$KO_DIR"/}
      if [[ $c == ladd ]]; then [[ $1 == pull && ! -e $b ]] && ((++k))
      elif ! { [[ -f $b ]] && cmp -s -- "$LIBRARY_ROOT/$p" "$b"; }; then ((++n)); fi
    done < <(awk -F'\t' -v OFS='\t' -v d="$KO_DIR/" '
      index($2, d) == 1 && ($1 == "rnew" || $1 == "lnew" || $1 == "size" || $1 == "ladd") {print $1, $2}' "$TMP/diff")
  fi
  echo "$n $k"
}

# ko_ask CONFLICTS ANSWERS: one question per conflict; L/R/N settle the rest of this sync at once.
ko_ask() {
  local id what here remote a i=0 n w
  n=$(wc -l <"$1"); : >"$2"; term_size
  w=$((TW > 40 ? TW - 12 : 60))
  while IFS=$'\t' read -r -u 3 id what here remote; do
    ((++i)); a=$KO_ALL
    if [[ -z $a ]]; then
      printf '\n %sKOReader conflict %d/%d%s  %s\n' "$CY" "$i" "$n" "$C0" "$what"
      printf '   %shere  %s  %s\n   %sremote%s  %s\n' "$CB" "$C0" "${here:0:w}" "$CB" "$C0" "${remote:0:w}"
      printf '   %sl%s this device  %sr%s remote  %sn%s newer' "$CB" "$C0" "$CB" "$C0" "$CB" "$C0"
      [[ $id == a:* ]] && printf '  %sb%s both notes' "$CB" "$C0"
      printf '  %sL/R/N%s same for all remaining  %sq%s cancel the sync ' "$CB" "$C0" "$CB" "$C0"
      while :; do
        read_key
        case $KEY in
          l | r) a=$KEY ;; n) a=newer ;; b) [[ $id == a:* ]] && a=b ;;
          L | R) KO_ALL=${KEY,}; a=$KO_ALL ;; N) KO_ALL=newer; a=newer ;;
          q | esc) say; return 1 ;;
        esac
        [[ -n $a ]] && { say "$a"; break; }
      done
    fi
    printf '%s\t%s\n' "$id" "$a" >>"$2"
  done 3<"$1"
}

# ko_merge_file OUT REL LOCAL REMOTE BASE LTIME RTIME: 0 merged, 1 can't merge this file, 2 cancelled.
ko_merge_file() {
  local hdr="-- $KO_DIR/$2" rc
  ko_lua merge "$1" "$hdr" "$3" "$4" "$5" "$6" "$7" "$KO_POLICY" >"$TMP/ko-conflicts" 2>"$TMP/ko.err"
  rc=$?
  ((rc == 3)) || return $((rc ? 1 : 0))
  ko_ask "$TMP/ko-conflicts" "$TMP/ko-answers" || return 2
  ko_lua merge "$1" "$hdr" "$3" "$4" "$5" "$6" "$7" ask "$TMP/ko-answers" 2>"$TMP/ko.err" || return 1
}

# After every successful sync the synced KOReader folder equals the remote one: keep it as the merge base.
save_koreader_base() {
  local src=$LIBRARY_ROOT/$KO_DIR dst; dst=$(ko_base)
  ko_synced || return 0
  rm -rf -- "$dst.tmp" && mkdir -p -- "$dst.tmp" || return 0
  [[ -d $src ]] && (cd -- "$src" && find . -path './*.sdr/metadata.*.lua' -type f -exec cp --parents -t "$dst.tmp" -- {} +)
  rm -rf -- "$dst" && mv -- "$dst.tmp" "$dst"
}

# koreader_merge OP LOCAL_TRASH REMOTE_TRASH
# Pull/Merge: metadata files that differ from the remote and changed here since the last sync are
# merged three-way (base: the synced copy after the last sync) and the result is uploaded, so the
# rclone run that follows finds both sides identical. On Pull, metadata files new here since the
# last sync are uploaded first rather than removed. On Merge, files unchanged here take the remote
# copy: Merge otherwise goes by modification time, and where times can't be kept (Android) a copy
# is dated when it was written, not when KOReader saved it. Returns 1 on failure or when cancelled.
koreader_merge() {
  local op=$1 cat p lt rt rel b i rc n=0 up=$TMP/ko-up
  local -a rels=() lts=() rts=() takes=()
  ko_synced || return 0
  : >"$up"
  while IFS=$'\t' read -r cat p lt rt; do
    rel=${p#"$KO_DIR"/} b=$(ko_base)/$rel
    ko_meta "$rel" || continue
    if [[ $cat == ladd ]]; then
      [[ $op == pull && ! -e $b ]] && printf '%s\n' "$rel" >>"$up"
    elif [[ -f $b ]] && cmp -s -- "$LIBRARY_ROOT/$p" "$b"; then
      [[ $op == merge ]] && takes+=("$rel")  # unchanged here: the remote copy wins (Pull does that anyway)
    else
      rels+=("$rel") lts+=("$lt") rts+=("$rt")
    fi
  done < <(awk -F'\t' -v OFS='\t' -v d="$KO_DIR/" '
    index($2, d) == 1 && ($1 == "rnew" || $1 == "lnew" || $1 == "size" || $1 == "ladd") {print $1, $2, $4, $6}' "$TMP/diff")
  if ((${#rels[@]})) && ! lua_bin >/dev/null; then
    warn "Lua is not installed, so the newer of each KOReader file replaces the other (Settings → KOReader installs it)."
    rels=()
  fi
  ((${#rels[@]} + ${#takes[@]})) || [[ -s $up ]] || return 0
  base_flags
  if ((${#rels[@]} + ${#takes[@]})); then
    printf '%s\n' "${rels[@]}" "${takes[@]}" | grep . >"$TMP/ko-list"
    rm -rf -- "$TMP/ko-remote" "$TMP/ko-merged"
    rclone copy "${BASE[@]}" --files-from "$TMP/ko-list" -- "$(rpath "$KO_DIR")" "$TMP/ko-remote" </dev/null 2>"$TMP/merge.err" ||
      { err "Could not download KOReader files from the remote:"; rclone_error "$TMP/merge.err"; return 1; }
  fi
  if ((${#rels[@]})); then
    info "Merging KOReader highlights, notes and reading progress from both sides…"
    # Merge everything first (questions included), so cancelling changes nothing.
    for i in "${!rels[@]}"; do
      rel=${rels[i]} b=$(ko_base)/$rel
      [[ -f $b ]] || b=-
      mkdir -p -- "$(dirname -- "$TMP/ko-merged/$rel")"
      ko_merge_file "$TMP/ko-merged/$rel" "$rel" "$LIBRARY_ROOT/$KO_DIR/$rel" "$TMP/ko-remote/$rel" "$b" "${lts[i]}" "${rts[i]}"
      rc=$?
      ((rc == 2)) && return 1
      ((rc)) && warn "Could not merge $KO_DIR/$rel, so the newer copy wins: $(head -c 300 -- "$TMP/ko.err")"
    done
  fi
  for rel in "${takes[@]}"; do
    [[ -f $TMP/ko-remote/$rel ]] || continue
    mkdir -p -- "$(dirname -- "$2/$KO_DIR/$rel")" && cp -- "$LIBRARY_ROOT/$KO_DIR/$rel" "$2/$KO_DIR/$rel" &&
      cp -p -- "$TMP/ko-remote/$rel" "$LIBRARY_ROOT/$KO_DIR/$rel" 2>/dev/null ||
      cmp -s -- "$TMP/ko-remote/$rel" "$LIBRARY_ROOT/$KO_DIR/$rel" || { err "Could not replace $KO_DIR/$rel."; return 1; }
  done
  for rel in "${rels[@]}"; do
    [[ -f $TMP/ko-merged/$rel ]] || continue
    # The merged copy is as new as the newer of the two (that is what "newer wins" compares next time).
    b=$LIBRARY_ROOT/$KO_DIR/$rel
    [[ $TMP/ko-remote/$rel -nt $b ]] && b=$TMP/ko-remote/$rel
    touch -r "$b" -- "$TMP/ko-merged/$rel" 2>/dev/null
    mkdir -p -- "$(dirname -- "$2/$KO_DIR/$rel")" && cp -- "$LIBRARY_ROOT/$KO_DIR/$rel" "$2/$KO_DIR/$rel" &&
      cp -p -- "$TMP/ko-merged/$rel" "$LIBRARY_ROOT/$KO_DIR/$rel" 2>/dev/null ||
      cmp -s -- "$TMP/ko-merged/$rel" "$LIBRARY_ROOT/$KO_DIR/$rel" || { err "Could not replace $KO_DIR/$rel."; return 1; }
    printf '%s\n' "$rel" >>"$up"; ((++n))
  done
  if [[ -s $up ]]; then
    rclone copy "${BASE[@]}" --files-from "$up" --backup-dir "$3/$KO_DIR" -- "$LIBRARY_ROOT/$KO_DIR" "$(rpath "$KO_DIR")" </dev/null 2>"$TMP/merge.err" ||
      { err "Uploading the KOReader files failed:"; rclone_error "$TMP/merge.err"; return 1; }
  fi
  ((n)) && { ok "Merged $n KOReader book(s) (previous copies kept in trash)."; log_line "merged $n KOReader book(s)"; }
  return 0
}

koreader_detect() {
  local d; local -a c=()
  ((TERMUX)) && [[ -d $HOME/storage/shared ]] && c+=("$(readlink -f -- "$HOME/storage/shared")/koreader")
  c+=("${XDG_CONFIG_HOME:-$HOME/.config}/koreader" "$HOME/.var/app/rocks.koreader.KOReader/config/koreader")
  for d in "${c[@]}"; do [[ -f $d/settings.reader.lua ]] && { printf '%s' "$d"; return 0; }; done
  return 1
}

install_lua() {
  case $(pkg_manager) in
    termux) confirm_run pkg install -y lua54 ;;
    pacman) confirm_run as_root pacman -S --needed lua ;;
    apt) confirm_run as_root apt-get install -y lua5.4 ;;
    dnf) confirm_run as_root dnf install -y lua ;;
    zypper) confirm_run as_root zypper install -y lua54 ;;
    *) err "Install Lua (5.1 or newer) with your package manager."; return 1 ;;
  esac
}

ko_conflict_hdr() {
  printf ' %sKOReader conflicts%s  now: %s\n\n' "$CB" "$C0" "$(ko_policy_desc "$KO_CONFLICT")"
  say " When a highlight was edited on both devices, or the book was read on both, between two syncs:"
}

koreader_setup() {
  local d loc
  cls
  printf ' %sKOReader%s\n\n' "$CB" "$C0"
  say " KOReader keeps each book's highlights, notes, bookmarks and reading position in a metadata"
  say " file. In its hash-based folder these files are named by the book's content, all in one place."
  say " This tool keeps a copy of them in $(tildify "$LIBRARY_ROOT/$KO_DIR"), syncs it like any folder, merges"
  say " books annotated on two devices and copies the result back to KOReader. Fonts, margins and zoom"
  say " stay as each device has them."
  say
  d=${KOREADER_DIR:-$(koreader_detect)}
  ask " KOReader's folder on this device (empty: don't sync KOReader here): " "$d"
  d=${REPLY/#\~/$HOME}; d=${d%/}
  if [[ -z $d ]]; then KOREADER_DIR=; save_config; info "KOReader is not synced on this device."; pause; return; fi
  [[ $d == /* ]] || { err "Please give an absolute path."; pause; return; }
  if [[ ! -r $d/settings.reader.lua ]]; then
    warn "$(tildify "$d")/settings.reader.lua can't be read - KOReader creates it the first time it starts."
    ((TERMUX)) && say "   If KOReader has run, Termux lacks access: Android settings → Apps → Termux → Permissions → Files → allow all."
    yesno " Use this folder anyway?" n || { pause; return; }
  fi
  KOREADER_DIR=$d
  if ! lua_bin >/dev/null; then
    yesno " Lua (reads and merges KOReader's files) is not installed. Install it?" y && install_lua
    lua_bin >/dev/null || warn "Without Lua, KOReader is not synced on this device."
  fi
  loc=$(ko_location)
  if [[ $loc == hash ]]; then
    ok "KOReader keeps book metadata in its hash-based folder."
  else
    warn "KOReader keeps book metadata in the ${loc:-book} folder, so nothing is synced with it yet. In KOReader:"
    say "   file browser → ⚙ (settings) → Document → Book metadata location → …/koreader/hashdocsettings"
    say "   then 'Move book metadata' in the same menu moves the existing files there."
  fi
  ko_synced || { FOLDERS+=("$KO_DIR"); ok "Added '$KO_DIR' to synced folders."; }
  mkdir -p -- "$LIBRARY_ROOT/$KO_DIR"
  save_config; DIFF_READY=0
  pause
  run_menu ko_conflict_hdr \
    "n|Newer wins|the more recent edit; for the reading position, the device that saved last" \
    "l|This device|keep this device's version" \
    "r|Remote|keep the version from the remote" \
    "a|Ask|ask for each conflict (the newer wins when run with -y)"
  case $MENU_KEY in n) KO_CONFLICT=newer ;; l) KO_CONFLICT=local ;; r) KO_CONFLICT=remote ;; a) KO_CONFLICT=ask ;; esac
  save_config; cls
  ok "KOReader conflicts: $(ko_policy_desc "$KO_CONFLICT") (also changeable per sync with c)."
  koreader_import
  pause
}

# ------------------------------------------------------------- settings --
settings_hdr() {
  printf ' %sSettings%s\n\n' "$CB" "$C0"
  printf ' config  %s\n rclone  %s · remote %s (%s)\n' "$(tildify "$CFG_FILE")" "$(rclone version 2>/dev/null | head -n1)" "$REMOTE" "$(remote_type)"
  printf ' tuning  transfers %s · checkers %s · tpslimit %s · bwlimit %s\n' "$TRANSFERS" "$CHECKERS" "$TPSLIMIT" "${BWLIMIT:-off}"
}

settings_menu() {
  local f
  while :; do
    run_menu settings_hdr \
      "1|Drive connection|connect / reconnect / test Google Drive" \
      "2|Library root|remote folder holding your library ($(rpath))" \
      "3|Local folder|where files live on this device ($(tildify "$LIBRARY_ROOT"))" \
      "4|Sioyek|keep sioyek annotations inside the library" \
      "k|KOReader|sync KOReader highlights, notes and reading progress" \
      "5|Dependencies|check / install rclone and sioyek" \
      "6|Tuning|parallel transfers, API rate limit, bandwidth" \
      "7|Encrypt config|password-protect rclone.conf (OAuth token)" \
      "8|Launcher|install a 'library' command in $(tildify "$(launcher_dir)")" \
      "9|Filter rules|show the generated rclone filter file" \
      "u|Uninstall|remove library from this device (keeps your books unless you ask)"
    case $MENU_KEY in
      1) setup_remote ;;
      2) DIRCACHE=(); browse_folders root ;;
      3) cls; ask "Local library folder: " "$LIBRARY_ROOT"; f=${REPLY/#\~/$HOME}
         if [[ $f == /* ]]; then LIBRARY_ROOT=${f%/}; mkdir -p -- "$LIBRARY_ROOT/logs"; DIFF_READY=0; save_config
           warn "Existing files were not moved. Move them yourself or pull into the new folder."; pause; fi ;;
      4) sioyek_setup ;;
      k) koreader_setup ;;
      5) cls; SIOYEK_ASKED=0; check_deps; ok "rclone: $(rclone version | head -n1)"; sioyek_installed && ok "sioyek installed"; have sqlite3 && ok "sqlite3: $(command -v sqlite3)"
         lua_bin >/dev/null && ok "lua: $(command -v "$(lua_bin)")"; pause ;;
      6) tuning ;;
      7) cls
         f=$(rclone_minor)
         if ((${f:-0} >= 65)); then cursor on; rclone config encryption set; cursor off
         else info "Run 'rclone config' and choose 's) Set configuration password'."; pause; fi ;;
      8) install_launcher; pause ;;
      9) build_filters && pager "rclone filter rules" "$FILTER_FILE" ;;
      u) uninstall && exit 0 ;;
      q) return ;;
    esac
  done
}

tuning() {
  cls
  say " ${CB}Tuning${C0}  ${CD}(Google allows ~10 API calls/s with rclone's shared client id)${C0}"
  ask "Parallel file transfers (1-32): " "$TRANSFERS"; [[ $REPLY =~ ^[0-9]+$ ]] && ((REPLY >= 1 && REPLY <= 32)) && TRANSFERS=$REPLY
  ask "Parallel checkers (1-64): " "$CHECKERS"; [[ $REPLY =~ ^[0-9]+$ ]] && ((REPLY >= 1 && REPLY <= 64)) && CHECKERS=$REPLY
  ask "API transactions/s (0 = unlimited): " "$TPSLIMIT"; [[ $REPLY =~ ^[0-9]+$ ]] && ((REPLY <= 100)) && TPSLIMIT=$REPLY
  ask "Bandwidth limit (e.g. 10M, empty = off): " "$BWLIMIT"; [[ $REPLY =~ ^[0-9A-Za-z.:,\ -]*$ ]] && BWLIMIT=$REPLY
  save_config; ok "Saved."; pause
}

launcher_dir() { if ((TERMUX)); then printf '%s' "$PREFIX/bin"; else printf '%s' "$HOME/.local/bin"; fi; }

install_launcher() {
  local bin; bin=$(launcher_dir)
  mkdir -p -- "$bin"
  if ((TERMUX)); then
    # Android shared storage is mounted noexec, so run the script through bash instead of linking it.
    printf '#!%s/bin/sh\nexec bash %q "$@"\n' "$PREFIX" "$LIBRARY_ROOT/library.sh" >"$bin/library" &&
      chmod 700 -- "$bin/library" && ok "Installed $bin/library → $(tildify "$LIBRARY_ROOT/library.sh")"
  else
    ln -sfn -- "$LIBRARY_ROOT/library.sh" "$bin/library" && ok "Linked $bin/library → $(tildify "$LIBRARY_ROOT/library.sh")"
  fi
  [[ :$PATH: == *":$bin:"* ]] || warn "$bin is not in your PATH - add it to your shell profile."
}

# ------------------------------------------------------------ uninstall --
# Removes the tool from this device: scripts, logs, settings, the launcher and this device's
# record on the remote. Books and annotations stay unless the user explicitly asks (default no).
uninstall() {
  local root=$LIBRARY_ROOT f bin target del_content=0 del_login=0 has_remote=0 launcher=0
  local -a scripts=()
  for f in library.sh library.ps1 library.cmd; do [[ -e $root/$f ]] && scripts+=("$root/$f"); done
  bin=$(launcher_dir)/library
  # Only remove a launcher that points at this library (symlink or Termux wrapper).
  if [[ -L $bin && $(readlink -f -- "$bin") == "$root/library.sh" ]] ||
    { [[ -f $bin && ! -L $bin ]] && grep -qF -- "$root/library.sh" "$bin" 2>/dev/null; }; then launcher=1; fi
  have rclone && [[ -n $(remote_type) ]] && has_remote=1
  cls
  say " ${CB}Uninstall library from this device${C0}"; say
  say " Will remove:"
  for f in "${scripts[@]}"; do say "   $(tildify "$f")"; done
  [[ -d $root/logs ]] && say "   $(tildify "$root/logs")/  ${CD}(sync logs)${C0}"
  [[ -d $CFG_DIR ]] && say "   $(tildify "$CFG_DIR")/  ${CD}(this device's settings)${C0}"
  ((launcher)) && say "   $(tildify "$bin")  ${CD}(the 'library' command)${C0}"
  ((has_remote)) && say "   $(rpath "$MARKER_DIR/$HOST.txt")  ${CD}(this device's sync record)${C0}"
  say; say " Will keep:"
  say "   $(tildify "$root")/ with your books, annotations and .trash, the copy on Google Drive,"
  say "   rclone and sioyek"
  say
  if [[ -d $root ]] && yesno " Also delete $(tildify "$root") and every file in it from this device?" n; then
    warn "Deleted files do not go to trash. The copy on Google Drive is not touched."
    ask " Type 'delete' to confirm: "
    if [[ $REPLY == delete ]]; then del_content=1; else info "Keeping your files."; fi
  fi
  ((has_remote)) && yesno " Also remove the Google Drive login '$REMOTE' from rclone?" n && del_login=1
  yesno " Uninstall now?" n || { info "Cancelled."; pause; return 1; }
  say
  base_flags
  if ((has_remote)) && rclone deletefile "${BASE[@]}" -- "$(rpath "$MARKER_DIR/$HOST.txt")" </dev/null 2>/dev/null; then
    ok "Removed this device from the remote sync records."
  fi
  if ((del_login)); then
    if rclone config delete "$REMOTE" </dev/null 2>/dev/null; then ok "Removed rclone remote '$REMOTE'."
    else warn "Could not remove rclone remote '$REMOTE'."; fi
  fi
  if ((del_content)); then
    # sioyek would otherwise keep pointing at a database that no longer exists.
    sioyek_paths
    target=$root/$ANNOT_DIR/shared.db
    if [[ -f $SY_PREFS ]] && grep -qF -- "shared_database_path $target" "$SY_PREFS" 2>/dev/null; then
      grep -vF -- "shared_database_path $target" "$SY_PREFS" | write_atomic "$SY_PREFS" && ok "sioyek uses its own annotation database again."
    fi
  fi
  ((launcher)) && rm -f -- "$bin" && ok "Removed $(tildify "$bin")"
  [[ -n $CFG_DIR && -d $CFG_DIR ]] && rm -rf -- "$CFG_DIR" && ok "Removed $(tildify "$CFG_DIR")"
  cd -- "$HOME" || cd /
  if ((del_content)) && [[ $root == /?* && $root != "$HOME" && $root != "${HOME%/}/" ]]; then
    rm -rf -- "$root" && ok "Deleted $(tildify "$root")"
  else
    [[ -d $root/logs ]] && rm -rf -- "$root/logs"
    ((${#scripts[@]})) && rm -f -- "${scripts[@]}"
    ok "Removed the scripts and logs; your files are still in $(tildify "$root")"
  fi
  say; ok "library is uninstalled from this device."
}

# ------------------------------------------------------------ first run --
first_run() {
  local root
  cls
  printf '\n %slibrary%s - Google Drive sync for books, papers, sioyek and KOReader annotations\n\n' "$CB" "$C0"
  if ((TERMUX)) && [[ ! -d $HOME/storage/shared ]]; then
    say " Reader apps can only open books in shared storage, which Termux needs permission for."
    if yesno " Run termux-setup-storage now (Android will ask for permission)?" y; then
      termux-setup-storage; sleep 2
      [[ -d $HOME/storage/shared ]] && LIBRARY_ROOT=$(termux_root)
    fi
  fi
  say " Where should the library live on this device?"
  say " ${CD}(files, logs and this script are kept here; settings go to $(tildify "$CFG_DIR"))${C0}"
  ask " Library folder: " "$LIBRARY_ROOT"
  root=${REPLY/#\~/$HOME}; root=${root%/}
  [[ $root == /* ]] || { err "Please give an absolute path."; exit 1; }
  LIBRARY_ROOT=$root
  mkdir -p -- "$LIBRARY_ROOT/content" "$LIBRARY_ROOT/$ANNOT_DIR" "$LIBRARY_ROOT/logs" || exit 1
  save_config
  if [[ $SELF != "$LIBRARY_ROOT/library.sh" ]]; then
    # cp + chmod (not install): shared storage on Android rejects chmod, which is harmless here.
    cp -- "$SELF" "$LIBRARY_ROOT/library.sh" && { chmod 700 -- "$LIBRARY_ROOT/library.sh" 2>/dev/null; :; } &&
      ok "Installed script to $(tildify "$LIBRARY_ROOT/library.sh")"
  fi
  yesno " Install a 'library' command in $(tildify "$(launcher_dir)")?" y && install_launcher
  check_deps
  unlock_rclone
  if [[ -z $(remote_type) ]]; then setup_remote || warn "No Drive connection yet - use Settings later."
  else test_remote; fi
  if [[ -n $(remote_type) ]] && yesno " Choose which Drive folders to sync now? (default: ${FOLDERS[*]})" n; then
    browse_folders select
  fi
  sioyek_installed && sioyek_setup
  koreader_detect >/dev/null && yesno " KOReader found on this device. Sync its highlights, notes and reading progress?" y && koreader_setup
  ok "Setup complete. Tip: run Status first, then Pull."
  pause
}

# ------------------------------------------------------------- main menu --
main_hdr() {
  printf ' %slibrary%s %sv%s · %s%s\n\n' "$CB$CC" "$C0" "$CD" "$VERSION" "$HOST" "$C0"
  printf ' %-8s %s\n' Local "$(tildify "$LIBRARY_ROOT")"
  printf ' %-8s %s   %strash → %s:%s%s\n' Remote "$(rpath)" "$CD" "$REMOTE" "$REMOTE_TRASH" "$C0"
  printf ' %-8s %s\n' Folders "$(folders_desc)"
  ko_on && printf ' %-8s %s\n' KOReader "$(tildify "$KOREADER_DIR")"
  printf ' %-8s %s\n' Filter "$(filter_desc)"
  printf ' %-8s pull %s · push %s\n' Last "$(ago "$LAST_PULL")" "$(ago "$LAST_PUSH")"
}

help_text() {
  cat <<EOF
library $VERSION - keyboard
  j/k or arrows   move          g/G      top/bottom      ctrl-d/u  half page
  enter / l       select/open   h / esc  back            q         back / quit
  /               search (status view)                   tab       next category
  s / x           open file / its folder (status view; Drive files open in the browser)

Operations
  Status   lists both sides (in parallel) and classifies every file:
           ↓+ only on remote · ↓~ newer on remote · ↑+ only local · ↑~ newer local
           » renamed/moved (same size and time, different path)
           !≠ same time, different size · = identical (size + modification time)
  Pull     makes local identical to remote. Local files that would be deleted or
           overwritten are moved to $(tildify "$LIBRARY_ROOT")/.trash/<timestamp>.
  Push     makes remote identical to local. Remote files that would be deleted or
           overwritten are moved to $REMOTE:$REMOTE_TRASH/<timestamp>.
  Merge    two-way copy: new and newer files flow both ways, nothing is deleted.
           Renamed files get the new name on both sides (the side that renamed
           since the last sync wins).
  Renames/moves are done as moves (server-side on Drive), never as re-transfers.
  sioyek's shared.db is merged row by row on Pull and Merge (needs sqlite3):
           highlights/bookmarks added or deleted on either side since the last
           sync are kept or deleted on both. Push uploads this device's copy.
  KOReader (Settings → KOReader, with its book metadata in the hash-based
           folder): highlights, notes, bookmarks and reading progress are
           copied to $KO_DIR/ before each sync and back after it. On Pull and
           Merge, books changed on both sides are merged highlight by highlight;
           conflicts follow this device's rule (now: $(ko_policy_desc "$KO_CONFLICT")),
           which c changes for one sync. Fonts, margins and zoom stay per device.

Only the selected folders are synced; logs/, .trash/ and the scripts stay local.
The file-type filter is per device (e.g. PDFs only on a tablet); the sioyek
and KOReader annotation folders are never filtered. Each sync leaves a marker in
$(rpath "$MARKER_DIR")/ so Status shows when other devices last synced.

Command line:  library status | pull | push | merge  [-y] [--force]
Settings: $(tildify "$CFG_FILE")   Logs: $(tildify "$LIBRARY_ROOT/logs")
EOF
}

main_menu() {
  while :; do
    prefetch
    run_menu main_hdr \
      "s|Status|compare local and remote - what is new where" \
      "p|Pull|remote → local (mirror; removed files go to local trash)" \
      "u|Push|local → remote (mirror; removed files go to remote trash)" \
      "m|Merge|two-way: copy new/newer files both ways, never delete" \
      "f|Folders|choose which Drive folders to sync" \
      "x|Filters|file-type filter for this device ($(filter_desc))" \
      "t|Trash|inspect / clean sync backups" \
      "o|Logs|view sync logs" \
      "c|Settings|Drive connection, sioyek, KOReader, dependencies, tuning" \
      "?|Help|keys and how syncing works"
    cls
    case $MENU_KEY in
      s)
        compute_diff || { pause; continue; }
        while :; do
          view_diff
          case $VIEW_ACTION in
            p) cls; do_sync pull; pause; break ;;
            u) cls; do_sync push; pause; break ;;
            m) cls; do_sync merge; pause; break ;;
            r) cls; compute_diff || { pause; break; } ;;
            *) break ;;
          esac
        done ;;
      p) do_sync pull; pause ;;
      u) do_sync push; pause ;;
      m) do_sync merge; pause ;;
      f) DIRCACHE=(); browse_folders select ;;
      x) filters_menu ;;
      t) trash_menu ;;
      o) logs_menu ;;
      c) settings_menu ;;
      '?') help_text >"$TMP/help"; pager "Help" "$TMP/help" ;;
      q) cls; return ;;
    esac
  done
}

# The 'library' command runs the copy installed in the library folder. When a different copy is
# run (e.g. a newer download), offer to replace the installed one with it.
self_update() {
  local inst=$LIBRARY_ROOT/library.sh v
  [[ -f $inst && $SELF != "$inst" && -t 0 && $TTY == 1 ]] || return 0
  cmp -s -- "$SELF" "$inst" && return 0
  v=$(sed -n 's/^VERSION=//p' "$inst" | head -n1)
  info "The installed copy ($(tildify "$inst"), v${v:-?}) differs from this one (v$VERSION)."
  yesno " Replace the installed copy with this one?" y || return 0
  cp -- "$SELF" "$inst" && { chmod 700 -- "$inst" 2>/dev/null; :; } && ok "Updated - 'library' now runs v$VERSION."
}

usage() { sed -n '2,10p' "$SELF" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd=${1:-menu} yes=0 force=0 a
  for a in "$@"; do
    case $a in -y | --yes) yes=1 ;; --force) force=1 ;; esac
  done
  case $cmd in
    -h | --help | help) usage; return 0 ;;
    -V | --version | version) say "$VERSION"; return 0 ;;
    menu | status | pull | push | merge | setup) ;;
    uninstall)
      [[ -t 0 && $TTY == 1 ]] || { err "Uninstall asks questions - run it in a terminal."; return 1; }
      load_kv "$CFG_FILE"
      have rclone && unlock_rclone
      uninstall && exit 0
      return 1 ;;
    *) usage; return 1 ;;
  esac
  if [[ $cmd == setup ]] || ! load_kv "$CFG_FILE"; then
    load_kv "$CFG_FILE"
    [[ -t 0 && $TTY == 1 ]] || { err "Not configured yet - run 'library' in a terminal first."; return 1; }
    first_run
    [[ $cmd == setup ]] && cmd=menu
  fi
  load_kv "$STATE_FILE"
  self_update
  have rclone || check_deps
  unlock_rclone
  case $cmd in
    menu)
      [[ -t 0 && $TTY == 1 ]] || { err "The menu needs a terminal. Try: library status"; return 1; }
      check_deps
      [[ -n $(remote_type) ]] || setup_remote
      main_menu ;;
    status) compute_diff && print_status ;;
    pull | push | merge) do_sync "$cmd" "$yes" "$force" ;;
  esac
}

main "$@"
