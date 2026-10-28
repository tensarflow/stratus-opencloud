#!/usr/bin/env bash
# Stratus live Finder round-trip test (Task 7).
#
#   scripts/e2e.sh <domain-root-path> [--large] [--only a,b,...]
#
# <domain-root-path> is the File Provider folder, e.g.
#   ~/Library/CloudStorage/<Stratus Personal>
# Requires OC_URL, OC_USER, OC_TOKEN in the environment (the token is only ever
# passed to curl via -u, never printed). The personal space id is looked up via
# /graph/v1.0/me/drives; OC_SPACE overrides it. Works exclusively inside
# <root>/fp-test/e2e-<timestamp>/ (== /fp-test/e2e-<timestamp>/ on the server)
# and removes that one local folder at the end (it then lands in the server trash).
# Targets bash 3.2 (macOS /bin/bash).
set -euo pipefail

SPACE=""
PROPBODY='<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><d:getetag/><oc:fileid/><oc:size/></d:prop></d:propfind>'
T_REMOTE=90 T_LOCAL=60 T_LARGE=180
FAILS=0 LARGE=0 ONLY="" ROOT="" RUN="" RUN_REL="" TMP="" TS=""

# ---- tiny python helpers (data via stdin/argv, never interpolated into code) ----
urlenc() { python3 -I -c 'import sys,unicodedata,urllib.parse as P
print(P.quote(unicodedata.normalize("NFC",sys.argv[1]),safe="/"),end="")' "$1"; }
PY_PROP='import sys,xml.etree.ElementTree as E
try: r=E.fromstring(sys.stdin.buffer.read())
except Exception: sys.exit(1)
for e in r.iter():
    if e.tag.rsplit("}",1)[-1]==sys.argv[1] and e.text:
        print(e.text.strip()); break'
PY_NAMES='import sys,unicodedata as U,urllib.parse as P,xml.etree.ElementTree as E
try: r=E.fromstring(sys.stdin.buffer.read())
except Exception: sys.exit(1)
for h in list(r.iter("{DAV:}href"))[1:]:
    print(U.normalize("NFC",P.unquote(h.text.strip()).rstrip("/").rsplit("/",1)[-1]))'

# ---- server side ----
oc() { curl -s -g -u "$OC_USER:$OC_TOKEN" "$@"; }
personal_space() { oc "${OC_URL%/}/graph/v1.0/me/drives" | python3 -I -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
print(next((x["id"] for x in d.get("value",[]) if x.get("driveType")=="personal"),""),end="")' || true; }
dav() { printf '%s/dav/spaces/%s/%s' "$OC_URL" "$SPACE" "$(urlenc "$1")"; }
http_code() { local m=$1 p=$2; shift 2; oc -o /dev/null -w '%{http_code}' -X "$m" "$@" "$(dav "$p")"; }
propfind() { oc -X PROPFIND -H "Depth: ${2:-0}" -H 'Content-Type: application/xml' --data-binary "$PROPBODY" "$(dav "$1")"; }
prop() { propfind "$1" 0 | python3 -I -c "$PY_PROP" "$2" || true; }   # prop <path> getetag|fileid|size
list_names() { propfind "$1" 1 | python3 -I -c "$PY_NAMES" || true; }  # basenames, NFC, one per line
server_has() { [ "$(http_code PROPFIND "$1" -H 'Depth: 0')" = 207 ]; }
server_gone() { [ "$(http_code PROPFIND "$1" -H 'Depth: 0')" = 404 ]; }
server_get() { oc -f -o "$2" "$(dav "$1")"; }
server_put() { http_code PUT "$1" -H 'Content-Type: application/octet-stream' --data-binary "@$2"; }
server_matches() { server_get "$1" "$TMP/dl" && cmp -s "$TMP/dl" "$2"; }       # path, local file
server_eq_str() { printf '%s' "$2" > "$TMP/exp"; server_matches "$1" "$TMP/exp"; }  # path, string
server_size_is() { [ "$(prop "$1" size)" = "$2" ]; }

# ---- harness ----
pass() { echo "PASS $1 $2"; }
fail() { echo "FAIL $1 $2: $3"; FAILS=$((FAILS + 1)); }
wait_until() { # wait_until <timeout-s> <command...>; polls every 3 s
  local limit=$1 start=$SECONDS; shift
  while ! "$@" >/dev/null 2>&1; do
    [ $((SECONDS - start)) -ge "$limit" ] && return 1
    sleep 3
  done
}
want() { [ -z "$ONLY" ] || [[ $ONLY == *",$1,"* ]]; }
cleanup() {
  case "$RUN" in */Library/CloudStorage/*/fp-test/e2e-[0-9]*) rm -rf -- "$RUN" ;; esac
  [ -n "$TMP" ] && rm -rf -- "$TMP"
  return 0
}

# ---- checks ----
check_b() { # remote file appears locally
  printf '%s' "from-server-$TS" > "$TMP/remote.txt"
  local c; c=$(server_put "$RUN_REL/remote.txt" "$TMP/remote.txt")
  case $c in 2??) ;; *) fail b "remote file appears locally" "server PUT returned HTTP $c"; return ;; esac
  if wait_until $T_REMOTE test -f "$RUN/remote.txt"; then pass b "remote.txt appeared locally"
  else fail b "remote.txt appeared locally" "not seen after ${T_REMOTE}s"; fi
}
check_a() { # fp-test lists; remote-created file is dataless (checked before it is read)
  local f="$RUN/remote.txt" flags blocks
  ls "$ROOT/fp-test" >/dev/null 2>&1 || { fail a "list fp-test, remote.txt dataless before read" "ls fp-test failed"; return; }
  [ -e "$f" ] || { fail a "list fp-test, remote.txt dataless before read" "remote.txt missing (check b failed)"; return; }
  flags=$(ls -lO "$f" 2>/dev/null || true); blocks=$(stat -f %b "$f")
  if [[ $flags == *dataless* ]]; then pass a "fp-test lists; remote.txt dataless (method: ls -lO flag)"
  elif [ "$blocks" = 0 ]; then pass a "fp-test lists; remote.txt dataless (method: stat %b == 0)"
  else fail a "remote.txt dataless before read" "materialized: blocks=$blocks, ls -lO: $flags"; fi
}
check_c() { # materialize on demand
  local got; got=$(cat "$RUN/remote.txt" 2>&1 || true)
  if [ "$got" = "from-server-$TS" ]; then pass c "cat remote.txt equals uploaded content"
  else fail c "cat remote.txt equals uploaded content" "got '$got'"; fi
}
check_d() { # local create -> server
  printf '%s' "from-mac-$TS" > "$RUN/local.txt"
  if wait_until $T_LOCAL server_eq_str "$RUN_REL/local.txt" "from-mac-$TS"; then pass d "local.txt reached server with same bytes"
  else fail d "local.txt reached server with same bytes" "no match after ${T_LOCAL}s (PROPFIND: $(http_code PROPFIND "$RUN_REL/local.txt" -H 'Depth: 0'))"; fi
}
conflict_copies() { # conflict_copies <stem>: names in the run folder like "<stem> (conflict …"
  local name
  while IFS= read -r name; do
    [[ $name == "$1 (conflict "* ]] && printf '%s\n' "$name"
  done < <(list_names "$RUN_REL")
  return 0
}
no_conflict_copy() { # no_conflict_copy <check> <stem>: after a settle delay, no conflict copy of <stem>
  local found
  sleep 10   # a spurious copy is uploaded right after the edit lands
  found=$(conflict_copies "$2")
  if [ -z "$found" ]; then pass "$1" "no conflict copy of $2"
  else fail "$1" "no conflict copy of $2" "found: $(printf '%s' "$found" | tr '\n' ' ')"; fi
}
check_e() { # local edit -> server etag changes
  local old; old=$(prop "$RUN_REL/local.txt" getetag)
  printf '\nsecond-line-%s\n' "$TS" >> "$RUN/local.txt"
  if wait_until $T_LOCAL server_matches "$RUN_REL/local.txt" "$RUN/local.txt"; then
    local new; new=$(prop "$RUN_REL/local.txt" getetag)
    if [ -n "$new" ] && [ "$new" != "$old" ]; then pass e "edit synced: etag $old -> $new, bytes match"
    else fail e "edit synced" "bytes match but etag unchanged ($old)"; fi
  else fail e "edit synced to server" "server bytes differ after ${T_LOCAL}s"; fi
  no_conflict_copy e local
}
check_f() { # mkdir, rename, move keep the same fileid
  local id1 id2
  mkdir "$RUN/sub"; mv "$RUN/local.txt" "$RUN/renamed.txt"
  wait_until $T_LOCAL server_has "$RUN_REL/renamed.txt" || { fail f "mkdir/rename/move" "renamed.txt not on server after ${T_LOCAL}s"; return; }
  id1=$(prop "$RUN_REL/renamed.txt" fileid)
  mv "$RUN/renamed.txt" "$RUN/sub/"
  wait_until $T_LOCAL server_has "$RUN_REL/sub/renamed.txt" || { fail f "mkdir/rename/move" "sub/renamed.txt not on server after ${T_LOCAL}s"; return; }
  id2=$(prop "$RUN_REL/sub/renamed.txt" fileid)
  server_has "$RUN_REL/sub" || { fail f "mkdir/rename/move" "sub/ not on server"; return; }
  wait_until $T_LOCAL server_gone "$RUN_REL/renamed.txt" || { fail f "mkdir/rename/move" "renamed.txt still at run-folder root on server"; return; }
  if [ -n "$id1" ] && [ "$id1" = "$id2" ]; then pass f "mkdir + rename + move; fileid unchanged ($id1)"
  else fail f "move keeps fileid" "before='$id1' after='$id2'"; fi
}
check_g() { # delete
  rm "$RUN/sub/renamed.txt"
  if wait_until $T_LOCAL server_gone "$RUN_REL/sub/renamed.txt"; then pass g "rm propagated (server 404)"
  else fail g "rm propagated" "sub/renamed.txt still on server after ${T_LOCAL}s"; fi
}
check_h() { # 150 MiB upload (TUS path)
  dd if=/dev/urandom of="$RUN/big.bin" bs=1m count=150 2>/dev/null
  if wait_until $T_LARGE server_size_is "$RUN_REL/big.bin" 157286400; then pass h "big.bin on server, size 157286400"
  else fail h "big.bin on server, size 157286400" "size now '$(prop "$RUN_REL/big.bin" size)' after ${T_LARGE}s"; fi
}
conflict_resolved() { # both versions survive: conflict copy + conflict.txt hold local-v2/server-v2
  local name c other
  while IFS= read -r name; do
    [[ $name == "conflict (conflict "* ]] || continue
    server_get "$RUN_REL/$name" "$TMP/c1" || continue
    c=$(cat "$TMP/c1")
    case $c in local-v2) other=server-v2 ;; server-v2) other=local-v2 ;; *) continue ;; esac
    server_eq_str "$RUN_REL/conflict.txt" "$other" && return 0
  done < <(list_names "$RUN_REL")
  return 1
}
check_i() {
  printf v1 > "$RUN/conflict.txt"
  wait_until $T_LOCAL server_eq_str "$RUN_REL/conflict.txt" v1 || { fail i "conflict" "conflict.txt (v1) never reached server"; return; }
  printf server-v2 > "$TMP/sv2"
  server_put "$RUN_REL/conflict.txt" "$TMP/sv2" >/dev/null
  sleep 5
  printf 'local-v2' > "$RUN/conflict.txt"
  if wait_until $T_REMOTE conflict_resolved; then pass i "conflict copy created, both versions survive"
  else fail i "conflict copy with both versions" "not found after ${T_REMOTE}s; server listing:"; list_names "$RUN_REL" | sed 's/^/    /'; fi
}
check_k() { # truncate to 0 bytes -> server size 0, same fileid
  local id1 id2
  printf 'to-be-truncated-%s' "$TS" > "$RUN/trunc.txt"
  wait_until $T_LOCAL server_eq_str "$RUN_REL/trunc.txt" "to-be-truncated-$TS" || { fail k "truncate to 0 bytes" "trunc.txt never reached server after ${T_LOCAL}s"; return; }
  id1=$(prop "$RUN_REL/trunc.txt" fileid)
  : > "$RUN/trunc.txt"
  wait_until $T_LOCAL server_size_is "$RUN_REL/trunc.txt" 0 || { fail k "truncate to 0 bytes" "server size '$(prop "$RUN_REL/trunc.txt" size)' after ${T_LOCAL}s"; return; }
  id2=$(prop "$RUN_REL/trunc.txt" fileid)
  if [ -n "$id1" ] && [ "$id1" = "$id2" ]; then pass k "truncated to 0 bytes on server; fileid unchanged ($id1)"
  else fail k "truncate keeps fileid" "before='$id1' after='$id2'"; fi
  no_conflict_copy k trunc
}
check_l() { # rapid saves: 3 writes within 1 s keep the last content and make no conflict copy
  local i
  printf 'rapid-0-%s' "$TS" > "$RUN/rapid.txt"
  wait_until $T_LOCAL server_eq_str "$RUN_REL/rapid.txt" "rapid-0-$TS" || { fail l "rapid saves" "rapid.txt never reached server after ${T_LOCAL}s"; return; }
  for i in 1 2 3; do printf 'rapid-%s-%s' "$i" "$TS" > "$RUN/rapid.txt"; sleep 0.3; done
  sleep 40
  if ! server_eq_str "$RUN_REL/rapid.txt" "rapid-3-$TS"; then
    fail l "rapid saves" "server does not hold the last save after 40s"
  elif [ -n "$(conflict_copies rapid)" ]; then
    fail l "rapid saves" "conflict copy found: $(conflict_copies rapid | tr '\n' ' ')"
  else pass l "3 saves within 1 s: server has the last one, no conflict copy"; fi
}
check_j() { # unicode / special-character name
  local name='Ödev Çağlayan şğ #1 100% a+b?.txt' n
  printf unicode > "$RUN/$name"
  if ! wait_until $T_LOCAL server_eq_str "$RUN_REL/$name" unicode; then
    fail j "special-character name round-trips" "server lacks NFC-named file with same bytes after ${T_LOCAL}s"; return; fi
  sleep 6   # let any duplicate (NFD/escaped variant) surface
  n=$(propfind "$RUN_REL" 1 | python3 -I -c 'import sys,unicodedata as U,urllib.parse as P,xml.etree.ElementTree as E
w=U.normalize("NFC",sys.argv[1]); r=E.fromstring(sys.stdin.buffer.read())
print(sum(U.normalize("NFC",P.unquote(h.text.strip()).rstrip("/").rsplit("/",1)[-1])==w for h in r.iter("{DAV:}href")))' "$name" || echo "?")
  if [ "$n" = 1 ]; then pass j "special-character name on server once, bytes match"
  else fail j "special-character name appears once" "$n matching entries in run folder listing"; fi
}

# ---- main ----
main() {
  local a
  [ $# -ge 1 ] || { echo "usage: $0 <domain-root-path> [--large] [--only a,b,...]" >&2; exit 2; }
  ROOT=${1%/}; shift
  while [ $# -gt 0 ]; do
    case $1 in
      --large) LARGE=1 ;;
      --only) ONLY=",$2,"; shift ;;
      --only=*) ONLY=",${1#--only=},"  ;;
      *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac; shift
  done
  : "${OC_URL:?OC_URL not set}" "${OC_USER:?OC_USER not set}" "${OC_TOKEN:?OC_TOKEN not set}"
  case "$ROOT" in */../*|*/..) echo "refusing: '..' in path" >&2; exit 2 ;; esac
  [[ $ROOT == */Library/CloudStorage/* ]] || { echo "refusing: $ROOT is not under */Library/CloudStorage/*" >&2; exit 2; }
  [ -d "$ROOT/fp-test" ] || { echo "refusing: $ROOT/fp-test does not exist" >&2; exit 2; }
  SPACE=${OC_SPACE:-$(personal_space)}
  [ -n "$SPACE" ] || { echo "cannot find the personal space id; set OC_SPACE" >&2; exit 2; }

  if [ -n "$ONLY" ]; then # pull in prerequisites
    local changed=1 p id dep
    while [ $changed = 1 ]; do
      changed=0
      for p in a:b c:b e:d f:d g:f; do
        id=${p%%:*}; dep=${p##*:}
        if [[ $ONLY == *",$id,"* && $ONLY != *",$dep,"* ]]; then ONLY="$ONLY$dep,"; changed=1; fi
      done
    done
  fi

  TS=$(date +%Y%m%d-%H%M%S); TMP=$(mktemp -d)
  RUN_REL="fp-test/e2e-$TS"; RUN="$ROOT/$RUN_REL"
  trap cleanup EXIT
  mkdir "$RUN"
  wait_until $T_LOCAL server_has "$RUN_REL" || { echo "run folder $RUN_REL never reached the server" >&2; exit 2; }
  echo "e2e run folder: $RUN_REL"

  for a in b a c d e f g h i j k l; do
    if [ "$a" = h ] && [ $LARGE = 0 ]; then want h && echo "SKIP h needs --large"; continue; fi
    want "$a" && "check_$a"
  done
  echo "done: $FAILS failed"
  [ "$FAILS" -eq 0 ]
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
