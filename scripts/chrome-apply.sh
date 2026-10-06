#!/usr/bin/env bash
# Applies chrome.yaml (Chrome preferences and extension keyboard shortcuts) to
# the running Google Chrome, for the profile of its front window. Idempotent:
# only values that differ are changed.
#
# How: Chrome's AppleScript `execute javascript` runs code in a tab. The
# private APIs behind chrome://settings (chrome.settingsPrivate) and
# chrome://extensions/shortcuts (chrome.developerPrivate) are only exposed on
# those pages, so we open them as background tabs, drive them, and close them.
# It needs "Allow JavaScript from Apple Events" (View > Developer) in Chrome.
#
# Usage:
#   scripts/chrome-apply.sh [--dry-run] [path/to/chrome.yaml]
#   scripts/chrome-apply.sh --list-settings [regex]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

die() {
  echo "error: $*" >&2
  exit 1
}

mode=apply
dry_run=false
config=""
filter=""
while (($#)); do
  case "$1" in
    --dry-run) dry_run=true ;;
    --list-settings)
      mode=list
      if (($# > 1)) && [[ "$2" != --* ]]; then
        filter="$2"
        shift
      fi
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [[ -z "$config" ]] || die "only one config path may be given"
      config="$1"
      ;;
  esac
  shift
done
config="${config:-$REPO/chrome.yaml}"

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
command -v yq > /dev/null || die "yq not found; run 'mise install' in $REPO"
if [[ "$mode" == apply ]]; then
  [[ -r "$config" ]] || die "cannot read $config"
  yq -e 'type == "!!map"' "$config" > /dev/null 2>&1 || die "$config is not a YAML mapping"
fi

# Don't launch Chrome: `is running` checks without starting it.
running="$(osascript -e 'application "Google Chrome" is running')"
[[ "$running" == true ]] || die "Google Chrome is not running; start it first"
windows="$(osascript -e 'tell application "Google Chrome" to count windows')"
((windows > 0)) || die "Google Chrome has no open window; open one first"

# Helper tabs we opened, as "windowId:tabId". Only these are ever closed.
HELPER_TABS=()

cleanup() {
  local t
  for t in "${HELPER_TABS[@]+"${HELPER_TABS[@]}"}"; do
    osascript - "${t%%:*}" "${t##*:}" > /dev/null 2>&1 << 'EOF' || true
on run argv
  tell application "Google Chrome"
    close (tab id ((item 2 of argv) as integer) of window id ((item 1 of argv) as integer))
  end tell
end run
EOF
  done
}
trap cleanup EXIT

# open_tab URL: opens URL as a background tab in the front window, waits for
# it to load, and sets TAB to "windowId:tabId". Not run in a subshell, so the
# tab is recorded for cleanup.
open_tab() {
  local ref i
  ref="$(osascript - "$1" << 'EOF'
on run argv
  tell application "Google Chrome"
    set w to front window
    set prev to active tab index of w
    set t to make new tab at end of tabs of w with properties {URL:(item 1 of argv)}
    set active tab index of w to prev
    return (id of w as text) & ":" & (id of t as text)
  end tell
end run
EOF
  )"
  HELPER_TABS+=("$ref")
  for ((i = 0; i < 100; i++)); do
    if [[ "$(osascript - "${ref%%:*}" "${ref##*:}" << 'EOF'
on run argv
  tell application "Google Chrome"
    return loading of (tab id ((item 2 of argv) as integer) of window id ((item 1 of argv) as integer))
  end tell
end run
EOF
    )" == false ]]; then
      TAB="$ref"
      return
    fi
    sleep 0.1
  done
  die "timed out waiting for $1 to load"
}

# exec_js TAB JS: runs JS in the tab and prints its result. The JS travels as
# an osascript argument, so no AppleScript quoting is involved.
exec_js() {
  local out
  if ! out="$(osascript - "${1%%:*}" "${1##*:}" "$2" 2>&1 << 'EOF'
on run argv
  tell application "Google Chrome"
    set t to tab id ((item 2 of argv) as integer) of window id ((item 1 of argv) as integer)
    return execute t javascript (item 3 of argv)
  end tell
end run
EOF
  )"; then
    if [[ "$out" == *"Apple Events"* || "$out" == *"AppleScript"* ]]; then
      die "Chrome refused to run JavaScript. Enable it in Chrome: View > Developer > Allow JavaScript from Apple Events
($out)"
    fi
    die "osascript failed: $out"
  fi
  printf '%s' "$out"
}

# call_api TAB DATA_JSON FN: FN is a JS function (D, done) that calls an async
# Chrome API with the decoded DATA_JSON as D and passes the result to done.
# Prints {"ok": result} or {"error": message} as JSON. The data is base64
# encoded so no value can break out of the JS string.
call_api() {
  local tab="$1" b64 js out i
  b64="$(printf '%s' "$2" | base64 | tr -d '\n')"
  js="(function(){window.__cbb=undefined;try{
var D=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('$b64'),function(c){return c.charCodeAt(0);})));
($3)(D,function(r){var e=window.chrome&&chrome.runtime&&chrome.runtime.lastError;
window.__cbb=JSON.stringify(e?{error:e.message}:{ok:r===undefined?null:r});});
}catch(x){window.__cbb=JSON.stringify({error:String(x)});}return 'started';})()"
  exec_js "$tab" "$js" > /dev/null
  for ((i = 0; i < 100; i++)); do
    out="$(exec_js "$tab" "typeof window.__cbb==='string'?window.__cbb:''")"
    if [[ -n "$out" ]]; then
      printf '%s' "$out"
      return
    fi
    sleep 0.1
  done
  die "timed out waiting for a Chrome API call"
}

