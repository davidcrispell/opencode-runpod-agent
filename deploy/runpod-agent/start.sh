#!/usr/bin/env bash
set -euo pipefail

: "${HF_BUCKET_ID:?HF_BUCKET_ID is required}"
: "${HF_BUCKET_PREFIX:?HF_BUCKET_PREFIX is required}"
: "${LLAMA_API_KEY:?LLAMA_API_KEY is required}"
: "${OPENCODE_PASSWORD:?OPENCODE_PASSWORD is required}"

model_root="${MODEL_ROOT:-/workspace/models}"
model_dir="${model_root}/${HF_BUCKET_PREFIX}"
agent_workspace="${AGENT_WORKSPACE:-/workspace/agent}"
model_port="8000"
opencode_port="${OPENCODE_PORT:-4096}"
mkdir -p "$model_dir" "$agent_workspace" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

first_shard=""
for candidate in "$model_dir"/*-00001-of-*.gguf; do
    if [[ -f "$candidate" ]]; then
        first_shard="$candidate"
        break
    fi
done

if [[ -z "$first_shard" ]]; then
    echo "Downloading ${HF_BUCKET_ID}/${HF_BUCKET_PREFIX} to ${model_dir} ..."
    hf buckets sync \
        "hf://buckets/${HF_BUCKET_ID}/${HF_BUCKET_PREFIX}" \
        "$model_dir" \
        --include "*.gguf"

    for candidate in "$model_dir"/*-00001-of-*.gguf; do
        if [[ -f "$candidate" ]]; then
            first_shard="$candidate"
            break
        fi
    done
fi

if [[ -z "$first_shard" ]]; then
    echo "No first GGUF shard was found in ${model_dir}." >&2
    exit 1
fi

model_log="${MODEL_LOG:-/workspace/llama-server.log}"
echo "Starting llama-server from ${first_shard}"
/app/llama-server \
    --model "$first_shard" \
    --alias deepseek-v4.1-flash \
    --host 127.0.0.1 \
    --port "$model_port" \
    --api-key "$LLAMA_API_KEY" \
    --ctx-size "${LLAMA_CTX_SIZE:-32768}" \
    --parallel "${LLAMA_PARALLEL:-1}" \
    --n-predict "${LLAMA_MAX_TOKENS:-4096}" \
    --n-gpu-layers all \
    --split-mode layer \
    --cache-type-k "${LLAMA_CACHE_TYPE_K:-q8_0}" \
    --cache-type-v "${LLAMA_CACHE_TYPE_V:-q8_0}" \
    --jinja \
    --metrics \
    >"$model_log" 2>&1 &
model_pid=$!

cleanup() {
    kill "$model_pid" 2>/dev/null || true
    wait "$model_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Waiting for llama-server on 127.0.0.1:${model_port} ..."
for _ in $(seq 1 1800); do
    if ! kill -0 "$model_pid" 2>/dev/null; then
        echo "llama-server exited before becoming ready." >&2
        tail -n 200 "$model_log" >&2 || true
        exit 1
    fi
    if curl --fail --silent \
        --header "Authorization: Bearer ${LLAMA_API_KEY}" \
        "http://127.0.0.1:${model_port}/health" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! curl --fail --silent --show-error \
    --header "Authorization: Bearer ${LLAMA_API_KEY}" \
    "http://127.0.0.1:${model_port}/health" >/dev/null; then
    echo "llama-server did not become ready in time." >&2
    tail -n 200 "$model_log" >&2 || true
    exit 1
fi

echo "Starting OpenCode in ${agent_workspace} on port ${opencode_port}"
cd "$agent_workspace"
exec opencode serve --hostname 0.0.0.0 --port "$opencode_port"
