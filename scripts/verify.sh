#!/usr/bin/env bash
# scripts/verify.sh — smoke the two TEI servers + the LiteLLM `embed` hop.
#
# Returns non-zero if any check fails. Safe to re-run any time.
set -uo pipefail

PASS=0
FAIL=0
check() {
    if eval "$2"; then
        echo "  ✓ $1"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $1"
        FAIL=$((FAIL + 1))
    fi
}

echo "── Local health ──"
check "rerank :8084 /health 200" \
    "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8084/health | grep -q 200"
check "embed  :8085 /health 200" \
    "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8085/health | grep -q 200"

echo
echo "── Functional rerank ──"
RERANK_TOP=$(curl -s -X POST http://127.0.0.1:8084/rerank \
    -H "Content-Type: application/json" \
    -d '{"query":"add alias to broker","texts":["sparse bundles","add alias to mlx-broker yaml","git commit style"]}' \
    | python3 -c "import json,sys; s=sorted(json.load(sys.stdin),key=lambda x:-x['score']); print(s[0]['index'])" 2>/dev/null || echo "")
check "rerank picks the middle text (index 1)" "[ '$RERANK_TOP' = '1' ]"

echo
echo "── Functional embed (1024-dim) ──"
EMBED_DIM=$(curl -s -X POST http://127.0.0.1:8085/embed \
    -H "Content-Type: application/json" \
    -d '{"inputs":["hello"]}' \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin)[0]))" 2>/dev/null || echo "")
check "embed returns 1024-dim vectors" "[ '$EMBED_DIM' = '1024' ]"

echo
echo "── Tailnet bind ──"
check "rerank reachable via 100.82.76.20:8084" \
    "curl -s -o /dev/null -w '%{http_code}' -m 3 http://100.82.76.20:8084/health | grep -q 200"
check "embed  reachable via 100.82.76.20:8085" \
    "curl -s -o /dev/null -w '%{http_code}' -m 3 http://100.82.76.20:8085/health | grep -q 200"

echo
echo "── LiteLLM hop (embed alias) ──"
if [ -f "$HOME/llm/configs/secrets.env" ]; then
    # shellcheck disable=SC1091
    source "$HOME/llm/configs/secrets.env"
    LITELLM_DIM=$(curl -s -X POST http://127.0.0.1:4000/v1/embeddings \
        -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
        -H "Content-Type: application/json" \
        -d '{"model":"embed","input":"verify"}' \
        | python3 -c "import json,sys; print(len(json.load(sys.stdin)['data'][0]['embedding']))" 2>/dev/null || echo "")
    check "LiteLLM /v1/embeddings via 'embed' alias returns 1024-dim" "[ '$LITELLM_DIM' = '1024' ]"
else
    echo "  · skipping LiteLLM check (~/llm/configs/secrets.env not found)"
fi

echo
echo "── Supervised by launchd ──"
check "com.tei.rerank state = running" \
    "launchctl print gui/\$(id -u)/com.tei.rerank 2>&1 | grep -qE 'state = running'"
check "com.tei.embed  state = running" \
    "launchctl print gui/\$(id -u)/com.tei.embed 2>&1 | grep -qE 'state = running'"

echo
echo "═════ $PASS passed, $FAIL failed ═════"
exit "$FAIL"
