#!/bin/zsh

set -euo pipefail

probe_dir="${0:A:h}"
repo_root="${probe_dir:h:h}"
probe_app="/Applications/XDialNEProbe.app"
probe_binary="$probe_app/Contents/MacOS/XDialNEProbe"
probe_extension_id="com.kafeifei.xdial.ne-probe.extension"
controlled_host="git.xindong.com"
controlled_address="139.196.60.210"

if [[ ! -x "$probe_binary" ]]; then
  print -u2 "signed probe is unavailable: $probe_binary"
  exit 2
fi
if ! systemextensionsctl list | grep -F "$probe_extension_id" | grep -q "activated enabled"; then
  print -u2 "probe system extension is not activated"
  exit 2
fi
if ! command -v tailscale >/dev/null; then
  print -u2 "tailscale CLI is unavailable"
  exit 2
fi
if ! command -v jq >/dev/null; then
  print -u2 "jq is unavailable"
  exit 2
fi

baseline_interface="$(
  /sbin/route -n get default |
    awk '/interface:/{print $2; exit}'
)"
if [[ -z "$baseline_interface" ]]; then
  print -u2 "default interface is unavailable"
  exit 2
fi
baseline_state="$(tailscale status --json)"
if [[ "$(jq -r '.BackendState' <<<"$baseline_state")" != "Running" ]] ||
   [[ "$(jq -r '.ExitNodeStatus.Online // false' <<<"$baseline_state")" != "true" ]]; then
  print -u2 "Tailscale baseline is not ready"
  exit 2
fi

cleanup() {
  "$probe_binary" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP

verify_underlay() {
  local current_state current_interface
  current_state="$(tailscale status --json)"
  current_interface="$(
    /sbin/route -n get default |
      awk '/interface:/{print $2; exit}'
  )"
  if [[ "$(jq -r '.BackendState' <<<"$current_state")" != "Running" ]] ||
     [[ "$(jq -r '.ExitNodeStatus.Online // false' <<<"$current_state")" != "true" ]] ||
     [[ "$current_interface" != "$baseline_interface" ]]; then
    print -u2 "Underlay changed while the probe was enabled"
    return 1
  fi
}

configure_output="$("$probe_binary" configure-scoped)"
print -r -- "$configure_output"
trial_id="${configure_output##*trial=}"
if [[ -z "$trial_id" || "$trial_id" == "$configure_output" || "$trial_id" == *' '* ]]; then
  print -u2 "probe did not return a valid trial identifier"
  exit 1
fi

probe_connected=false
for attempt in {1..15}; do
  verify_underlay
  probe_status="$("$probe_binary" status)"
  if [[ "$probe_status" == *"status=connected" ]]; then
    probe_connected=true
    break
  fi
  if [[ "$probe_status" == *"status=invalid" ||
        "$probe_status" == *"status=disconnected" ]]; then
    print -u2 "probe failed to connect: $probe_status"
    exit 1
  fi
  sleep 1
done
if [[ "$probe_connected" != "true" ]]; then
  print -u2 "probe did not become connected"
  exit 1
fi

curl \
  --silent \
  --show-error \
  --insecure \
  --head \
  --connect-timeout 5 \
  --max-time 10 \
  --resolve "$controlled_host:443:$controlled_address" \
  "https://$controlled_host/" >/dev/null

verify_underlay
probe_status="$("$probe_binary" status)"
if [[ "$probe_status" != *"status=connected" ]]; then
  print -u2 "probe stopped before observation completed: $probe_status"
  exit 1
fi

probe_logs="$(/usr/bin/log show \
  --last 2m \
  --style compact \
  --predicate 'subsystem == "com.kafeifei.xdial.ne-probe.extension"')"
print -r -- "$probe_logs" | tail -n 40
if ! grep -F "flow trial=$trial_id" <<<"$probe_logs" >/dev/null; then
  print -u2 "no flow from this trial was observed"
  exit 1
fi
