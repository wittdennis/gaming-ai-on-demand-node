#!/usr/bin/env bash
# Frees the card without stopping the cluster, for GPU work that is not a game and so never
# reaches the gamemode hook: rendering, encoding, a game started without gamemoderun.
#
#   OLLAMA_TOKEN=... hack/unload-models.sh            # everything currently resident
#   OLLAMA_TOKEN=... hack/unload-models.sh qwen3.6:27b
#
# Models reload on the next request, so this costs a reload and nothing else.
set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-https://ollama.otter.derwitt.site:11434}"
: "${OLLAMA_TOKEN:?set OLLAMA_TOKEN}"

api() { curl -sS --fail-with-body -H "Authorization: Bearer ${OLLAMA_TOKEN}" "$@"; }

loaded() {
  api "${OLLAMA_URL}/api/ps" | python3 -c '
import json,sys
for m in json.load(sys.stdin).get("models", []):
    print(m.get("model") or m.get("name"))
'
}

models=("$@")
if [ "${#models[@]}" -eq 0 ]; then
  mapfile -t models < <(loaded)
fi

if [ "${#models[@]}" -eq 0 ]; then
  echo "Nothing resident."
  exit 0
fi

for m in "${models[@]}"; do
  # keep_alive 0 unloads immediately rather than waiting out OLLAMA_KEEP_ALIVE.
  api -X POST "${OLLAMA_URL}/api/generate" \
    -d "$(python3 -c '
import json,sys
print(json.dumps({"model": sys.argv[1], "keep_alive": 0}))
' "$m")" >/dev/null
  echo "unloaded ${m}"
done

# The API reports what it has released; the card is what decides whether that is true.
if remaining=$(loaded) && [ -n "$remaining" ]; then
  echo "still resident: ${remaining}" >&2
  exit 1
fi
echo "Card is free."
