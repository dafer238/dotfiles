#!/usr/bin/env bash
# library.sh - interactive Google Drive <-> local library sync (books, papers, sioyek annotations)
#
#   library               interactive menu (vim keys: j/k move, enter/l open, h/esc back, q quit)
#   library status        print sync status and exit
#   library pull|push|merge [-y] [--force]
#   library setup         re-run first-time setup
#
# Everything is driven by rclone. Per-device settings live in
# ${XDG_CONFIG_HOME:-~/.config}/library-sync/ (never synced).

set -uo pipefail

VERSION=1.0.0
SELF=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
CFG_DIR=${LIBRARY_SYNC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/library-sync}
CFG_FILE=$CFG_DIR/config
STATE_FILE=$CFG_DIR/state
FILTER_FILE=$CFG_DIR/filters.rclone
MANIFEST_FILE=$CFG_DIR/manifest
ANNOT_DIR=sioyek
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
# On Android the library must be in shared storage so reader apps can open the books.
((TERMUX)) && [[ -d $HOME/storage/shared ]] && LIBRARY_ROOT=$(readlink -f -- "$HOME/storage/shared")/library
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
LAST_PULL= LAST_PUSH= LAST_MERGE=
DIFF_READY=0
REMOTE_MISSING=0
declare -A CNT=() MENU_POS=() DIRCACHE=()
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
  [ladd]="New locally" [lnew]="Newer locally" [size]="Conflicts" [same]="In sync")
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
  build_filters && start_listings "$TMP/ls.$RANDOM$RANDOM"
}

