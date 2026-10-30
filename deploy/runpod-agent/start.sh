#!/usr/bin/env bash
set -euo pipefail

: "${LLAMA_API_KEY:?LLAMA_API_KEY is required}"
: "${OPENCODE_PASSWORD:?OPENCODE_PASSWORD is required}"

model_root="${MODEL_ROOT:-/workspace/models}"
agent_workspace="${AGENT_WORKSPACE:-/workspace/agent}"
model_port="${MODEL_PORT:-8000}"
opencode_port="${OPENCODE_PORT:-4096}"
served_model="${SERVED_MODEL_NAME:-runpod-model}"
context_size="${LLAMA_CTX_SIZE:-16384}"
max_tokens="${LLAMA_MAX_TOKENS:-4096}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/workspace/.opencode/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/workspace/.opencode/cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-/workspace/.opencode/state}"
mkdir -p "$model_root" "$agent_workspace" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

model_file="${MODEL_FILE:-}"
if [[ -z "$model_file" && -n "${HF_REPO_ID:-}" ]]; then
    : "${HF_FILENAME:?HF_FILENAME is required with HF_REPO_ID}"
    : "${HF_REVISION:?HF_REVISION must pin the Hugging Face repository commit}"
    if [[ ! "$HF_REVISION" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "HF_REVISION must be an immutable 40-character commit SHA." >&2
        exit 1
    fi
    model_dir="${model_root}/repos/${HF_REPO_ID}/${HF_REVISION}"
    mkdir -p "$model_dir"
    echo "Downloading ${HF_REPO_ID}/${HF_FILENAME} at ${HF_REVISION} ..."
    hf download "$HF_REPO_ID" "$HF_FILENAME" \
        --revision "$HF_REVISION" \
        --local-dir "$model_dir"
    model_file="${model_dir}/${HF_FILENAME}"
elif [[ -z "$model_file" ]]; then
    : "${HF_BUCKET_ID:?Set MODEL_FILE, HF_REPO_ID, or HF_BUCKET_ID}"
    : "${HF_BUCKET_PREFIX:?HF_BUCKET_PREFIX is required with HF_BUCKET_ID}"
    model_dir="${model_root}/${HF_BUCKET_PREFIX}"
    mkdir -p "$model_dir"
    # Sync every start: the first shard may exist after an interrupted download.
    echo "Syncing ${HF_BUCKET_ID}/${HF_BUCKET_PREFIX} to ${model_dir} ..."
    hf buckets sync \
        "hf://buckets/${HF_BUCKET_ID}/${HF_BUCKET_PREFIX}" \
        "$model_dir" \
        --include "*.gguf"
    for candidate in "$model_dir"/*-00001-of-*.gguf; do
        if [[ -f "$candidate" ]]; then
            model_file="$candidate"
            break
        fi
    done
fi

if [[ -z "$model_file" || ! -f "$model_file" ]]; then
    echo "No GGUF model found. Set MODEL_FILE, an exact HF_FILENAME, or a bucket containing GGUF shards." >&2
    exit 1
fi
model_file="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$model_file")"

config_template="${OPENCODE_CONFIG:-/opt/runpod-agent/opencode.json}"
runtime_config="${XDG_STATE_HOME}/runpod-agent.json"
python3 - "$config_template" "$runtime_config" "$served_model" "$context_size" "$max_tokens" \
    "${MODEL_DISPLAY_NAME:-$served_model}" "${MODEL_BASE_URL:-http://127.0.0.1:${model_port}/v1}" <<'PY'
import json
import os
import sys

template, destination, model_id, context, output, display_name, base_url = sys.argv[1:]
with open(template, encoding="utf-8") as source:
    config = json.load(source)
provider = config["providers"]["runpod-local"]
model = next(iter(provider["models"].values()))
model["name"] = display_name
model["limit"] = {"context": int(context), "output": int(output)}
if int(context) <= int(output) or int(output) <= 0:
    raise SystemExit("LLAMA_CTX_SIZE must exceed LLAMA_MAX_TOKENS, and both must be positive.")
provider["models"] = {model_id: model}
provider["settings"]["baseURL"] = base_url
config["model"] = f"runpod-local/{model_id}"
descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as target:
    json.dump(config, target, indent=2)
    target.write("\n")
os.chmod(destination, 0o600)
PY
export OPENCODE_CONFIG="$runtime_config"

# These credentials are only needed for provisioning/downloads, not agent tools.
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN RUNPOD_API_KEY

model_pid=""
agent_pid=""
cleanup() {
    trap - EXIT INT TERM
    if [[ -n "$agent_pid" ]]; then kill "$agent_pid" 2>/dev/null || true; fi
    if [[ -n "$model_pid" ]]; then kill "$model_pid" 2>/dev/null || true; fi
    if [[ -n "$agent_pid" ]]; then wait "$agent_pid" 2>/dev/null || true; fi
    if [[ -n "$model_pid" ]]; then wait "$model_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

model_log="${MODEL_LOG:-/workspace/llama-server.log}"
model_args=(
    --model "$model_file"
    --alias "$served_model"
    --host "${LLAMA_HOST:-127.0.0.1}"
    --port "$model_port"
    --api-key "$LLAMA_API_KEY"
    --ctx-size "$context_size"
    --parallel "${LLAMA_PARALLEL:-1}"
    --n-predict "$max_tokens"
    --n-gpu-layers all
    --split-mode layer
    --cache-type-k "${LLAMA_CACHE_TYPE_K:-q8_0}"
    --cache-type-v "${LLAMA_CACHE_TYPE_V:-q8_0}"
    --jinja
    --metrics
)
if [[ -n "${LLAMA_CHAT_TEMPLATE_KWARGS:-}" ]]; then
    model_args+=(--chat-template-kwargs "$LLAMA_CHAT_TEMPLATE_KWARGS")
fi
echo "Starting llama-server from ${model_file}"
/app/llama-server "${model_args[@]}" >"$model_log" 2>&1 &
model_pid=$!

echo "Waiting for llama-server on 127.0.0.1:${model_port} ..."
deadline=$((SECONDS + ${LLAMA_STARTUP_TIMEOUT:-3600}))
until curl --fail --silent --connect-timeout 2 --max-time 5 \
    --header "Authorization: Bearer ${LLAMA_API_KEY}" \
    "http://127.0.0.1:${model_port}/health" >/dev/null 2>&1; do
    if ! kill -0 "$model_pid" 2>/dev/null; then
        echo "llama-server exited before becoming ready." >&2
        tail -n 100 "$model_log" >&2 || true
        exit 1
    fi
    if (( SECONDS >= deadline )); then
        echo "llama-server did not become ready in time." >&2
        tail -n 100 "$model_log" >&2 || true
        exit 1
    fi
    sleep 2
done

echo "Starting OpenCode in ${agent_workspace} on port ${opencode_port}"
cd "$agent_workspace"
opencode serve --hostname 0.0.0.0 --port "$opencode_port" &
agent_pid=$!

# Keep PID 1 informed if either service dies after startup.
set +e
wait -n "$model_pid" "$agent_pid"
child_status=$?
set -e
echo "A required service exited (status ${child_status}); stopping the Pod services." >&2
if ! kill -0 "$model_pid" 2>/dev/null; then tail -n 100 "$model_log" >&2 || true; fi
if (( child_status == 0 )); then child_status=1; fi
exit "$child_status"
