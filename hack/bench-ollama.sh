#!/usr/bin/env bash
# Measures throughput and VRAM for a set of models, and checks that VRAM is returned once
# OLLAMA_KEEP_ALIVE expires. Output is a markdown table.
#
#   OLLAMA_TOKEN=... hack/bench-ollama.sh qwen3-coder:30b qwen2.5-coder:32b
#
# Inference is driven over the endpoint, so this runs from anywhere. Whole-GPU readings come
# from rocm-smi, which has to execute on the machine itself; set SSH_HOST to reach it from
# elsewhere. Ollama's own per-model figure needs neither and is reported alongside, because it
# answers a different question: how much of the model reached the GPU at all.
#
#   SSH_HOST=otter OLLAMA_TOKEN=... hack/bench-ollama.sh qwen3-coder:30b
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: OLLAMA_TOKEN=... $0 <model> [model...]" >&2
  echo "example: SSH_HOST=otter OLLAMA_TOKEN=... $0 qwen3-coder:30b qwen2.5-coder:32b" >&2
  exit 1
fi

OLLAMA_URL="${OLLAMA_URL:-https://ollama.otter.derwitt.site:11434}"
: "${OLLAMA_TOKEN:?set OLLAMA_TOKEN}"
RUNS="${RUNS:-3}"
PROMPT="${PROMPT:-Write a Go function that merges two sorted integer slices into one sorted slice, with a short explanation.}"
NUM_PREDICT="${NUM_PREDICT:-512}"

# The discrete card, by the unique id the pod also pins on. The iGPU shares system memory and
# would otherwise be averaged into these readings.
XTX_DID="${XTX_DID:-0x744c}"

api() { curl -sS --fail-with-body -H "Authorization: Bearer ${OLLAMA_TOKEN}" "$@"; }

# Empty unless SSH_HOST is set, in which case rocm-smi runs there instead of locally.
runner() { if [ -n "${SSH_HOST:-}" ]; then ssh -n "$SSH_HOST" "$@"; else "$@"; fi; }

# A non-interactive ssh session gets a minimal PATH, and the ROCm packages install outside it.
# Resolved once, and fatal if absent: a missing reading would otherwise report as 0 MiB and
# quietly turn the whole table into fiction.
resolve_rocm_smi() {
  local c
  for c in ${ROCM_SMI:-} rocm-smi /opt/rocm/bin/rocm-smi; do
    if runner command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  echo "rocm-smi not found${SSH_HOST:+ on $SSH_HOST}; set ROCM_SMI to its path" >&2
  return 1
}
ROCM_SMI="$(resolve_rocm_smi)"

vram_mib() {
  runner "$ROCM_SMI" --showmeminfo vram --csv 2>/dev/null |
    awk -F, -v want="$XTX_DID" '
      NR==1 { for (i=1;i<=NF;i++) if ($i ~ /Used/) used=i; next }
      $0 ~ /card/ && used { print int($used/1048576); exit }'
}

baseline="$(vram_mib || echo 0)"
echo "Desktop baseline VRAM: ${baseline} MiB (measured before any model is loaded)"
echo
echo "| model | weights | load s | tok/s | on GPU | VRAM (ollama) | peak VRAM MiB | over baseline |"
echo "|---|---|---|---|---|---|---|---|"

for model in "$@"; do
  api -X POST "${OLLAMA_URL}/api/pull" -d "{\"model\":\"${model}\"}" >/dev/null

  best_tps=0 load_s=0 peak=0
  for _ in $(seq "$RUNS"); do
    resp="$(api -X POST "${OLLAMA_URL}/api/generate" -d "$(python3 -c '
import json,sys
model, prompt, npredict = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(json.dumps({"model": model, "prompt": prompt,
                  "stream": False, "options": {"num_predict": npredict}}))
' "$model" "$PROMPT" "$NUM_PREDICT")")"
    cur="$(vram_mib || echo 0)"
    [ "$cur" -gt "$peak" ] && peak="$cur"

    read -r tps ld <<<"$(python3 -c '
import json,sys
d = json.load(sys.stdin)
ev, dur = d.get("eval_count", 0), d.get("eval_duration", 0)
print("%.1f %.1f" % (ev / (dur / 1e9) if dur else 0, d.get("load_duration", 0) / 1e9))
' <<<"$resp")"
    awk "BEGIN{exit !($tps > $best_tps)}" && best_tps="$tps"
    load_s="$ld"
  done

  # size_vram below total size means layers stayed on the CPU, which reads as poor tok/s
  # rather than an error.
  onstats="$(api "${OLLAMA_URL}/api/ps" | python3 -c '
import json,sys
m = sys.argv[1]
for x in json.load(sys.stdin).get("models", []):
    if m in (x.get("name"), x.get("model")):
        tot, vram = x.get("size", 0), x.get("size_vram", 0)
        print("%.1f %d" % (vram / 1e9, round(100 * vram / tot) if tot else 0)); break
else:
    print("0.0 0")
' "$model")"
  read -r vram_gb on_gpu_pct <<<"$onstats"

  size="$(api "${OLLAMA_URL}/api/tags" | python3 -c '
import json,sys
m = sys.argv[1]
for x in json.load(sys.stdin)["models"]:
    if m in (x["name"], x["model"]):
        print("%.1f GB" % (x["size"] / 1e9)); break
else:
    print("?")
' "$model")"

  echo "| ${model} | ${size} | ${load_s} | ${best_tps} | ${on_gpu_pct}% | ${vram_gb} GB | ${peak} | $((peak - baseline)) |"
done

echo
echo "Unloading, then watching for VRAM release (OLLAMA_KEEP_ALIVE governs this)."
for m in "$@"; do
  api -X POST "${OLLAMA_URL}/api/generate" -d "{\"model\":\"${m}\",\"keep_alive\":0}" >/dev/null || true
done
sleep 15
after="$(vram_mib || echo 0)"
echo "VRAM after unload: ${after} MiB (baseline ${baseline} MiB, delta $((after - baseline)) MiB)"
