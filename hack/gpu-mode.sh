#!/usr/bin/env bash
# Switches the desktop off and on to free the VRAM it holds, and reports what that gained.
#
#   hack/gpu-mode.sh status
#   hack/gpu-mode.sh headless
#   hack/gpu-mode.sh desktop
#
# Only the running target changes; the default target is untouched, so a reboot always comes
# back up with a desktop no matter which state it was left in.
set -euo pipefail

# A non-interactive shell gets a minimal PATH, and the ROCm packages install outside it.
resolve_rocm_smi() {
  local c
  for c in ${ROCM_SMI:-} rocm-smi /opt/rocm/bin/rocm-smi; do
    if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  return 1
}

vram_mib() {
  local smi
  smi="$(resolve_rocm_smi)" || { echo "?"; return 0; }
  "$smi" --showmeminfo vram --csv 2>/dev/null |
    awk -F, '
      NR==1 { for (i=1;i<=NF;i++) if ($i ~ /Used/) used=i; next }
      $0 ~ /card/ && used { print int($used/1048576); exit }'
}

status() {
  echo "active target : $(systemctl get-default) (default), $(systemctl is-active graphical.target) graphical"
  echo "VRAM in use   : $(vram_mib) MiB"
}

case "${1:-status}" in
status)
  status
  ;;
headless | desktop)
  target=$([ "$1" = headless ] && echo multi-user.target || echo graphical.target)
  before="$(vram_mib)"

  # isolate tears down the graphical session, taking any terminal inside it. Over SSH or from a
  # TTY the caller survives, because sshd and getty belong to the target being kept.
  if [ "$1" = headless ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ "${FORCE:-0}" != 1 ]; then
    echo "Running inside the graphical session, which this will end (including this terminal)." >&2
    echo "Re-run from a TTY or over SSH, or set FORCE=1 to accept that." >&2
    exit 1
  fi

  sudo systemctl isolate "$target"
  sleep 5
  after="$(vram_mib)"
  echo "switched to ${1}: VRAM ${before} MiB -> ${after} MiB"
  ;;
*)
  echo "usage: $0 status|headless|desktop" >&2
  exit 1
  ;;
esac
