#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
    echo "Usage: $0 /absolute/path/to/project" >&2
    exit 1
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
opencode_bin="${OPENCODE_BIN:-$script_dir/.runtime/bin/opencode}"
if [[ ! -x "$opencode_bin" ]]; then opencode_bin=opencode; fi
if [[ "$("$opencode_bin" --version)" != "opencode v2.2.2" ]]; then
    echo "This launcher requires OpenCode v2.2.2." >&2
    exit 1
fi

config_dir="$(mktemp -d)"
trap 'rm -f "$config_dir/opencode.json"; rmdir "$config_dir"' EXIT
python3 - "$script_dir/opencode.json" "$config_dir/opencode.json" "${RUNPOD_ACCESS_FILE:-$script_dir/.runtime/access.json}" <<'PY'
import json
import os
import sys

with open(sys.argv[1]) as source:
    config = json.load(source)
access = {}
if os.path.isfile(sys.argv[3]):
    with open(sys.argv[3]) as source:
        access = json.load(source)
base_url = os.environ.get("MODEL_BASE_URL")
if not base_url and access.get("pod_id"):
    base_url = "https://" + access["pod_id"] + "-8000.proxy.runpod.net/v1"
key = os.environ.get("LLAMA_API_KEY") or access.get("model_key")
if not base_url or not key:
    raise SystemExit("Set MODEL_BASE_URL and LLAMA_API_KEY, or provide a private Runpod access file.")
provider = config["providers"]["runpod-local"]
provider["name"] = "Runpod remote model / local tools"
provider["settings"]["baseURL"] = base_url
provider["settings"]["apiKey"] = key
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
