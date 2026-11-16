#!/usr/bin/env bash
# Real play/pause checks. Primary target: Netease (loaded track available).
set -u
PASS=0
FAIL=0
CHOOSER="/Applications/ChooseMyMusicPlayer.app"
DOMAIN="org.nift4.ChooseMyMusicPlayer"

log() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS+1)); log "  PASS  $*"; }
bad() { FAIL=$((FAIL+1)); log "  FAIL  $*"; }

np_json() { media-control get 2>/dev/null || echo null; }
np_get() {
  local key="$1"
  np_json | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
if not raw or raw == "null":
    print("")
    raise SystemExit
try:
    d = json.loads(raw)
except Exception:
    print("")
    raise SystemExit
v = d.get(sys.argv[1], "")
if isinstance(v, bool):
    print("true" if v else "false")
elif v is None:
    print("")
else:
    print(v)
' "$key"
}

stop_chooser() {
  pkill -x ChooseMyMusicPlayer 2>/dev/null || true
  sleep 0.7
}

start_chooser() {
  local ignore="$1" preset="$2" path="$3"
  defaults write "$DOMAIN" org.nift4.ChooseMyMusicPlayer.IgnoreMediaKey -bool "$ignore"
  defaults write "$DOMAIN" org.nift4.ChooseMyMusicPlayer.PlayerPreset -string "$preset"
  defaults write "$DOMAIN" org.nift4.ChooseMyMusicPlayer.PlayerApp -string "$path"
  open "$CHOOSER"
  sleep 2.5
}

wait_owner() {
  local want="$1" seconds="${2:-15}"
  local i got
  for ((i=0; i<seconds*2; i++)); do
    got="$(np_get bundleIdentifier)"
    if [[ "$got" == "$want" ]]; then
      return 0
    fi
    sleep 0.5
  done
  log "  (timeout waiting owner=$want, now=$(np_get bundleIdentifier))"
  return 1
}

force_netease_owner() {
  open -a NeteaseMusic
  wait_owner "com.netease.163music" 20
}

set_playing() {
  local want="$1"
  if ! force_netease_owner; then
    return 1
  fi
  if [[ "$want" == "true" ]]; then
    media-control play >/dev/null 2>&1 || true
  else
    media-control pause >/dev/null 2>&1 || true
  fi
  sleep 1.0
  local got
  got="$(np_get playing)"
  log "  set_playing want=$want got=$got title=$(np_get title)"
  [[ "$got" == "$want" ]]
}

read_netease_playing_after_chooser() {
  stop_chooser
  if ! force_netease_owner; then
    echo "unknown"
    return 1
  fi
  np_get playing
}

log "==== Play/Pause verification ===="

stop_chooser
log "== baseline Netease via media-control =="
if set_playing true; then ok "baseline play -> true"; else bad "baseline play failed (playing=$(np_get playing))"; fi
if set_playing false; then ok "baseline pause -> false"; else bad "baseline pause failed (playing=$(np_get playing))"; fi

log "== ignore ON: must NOT start Netease (was paused) =="
stop_chooser
set_playing false || true
start_chooser true netease "/Applications/NeteaseMusic.app"
log "  chooser NP=$(np_get bundleIdentifier) playing=$(np_get playing)"
media-control play >/dev/null 2>&1 || true
media-control toggle-play-pause >/dev/null 2>&1 || true
sleep 2.0
after="$(read_netease_playing_after_chooser || true)"
log "  Netease after swallow play: playing=$after"
if [[ "$after" == "false" ]]; then ok "ignore ON swallowed play/toggle"; else bad "ignore ON Netease playing=$after (expected false)"; fi