# api_ok RESULT: prints the "ok" part, or fails with the "error" part.
api_ok() {
  local err
  [[ -n "$1" ]] || die "no result from Chrome"
  err="$(yq -p=json -o=json -I=0 '.error // ""' <<< "$1")"
  [[ "$err" == '""' ]] || die "Chrome API error: $err"
  yq -p=json -o=json -I=0 '.ok' <<< "$1"
}

# canon JSON: compact JSON with sorted map keys, for comparing values.
canon() {
  yq -p=json -o=json -I=0 'sort_keys(..)' <<< "$1"
}

# norm_key BINDING: canonical form of a shortcut, accepting both the manifest
# format (Command+Shift+J) and Chrome's macOS display form (⇧⌘J). On macOS
# "Ctrl" in a manifest means Command and "MacCtrl" means Control.
norm_key() {
  local s="$1" mods="" key part
  [[ -n "$s" ]] || return 0
  if [[ "$s" == *+* ]]; then
    IFS=+ read -ra parts <<< "$s"
    key="${parts[${#parts[@]} - 1]}"
    for part in "${parts[@]:0:${#parts[@]}-1}"; do
      case "$(tr '[:upper:]' '[:lower:]' <<< "$part")" in
        command | cmd | ctrl) mods+="C" ;;
        macctrl) mods+="T" ;;
        alt | option) mods+="A" ;;
        shift) mods+="S" ;;
        *) mods+="?$part" ;;
      esac
    done
  else
    key="$s"
    while :; do
      case "$key" in
        ⌘*) mods+="C" key="${key#⌘}" ;;
        ⌃*) mods+="T" key="${key#⌃}" ;;
        ⌥*) mods+="A" key="${key#⌥}" ;;
        ⇧*) mods+="S" key="${key#⇧}" ;;
        *) break ;;
      esac
    done
  fi
  case "$key" in
    ,) key=Comma ;;
    .) key=Period ;;
    ↑) key=Up ;;
    ↓) key=Down ;;
    ←) key=Left ;;
    →) key=Right ;;
  esac
  # Fixed modifier order so "Shift+Command" and "Command+Shift" compare equal.
  printf '%s%s%s%s+%s\n' \
    "$([[ $mods == *T* ]] && echo MacCtrl+)" "$([[ $mods == *A* ]] && echo Alt+)" \
    "$([[ $mods == *S* ]] && echo Shift+)" "$([[ $mods == *C* ]] && echo Command)" \
    "$(tr '[:lower:]' '[:upper:]' <<< "$key")"
}

GET_ALL_PREFS='function(D,done){chrome.settingsPrivate.getAllPrefs(function(ps){done(ps.map(function(p){return {key:p.key,value:p.value===undefined?null:p.value};}));});}'
GET_PREF='function(D,done){chrome.settingsPrivate.getPref(D.key,function(p){done(p?(p.value===undefined?null:p.value):null);});}'
SET_PREF='function(D,done){chrome.settingsPrivate.setPref(D.key,D.value,"",done);}'
GET_EXTENSIONS='function(D,done){chrome.developerPrivate.getExtensionsInfo(function(es){done(es.map(function(e){return {id:e.id,name:e.name,commands:(e.commands||[]).map(function(c){return {name:c.name,keybinding:c.keybinding};})};}));});}'
SET_COMMAND='function(D,done){chrome.developerPrivate.updateExtensionCommand({extensionId:D.id,commandName:D.command,keybinding:D.keybinding},function(){done(true);});}'

if [[ "$mode" == list ]]; then
  open_tab chrome://settings
  tab="$TAB"
  prefs="$(api_ok "$(call_api "$tab" '{}' "$GET_ALL_PREFS")")"
  yq -p=json -r '.[] | .key + " = " + (.value | to_json(0))' <<< "$prefs" \
    | LC_ALL=C sort | { grep -E -- "${filter:-.}" || true; }
  exit 0
fi

failures=0
fail() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}
verb="changed   "
$dry_run && verb="would set "

