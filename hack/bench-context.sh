#!/usr/bin/env bash
# Finds where a model stops fitting as its context grows. llama.cpp allocates the KV cache at
# load time, so a short prompt with a large num_ctx costs the same VRAM as a full one: the
# question is answered without having to generate a huge prompt.
#
#   OLLAMA_TOKEN=... hack/bench-context.sh qwen3-coder:30b
#   SSH_HOST=otter CTX_LIST="8192 32768 131072" OLLAMA_TOKEN=... hack/bench-context.sh qwen3.6:27b
#
# Watch the "on GPU" column: the first value below 100% is the ceiling, and the tok/s beside it
# shows what exceeding it costs.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: OLLAMA_TOKEN=... $0 <model>" >&2
  exit 1
fi

model="$1"
OLLAMA_URL="${OLLAMA_URL:-https://ollama.otter.derwitt.site:11434}"
: "${OLLAMA_TOKEN:?set OLLAMA_TOKEN}"
CTX_LIST="${CTX_LIST:-4096 8192 16384 32768 65536 131072}"
PROMPT="${PROMPT:-Write a Go function that merges two sorted integer slices.}"
NUM_PREDICT="${NUM_PREDICT:-128}"
XTX_DID="${XTX_DID:-0x744c}"

api() { curl -sS --fail-with-body -H "Authorization: Bearer ${OLLAMA_TOKEN}" "$@"; }
runner() { if [ -n "${SSH_HOST:-}" ]; then ssh -n "$SSH_HOST" "$@"; else "$@"; fi; }

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

unload() { api -X POST "${OLLAMA_URL}/api/generate" -d "{\"model\":\"${model}\",\"keep_alive\":0}" >/dev/null || true; }

unload
sleep 5
baseline="$(vram_mib)"
echo "Model: ${model}"
echo "Baseline VRAM with nothing loaded: ${baseline} MiB"
echo
echo "| num_ctx | on GPU | VRAM (ollama) | peak MiB | over baseline | tok/s |"
echo "|---|---|---|---|---|---|"

for ctx in $CTX_LIST; do
  # Reload for each value: the KV cache is sized once, when the model is loaded.
  unload
  sleep 3

  resp="$(api -X POST "${OLLAMA_URL}/api/generate" -d "$(python3 -c '
import json,sys
model, prompt, npredict, ctx = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
print(json.dumps({"model": model, "prompt": prompt, "stream": False,
                  "options": {"num_predict": npredict, "num_ctx": ctx}}))
' "$model" "$PROMPT" "$NUM_PREDICT" "$ctx")" || true)"

  if [ -z "$resp" ]; then
    echo "| ${ctx} | request failed | | | | |"
    continue
  fi

  tps="$(python3 -c '
import json,sys
d = json.load(sys.stdin)
ev, dur = d.get("eval_count", 0), d.get("eval_duration", 0)
print("%.1f" % (ev / (dur / 1e9) if dur else 0))
' <<<"$resp")"

  peak="$(vram_mib)"
  read -r vram_gb on_gpu_pct <<<"$(api "${OLLAMA_URL}/api/ps" | python3 -c '
import json,sys
m = sys.argv[1]
for x in json.load(sys.stdin).get("models", []):
    if m in (x.get("name"), x.get("model")):
        tot, vram = x.get("size", 0), x.get("size_vram", 0)
        print("%.1f %d" % (vram / 1e9, round(100 * vram / tot) if tot else 0)); break
else:
    print("0.0 0")
' "$model")"

  echo "| ${ctx} | ${on_gpu_pct}% | ${vram_gb} GB | ${peak} | $((peak - baseline)) | ${tps} |"
done

unload