log "== ignore ON: must NOT pause Netease (was playing) =="
stop_chooser
set_playing true || true
start_chooser true netease "/Applications/NeteaseMusic.app"
log "  chooser NP=$(np_get bundleIdentifier) playing=$(np_get playing)"
media-control pause >/dev/null 2>&1 || true
media-control toggle-play-pause >/dev/null 2>&1 || true
sleep 2.0
after="$(read_netease_playing_after_chooser || true)"
log "  Netease after swallow pause: playing=$after"
if [[ "$after" == "true" ]]; then ok "ignore ON swallowed pause/toggle"; else bad "ignore ON Netease playing=$after (expected true)"; fi

log "== ignore OFF: play should start Netease (was paused) =="
stop_chooser
set_playing false || true
start_chooser false netease "/Applications/NeteaseMusic.app"
log "  chooser NP=$(np_get bundleIdentifier)"
media-control play >/dev/null 2>&1 || true
sleep 2.5
live_owner="$(np_get bundleIdentifier)"
live_playing="$(np_get playing)"
log "  live owner=$live_owner playing=$live_playing"
after="$(read_netease_playing_after_chooser || true)"
log "  after chooser quit: playing=$after"
if [[ "$after" == "true" || "$live_playing" == "true" ]]; then
  ok "ignore OFF forwarded play"
else
  bad "ignore OFF play did not start Netease (after=$after live=$live_playing)"
fi

log "== ignore OFF: pause should stop Netease (was playing) =="
stop_chooser
set_playing true || true
start_chooser false netease "/Applications/NeteaseMusic.app"
sleep 0.8
# If Netease owns already, pause goes there; if chooser holds, it should forward.
media-control pause >/dev/null 2>&1 || true
sleep 2.0
live_owner="$(np_get bundleIdentifier)"
live_playing="$(np_get playing)"
log "  live owner=$live_owner playing=$live_playing"
after="$(read_netease_playing_after_chooser || true)"
log "  after chooser quit: playing=$after"
if [[ "$after" == "false" || ( "$live_owner" == "com.netease.163music" && "$live_playing" == "false" ) ]]; then
  ok "ignore OFF forwarded/applied pause"
else
  bad "ignore OFF pause did not stop Netease (after=$after live=$live_playing owner=$live_owner)"
fi

log "== SodaPlus best-effort =="
stop_chooser
pkill -x SodaPlus 2>/dev/null || true
pkill -x sodaplus-bridge 2>/dev/null || true
sleep 0.5
open -a SodaPlus
if wait_owner "org.sodaplus.SodaPlus" 12; then
  media-control play >/dev/null 2>&1 || true
  sleep 1
  if [[ "$(np_get playing)" == "true" ]]; then
    ok "SodaPlus baseline play"
    start_chooser true sodaPlus "/Applications/SodaPlus.app"
    media-control pause >/dev/null 2>&1 || true
    media-control toggle-play-pause >/dev/null 2>&1 || true
    sleep 1
    stop_chooser
    sleep 0.8
    open -a SodaPlus
    if wait_owner "org.sodaplus.SodaPlus" 10; then
      after="$(np_get playing)"
      log "  SodaPlus after ignore swallow: playing=$after"
      if [[ "$after" == "true" ]]; then ok "ignore ON did not pause SodaPlus"; else bad "ignore ON altered SodaPlus playing=$after"; fi
    else
      log "  SKIP SodaPlus republish after chooser quit"
    fi
  else
    log "  SKIP SodaPlus (NP present but play did not start, title=$(np_get title))"
  fi
else
  log "  SKIP SodaPlus (no Now Playing session)"
fi

log "== Music: empty library — launch guard only =="
stop_chooser
osascript -e 'tell application "Music" to quit' >/dev/null 2>&1 || true
sleep 0.5
start_chooser true appleMusic "/System/Applications/Music.app"
media-control play >/dev/null 2>&1 || true
sleep 1
if pgrep -x Music >/dev/null; then bad "Music launched under ignore ON"; else ok "Music not launched under ignore ON play"; fi

log
log "======== play/pause summary: passed=$PASS failed=$FAIL ========"
exit "$FAIL"
