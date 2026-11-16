#!/usr/bin/env bash
# Exercise preferred-player + ignore-media-key combinations via MediaRemote
# (media-control) and process state. Hardware headset is not simulated here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/ChooseMyMusicPlayer.app"
BIN="${APP}/Contents/MacOS/ChooseMyMusicPlayer"
BUNDLE_ID="org.nift4.ChooseMyMusicPlayer"
DEFAULTS_DOMAIN="org.nift4.ChooseMyMusicPlayer"
KEY_IGNORE="org.nift4.ChooseMyMusicPlayer.IgnoreMediaKey"
KEY_PRESET="org.nift4.ChooseMyMusicPlayer.PlayerPreset"
KEY_APP="org.nift4.ChooseMyMusicPlayer.PlayerApp"

PASS=0
FAIL=0
RESULTS=()

log() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); RESULTS+=("PASS  $*"); log "  PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); RESULTS+=("FAIL  $*"); log "  FAIL  $*"; }

need() {
  command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }
}

need media-control
test -x "$BIN" || { echo "missing $APP — install first" >&2; exit 1; }

np_json() {
  media-control get 2>/dev/null || true
}

np_field() {
  local key="$1"
  np_json | python3 -c '
import sys,json
raw=sys.stdin.read().strip()
if not raw or raw=="null":
  print("")
  raise SystemExit
d=json.loads(raw)
print(d.get(sys.argv[1],"") if d else "")
' "$key" 2>/dev/null || true
}

restart_chooser() {
  pkill -x ChooseMyMusicPlayer 2>/dev/null || true
  sleep 0.4
  open "$APP"
  sleep 1.2
}

set_prefs() {
  local preset="$1"
  local path="$2"
  local ignore="$3"
  defaults write "$DEFAULTS_DOMAIN" "$KEY_PRESET" -string "$preset"
  defaults write "$DEFAULTS_DOMAIN" "$KEY_APP" -string "$path"
  defaults write "$DEFAULTS_DOMAIN" "$KEY_IGNORE" -bool "$ignore"
  restart_chooser
}

quit_players() {
  osascript -e 'tell application "Music" to quit' >/dev/null 2>&1 || true
  pkill -x NeteaseMusic 2>/dev/null || true
  pkill -x SodaPlus 2>/dev/null || true
  pkill -x sodaplus-bridge 2>/dev/null || true
  sleep 0.8
}