# Settings ------------------------------------------------------------------
if [[ "$(yq '.settings | length' "$config")" != 0 ]]; then
  open_tab chrome://settings
  tab="$TAB"
  prefs="$(api_ok "$(call_api "$tab" '{}' "$GET_ALL_PREFS")")"
  while IFS= read -r key; do
    data="$(KEY="$key" yq -o=json -I=0 '{"key": strenv(KEY), "value": .settings[strenv(KEY)]}' "$config")"
    want="$(canon "$(yq -p=json -o=json -I=0 '.value' <<< "$data")")"
    if [[ "$(KEY="$key" yq -p=json '[.[] | select(.key == strenv(KEY))] | length' <<< "$prefs")" == 0 ]]; then
      fail "unknown setting settings.$key (list them with --list-settings)"
      continue
    fi
    have="$(canon "$(KEY="$key" yq -p=json -o=json -I=0 '.[] | select(.key == strenv(KEY)) | .value' <<< "$prefs")")"
    if [[ "$have" == "$want" ]]; then
      echo "unchanged  settings.$key = $have"
      continue
    fi
    if $dry_run; then
      echo "$verb settings.$key: $have -> $want"
      continue
    fi
    ok="$(api_ok "$(call_api "$tab" "$data" "$SET_PREF")")"
    now="$(canon "$(api_ok "$(call_api "$tab" "$data" "$GET_PREF")")")"
    if [[ "$ok" != true || "$now" != "$want" ]]; then
      fail "could not set settings.$key to $want (Chrome reports $now; policy-managed or wrong type?)"
      continue
    fi
    echo "$verb settings.$key: $have -> $now"
  done < <(yq -r '.settings // {} | keys | .[]' "$config")
fi

# Shortcuts -----------------------------------------------------------------
if [[ "$(yq '.shortcuts | length' "$config")" != 0 ]]; then
  open_tab chrome://extensions/shortcuts
  tab="$TAB"
  exts="$(api_ok "$(call_api "$tab" '{}' "$GET_EXTENSIONS")")"
  while IFS= read -r ext; do
    matches="$(EXT="$ext" yq -p=json -o=json -I=0 '[.[] | select(.name == strenv(EXT))]' <<< "$exts")"
    count="$(yq -p=json 'length' <<< "$matches")"
    if [[ "$count" == 0 ]]; then
      fail "no installed extension is named \"$ext\""
      continue
    elif [[ "$count" != 1 ]]; then
      fail "$count installed extensions are named \"$ext\": $(yq -p=json -r '[.[].id] | join(", ")' <<< "$matches")"
      continue
    fi
    id="$(yq -p=json -r '.[0].id' <<< "$matches")"
    while IFS= read -r cmd; do
      label="shortcuts.\"$ext\".$cmd"
      want_raw="$(EXT="$ext" CMD="$cmd" yq -r '.shortcuts[strenv(EXT)][strenv(CMD)] // ""' "$config")"
      if [[ -z "$(CMD="$cmd" yq -p=json '.[0].commands[] | select(.name == strenv(CMD)) | .name' <<< "$matches")" ]]; then
        fail "$ext has no command \"$cmd\"; it has: $(yq -p=json -r '[.[0].commands[].name] | join(", ")' <<< "$matches")"
        continue
      fi
      have_raw="$(ID="$id" CMD="$cmd" yq -p=json -r '.[] | select(.id == strenv(ID)) | .commands[] | select(.name == strenv(CMD)) | .keybinding' <<< "$exts")"
      want="$(norm_key "$want_raw")"
      have="$(norm_key "$have_raw")"
      if [[ "$want" == "$have" ]]; then
        echo "unchanged  $label = ${want:-(none)}"
        continue
      fi
      if $dry_run; then
        echo "$verb $label: ${have:-(none)} -> ${want:-(none)}"
        continue
      fi
      data="$(ID="$id" CMD="$cmd" KB="$want_raw" yq -n -o=json -I=0 '{"id": strenv(ID), "command": strenv(CMD), "keybinding": strenv(KB)}')"
      api_ok "$(call_api "$tab" "$data" "$SET_COMMAND")" > /dev/null
      exts="$(api_ok "$(call_api "$tab" '{}' "$GET_EXTENSIONS")")"
      now="$(norm_key "$(ID="$id" CMD="$cmd" yq -p=json -r '.[] | select(.id == strenv(ID)) | .commands[] | select(.name == strenv(CMD)) | .keybinding' <<< "$exts")")"
      if [[ "$now" != "$want" ]]; then
        fail "could not set $label to ${want:-(none)} (Chrome reports ${now:-(none)})"
        continue
      fi
      echo "$verb $label: ${have:-(none)} -> ${now:-(none)}"
    done < <(EXT="$ext" yq -r '.shortcuts[strenv(EXT)] | keys | .[]' "$config")
  done < <(yq -r '.shortcuts // {} | keys | .[]' "$config")
fi

if ((failures)); then
  if $dry_run; then
    echo "$failures error(s)" >&2
  else
    echo "$failures error(s); the rest was applied" >&2
  fi
  exit 1
fi