compute_diff() {
  local lo ro d lrc rrc k n
  DIFF_READY=0 REMOTE_MISSING=0
  build_filters || return 1
  if [[ -z $LIST_DIR ]] || (($(date +%s) - LIST_AT > 120)) || [[ $LIST_SIG != "$(list_sig)" ]]; then
    printf '%sListing %s and %s …%s\n' "$CD" "$(tildify "$LIBRARY_ROOT")" "$(rpath)" "$C0"
    start_listings "$TMP/ls.$RANDOM$RANDOM"
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

set_last() { printf -v "LAST_${1^^}" '%s' "$(now_iso)"; save_state; save_manifest; write_marker; }

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
  local op=$1 yes=${2:-0} force=${3:-0} a b c d over del dest_n ts log rc=0 title ren unk revert names=b
  [[ $DIFF_READY == 1 ]] || compute_diff || return 1
  ren=${CNT[ren]}
  unk=$(awk -F'\t' '$3 == ""' "$TMP/renames" | wc -l)
  case $op in
    pull) revert=$(awk -F'\t' '$3 == "local"' "$TMP/renames" | wc -l) ;;
    push) revert=$(awk -F'\t' '$3 == "remote"' "$TMP/renames" | wc -l) ;;
    *) revert=0 ;;
  esac
  case $op in
    pull)  a=${CNT[radd]} b=$((CNT[rnew] + CNT[size])) over=${CNT[lnew]} del=${CNT[ladd]} dest_n=$LOCAL_N
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
    if ((a + b + over + del + ren == 0)); then
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
      *) say; info "Cancelled."; return 1 ;;
    esac
  done
  # Guard against mass deletion (e.g. pushing from an empty or wrongly-configured device).
  if ((del >= 10 && del * 4 > dest_n)); then
    warn "This would remove $del of $dest_n files on the destination."
    if ((yes)); then
      ((force)) || { err "Refusing without --force."; return 1; }
    else
      ask "Type 'delete' to continue: "; [[ $REPLY == delete ]] || { info "Cancelled."; return 1; }
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
    buf=" ${CB}File-type filter for this device${C0}  ${CD}(sioyek annotations are always synced)${C0}"$'\n\n'
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
  if ((SIOYEK_ASKED == 0 && !TERMUX)) && ! sioyek_installed; then
    yesno "sioyek (PDF reader whose annotations this tool syncs) is not installed. Install it?" y && install_sioyek
    SIOYEK_ASKED=1; save_config
  fi
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
  SY_PREFS=$cfg/sioyek/prefs_user.config SY_DB=$data/sioyek/shared.db
  if ! have sioyek && have flatpak && flatpak info com.github.ahrm.sioyek >/dev/null 2>&1; then
    SY_PREFS=$HOME/.var/app/com.github.ahrm.sioyek/config/sioyek/prefs_user.config
    SY_DB=$HOME/.var/app/com.github.ahrm.sioyek/data/sioyek/shared.db
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
  if [[ $current == "$target" ]]; then ok "Already pointing at the library."; pause; return; fi
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
  if [[ " ${FOLDERS[*]} " != *" $ANNOT_DIR "* ]]; then FOLDERS+=("$ANNOT_DIR"); save_config; ok "Added '$ANNOT_DIR' to synced folders."; fi
  warn "Annotations merge per file, not per highlight: if two devices annotate before syncing, the newer shared.db wins."
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
      "5|Dependencies|check / install rclone and sioyek" \
      "6|Tuning|parallel transfers, API rate limit, bandwidth" \
      "7|Encrypt config|password-protect rclone.conf (OAuth token)" \
      "8|Launcher|install a 'library' command in $(tildify "$(launcher_dir)")" \
      "9|Filter rules|show the generated rclone filter file"
    case $MENU_KEY in
      1) setup_remote ;;
      2) DIRCACHE=(); browse_folders root ;;
      3) cls; ask "Local library folder: " "$LIBRARY_ROOT"; f=${REPLY/#\~/$HOME}
         if [[ $f == /* ]]; then LIBRARY_ROOT=${f%/}; mkdir -p -- "$LIBRARY_ROOT/logs"; DIFF_READY=0; save_config
           warn "Existing files were not moved. Move them yourself or pull into the new folder."; pause; fi ;;
      4) sioyek_setup ;;
      5) cls; SIOYEK_ASKED=0; check_deps; ok "rclone: $(rclone version | head -n1)"; sioyek_installed && ok "sioyek installed"; pause ;;
      6) tuning ;;
      7) cls
         f=$(rclone_minor)
         if ((${f:-0} >= 65)); then cursor on; rclone config encryption set; cursor off
         else info "Run 'rclone config' and choose 's) Set configuration password'."; pause; fi ;;
      8) install_launcher; pause ;;
      9) build_filters && pager "rclone filter rules" "$FILTER_FILE" ;;
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

# ------------------------------------------------------------ first run --
first_run() {
  local root
  cls
  printf '\n %slibrary%s - Google Drive sync for books, papers and sioyek annotations\n\n' "$CB" "$C0"
  if ((TERMUX)) && [[ ! -d $HOME/storage/shared ]]; then
    say " Reader apps can only open books in shared storage, which Termux needs permission for."
    if yesno " Run termux-setup-storage now (Android will ask for permission)?" y; then
      termux-setup-storage; sleep 2
      [[ -d $HOME/storage/shared ]] && LIBRARY_ROOT=$(readlink -f -- "$HOME/storage/shared")/library
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
  ok "Setup complete. Tip: run Status first, then Pull."
  pause
}

# ------------------------------------------------------------- main menu --
main_hdr() {
  printf ' %slibrary%s %sv%s · %s%s\n\n' "$CB$CC" "$C0" "$CD" "$VERSION" "$HOST" "$C0"
  printf ' %-8s %s\n' Local "$(tildify "$LIBRARY_ROOT")"
  printf ' %-8s %s   %strash → %s:%s%s\n' Remote "$(rpath)" "$CD" "$REMOTE" "$REMOTE_TRASH" "$C0"
  printf ' %-8s %s\n' Folders "$(folders_desc)"
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

Only the selected folders are synced; logs/, .trash/ and the scripts stay local.
The file-type filter is per device (e.g. PDFs only on a tablet); sioyek's
annotation folder is never filtered. Each sync leaves a marker in
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
      "c|Settings|Drive connection, sioyek, dependencies, tuning" \
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

usage() { sed -n '2,9p' "$SELF" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd=${1:-menu} yes=0 force=0 a
  for a in "$@"; do
    case $a in -y | --yes) yes=1 ;; --force) force=1 ;; esac
  done
  case $cmd in
    -h | --help | help) usage; return 0 ;;
    -V | --version | version) say "$VERSION"; return 0 ;;
    menu | status | pull | push | merge | setup) ;;
    *) usage; return 1 ;;
  esac
  if [[ $cmd == setup ]] || ! load_kv "$CFG_FILE"; then
    load_kv "$CFG_FILE"
    [[ -t 0 && $TTY == 1 ]] || { err "Not configured yet - run 'library' in a terminal first."; return 1; }
    first_run
    [[ $cmd == setup ]] && cmd=menu
  fi
  load_kv "$STATE_FILE"
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
