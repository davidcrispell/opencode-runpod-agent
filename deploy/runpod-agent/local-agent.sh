#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
    echo "Usage: $0 /absolute/path/to/project" >&2
    exit 1
fi
: "${MODEL_BASE_URL:?Set MODEL_BASE_URL to the authenticated Runpod model URL ending in /v1}"
: "${LLAMA_API_KEY:?Set LLAMA_API_KEY to the model API credential}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
opencode_bin="${OPENCODE_BIN:-opencode}"
if [[ "$("$opencode_bin" --version)" != "opencode v2.2.2" ]]; then
    echo "This launcher requires OpenCode v2.2.2." >&2
    exit 1
fi

config_dir="$(mktemp -d)"
trap 'rm -f "$config_dir/opencode.json"; rmdir "$config_dir"' EXIT
python3 - "$script_dir/opencode.json" "$config_dir/opencode.json" <<'PY'
import json
import os
import sys

with open(sys.argv[1]) as source:
    config = json.load(source)
provider = config["providers"]["runpod-local"]
provider["name"] = "Runpod remote model / local tools"
provider["settings"]["baseURL"] = os.environ["MODEL_BASE_URL"]
name = os.environ.get("SERVED_MODEL_NAME", "qwen3-4b")
model = provider["models"].pop("runpod-model")
model["name"] = os.environ.get("MODEL_DISPLAY_NAME", name)
model["limit"]["context"] = int(os.environ.get("LLAMA_CTX_SIZE", "16384"))
model["limit"]["output"] = int(os.environ.get("LLAMA_MAX_TOKENS", "4096"))
provider["models"][name] = model
config["model"] = "runpod-local/" + name
# Local execution is opt-in per command; the cloud profile is autonomous.
config["permissions"] = [
    {"action": "*", "resource": "*", "effect": "ask"},
    {"action": "read", "resource": "*", "effect": "allow"},
    {"action": "list", "resource": "*", "effect": "allow"},
    {"action": "glob", "resource": "*", "effect": "allow"},
    {"action": "grep", "resource": "*", "effect": "allow"},
    {"action": "external_directory", "resource": "*", "effect": "deny"},
    {"action": "read", "resource": "*.env", "effect": "ask"},
    {"action": "read", "resource": "*.env.*", "effect": "ask"},
]
with open(sys.argv[2], "w") as target:
    json.dump(config, target)
os.chmod(sys.argv[2], 0o600)
PY

export OPENCODE_CONFIG="$config_dir/opencode.json"
export OPENCODE_CONFIG_PROJECT_DISABLE=true
export OPENCODE_DISABLE_CLAUDE_CODE=true
export OPENCODE_DISABLE_MODELS_FETCH=true
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN RUNPOD_API_KEY
cd -- "$1"
echo "OpenCode will read files and run approved commands on this computer in $PWD."
"$opencode_bin" --standalone