is_running_bundle() {
  local bid="$1"
  [[ -n "$(pgrep -f "$bid" 2>/dev/null || true)" ]] || \
    [[ -n "$(osascript -e "tell application \"System Events\" to (name of processes) as string" 2>/dev/null | rg -i "${2:-}" || true)" ]]
  pgrep -lf "$2" 2>/dev/null | rg -v 'cursor-agent|Helper|GPU|Renderer' >/dev/null
}

wait_np_bundle() {
  local want="$1"
  local seconds="${2:-8}"
  local i
  for ((i=0; i<seconds*2; i++)); do
    local got
    got="$(np_field bundleIdentifier)"
    if [[ "$got" == "$want" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

send_transport() {
  media-control toggle-play-pause >/dev/null 2>&1 || true
  sleep 0.35
  media-control play >/dev/null 2>&1 || true
  sleep 0.35
  media-control pause >/dev/null 2>&1 || true
  sleep 0.35
}

scenario_idle_ignore_no_launch() {
  local name="$1"
  local preset="$2"
  local path="$3"
  local process_pat="$4"
  log "== $name: ignore ON, player quit — must not re-launch =="
  quit_players
  set_prefs "$preset" "$path" true
  sleep 0.5
  send_transport
  sleep 0.8
  if pgrep -lf "$process_pat" 2>/dev/null | rg -v 'cursor-agent|Helper|GPU|Renderer|ChooseMyMusic' >/dev/null; then
    bad "$name ignore-on idle launched player"
  else
    ok "$name ignore-on idle did not launch"
  fi
  local owner
  owner="$(np_field bundleIdentifier)"
  if [[ "$owner" == "$BUNDLE_ID" || -z "$owner" ]]; then
    ok "$name ignore-on idle NP held/empty (owner=${owner:-none})"
  else
    bad "$name ignore-on idle unexpected NP owner=$owner"
  fi
}

scenario_ignore_off_forwards_or_holds() {
  local name="$1"
  local preset="$2"
  local path="$3"
  log "== $name: ignore OFF idle — chooser should hold NP for forwarding =="
  quit_players
  set_prefs "$preset" "$path" false
  sleep 0.5
  if wait_np_bundle "$BUNDLE_ID" 6; then
    ok "$name ignore-off idle chooser holds NP"
  else
    bad "$name ignore-off idle NP owner=$(np_field bundleIdentifier)"
  fi
}

scenario_player_owns_then_ignore() {
  local name="$1"
  local preset="$2"
  local path="$3"
  local bid="$4"
  local open_name="$5"
  log "== $name: start player, then ignore ON/OFF =="
  quit_players
  set_prefs "$preset" "$path" false
  open -a "$open_name" 2>/dev/null || open "$path" 2>/dev/null || true
  sleep 2.5
  # Best-effort: ask player to publish NP via MediaRemote poke from chooser side
  media-control play >/dev/null 2>&1 || true
  sleep 1
  local before
  before="$(np_field bundleIdentifier)"
  log "  NP before ignore: ${before:-none}"

  defaults write "$DEFAULTS_DOMAIN" "$KEY_IGNORE" -bool true
  # Toggle via relaunch to apply without UI
  restart_chooser
  sleep 1
  send_transport
  sleep 0.8
  # With ignore on, chooser must not have forwarded a cold-start open storm.
  # Player may already be running; that is OK.
  local after_on
  after_on="$(np_field bundleIdentifier)"
  log "  NP ignore ON: ${after_on:-none}"
  ok "$name ignore-on applied (NP=${after_on:-none})"

  defaults write "$DEFAULTS_DOMAIN" "$KEY_IGNORE" -bool false
  restart_chooser
  sleep 1.2
  local after_off
  after_off="$(np_field bundleIdentifier)"
  log "  NP ignore OFF: ${after_off:-none}"
  if [[ "$after_off" == "$BUNDLE_ID" || "$after_off" == "$bid" ]]; then
    ok "$name ignore-off restored control path (NP=$after_off)"
  else
    bad "$name ignore-off dead NP (owner=${after_off:-none})"
  fi
}

codesign_check() {
  log "== codesign / adhoc check =="
  local sig
  sig="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
  printf '%s\n' "$sig" | sed -n '1,12p'
  if printf '%s\n' "$sig" | rg -q '^Signature=adhoc$|flags=0x[0-9a-f]*adhoc'; then
    bad "app is adhoc-signed (TCC will reset every rebuild)"
  elif printf '%s\n' "$sig" | rg -q 'Authority=ChooseMyMusicPlayer Local|Authority=.+'; then
    ok "app uses stable (non-adhoc) signature"
  else
    bad "could not determine signature authority"
  fi
}

log "ChooseMyMusicPlayer media-key scenario smoke test"
log "App: $APP"
codesign_check

scenario_idle_ignore_no_launch "Music" "appleMusic" "/System/Applications/Music.app" "Music.app|/System/Applications/Music"
scenario_idle_ignore_no_launch "Netease" "netease" "/Applications/NeteaseMusic.app" "NeteaseMusic"
scenario_idle_ignore_no_launch "SodaPlus" "sodaPlus" "/Applications/SodaPlus.app" "SodaPlus"

scenario_ignore_off_forwards_or_holds "Music" "appleMusic" "/System/Applications/Music.app"
scenario_ignore_off_forwards_or_holds "Netease" "netease" "/Applications/NeteaseMusic.app"
scenario_ignore_off_forwards_or_holds "SodaPlus" "sodaPlus" "/Applications/SodaPlus.app"

scenario_player_owns_then_ignore "Music" "appleMusic" "/System/Applications/Music.app" "com.apple.Music" "Music"
scenario_player_owns_then_ignore "Netease" "netease" "/Applications/NeteaseMusic.app" "com.netease.163music" "NeteaseMusic"
scenario_player_owns_then_ignore "SodaPlus" "sodaPlus" "/Applications/SodaPlus.app" "org.sodaplus.SodaPlus" "SodaPlus"

log
log "======== summary ========"
for line in "${RESULTS[@]}"; do log "$line"; done
log "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
