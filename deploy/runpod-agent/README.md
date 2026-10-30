# OpenCode agent on Runpod

Fork: https://github.com/davidcrispell/opencode-runpod-agent/tree/runpod-agent

Image: `ghcr.io/davidcrispell/opencode-runpod-agent:2.2.2-v2`

The container starts a local GGUF model with llama.cpp, then serves OpenCode's web UI and API on port 4096. OpenCode can read and edit files, execute shell commands, and iterate on their output. Its default working directory is `/workspace/agent`.

OpenCode is pinned to v2.2.2 and verified against its release archive checksum. The CUDA 13 llama.cpp image is pinned by digest. This fork is not affiliated with or endorsed by OpenCode.

## Small test model

Use `test-model.env.example` for the pinned `ggml-org/Qwen3-4B-GGUF` Q4_K_M model (about 2.5 GB). It runs on one GPU; an RTX A4500 20 GB is sufficient for the configured 16384-token context. Recheck Runpod availability and price before launch.

Configure a Secure Cloud Pod with:

- Image above, or its published digest.
- One GPU, host CUDA 13.0 or newer.
- 20 GB container disk and a 10 GB persistent disk mounted at `/workspace` for the small model.
- HTTP port `4096`; Jupyter and SSH disabled.
- Environment from `test-model.env.example`.
- Distinct random `LLAMA_API_KEY` and `OPENCODE_PASSWORD`, stored as Runpod account secrets.

Open `https://POD_ID-4096.proxy.runpod.net` after the services are ready. Sign in with the OpenCode password (username `opencode` if requested). The web shell loads before sign-in; API requests require authentication.

## DeepSeek bucket profile

To use the original model, omit `HF_REPO_ID`, `HF_FILENAME`, and `HF_REVISION`, and set:

```text
HF_BUCKET_ID=dcrispell/DeepSeek-V4.1-Flash-1017-abliterated-GGUF-bucket
HF_BUCKET_PREFIX=Q2_K
SERVED_MODEL_NAME=deepseek-v4.1-flash
MODEL_DISPLAY_NAME=DeepSeek V4.1 Flash Abliterated
LLAMA_CTX_SIZE=8192
LLAMA_MAX_TOKENS=2048
```

Q2_K requires roughly 246 GiB of model files. Use at least 300 GB of storage; the conservative initial shape is 4× A100 SXM 80 GB. This is a separate, expensive profile: the small-model smoke test does not prove DeepSeek tool-call reliability or memory fit. Set `HF_TOKEN` only for a private bucket. Bucket sync runs on every start and resumes incomplete downloads.

Alternatively set `MODEL_FILE` to an existing GGUF file. Repository downloads require an exact `HF_FILENAME` and immutable 40-character `HF_REVISION`.

## Execution on your Mac

The web UI above executes tools on the Pod. For local files and commands, run a separate local OpenCode instance using the same remote model:

1. Enable `LLAMA_HOST=0.0.0.0` and expose HTTP port `8000` on the Pod. The model API requires `LLAMA_API_KEY`.
2. Install OpenCode **v2.2.2**, or set `OPENCODE_BIN` to that release's binary.
3. Set `MODEL_BASE_URL=https://POD_ID-8000.proxy.runpod.net/v1`, `LLAMA_API_KEY`, and `SERVED_MODEL_NAME=qwen3-4b` in your terminal. Then run:

```bash
bash deploy/runpod-agent/local-agent.sh /absolute/path/to/your/project
```

This launcher starts a private local OpenCode server and asks before changes and command execution. Model requests, including file content supplied by the local tools, go to your Runpod model. It does not provide the remote agent with an inbound shell on your Mac.

## Permissions and lifecycle

The cloud profile allows normal tools automatically, asks before selected shell commands such as `rm`, `sudo`, `git push`, and `git reset`, and denies the `external_directory` permission. These are OpenCode approval rules, **not an operating-system sandbox**: allowed shell programs have the container user's filesystem access. The container currently runs as root. Keep unrelated credentials and projects out of it.

Only the configured `runpod-local` provider is allowed. Cloud providers, sharing, and automatic updates are disabled. Download credentials are removed from the agent's environment after model setup.

Both services are supervised: if either exits, the container exits. Container exit alone does **not** guarantee Runpod billing stops. Stop the Pod from Runpod when finished; terminate a disposable test Pod to remove its disks. Persistent Pod disk survives stop, but is deleted on termination. A network volume survives either and bills until separately deleted.

Optional settings include `AGENT_WORKSPACE`, `LLAMA_CTX_SIZE`, `LLAMA_MAX_TOKENS`, `LLAMA_PARALLEL`, `LLAMA_CHAT_TEMPLATE_KWARGS`, `LLAMA_HOST`, `MODEL_PORT`, and `OPENCODE_PORT`. Runtime model limits are generated from the same context/output values used by llama.cpp.

## Build

The `Runpod agent image` GitHub Actions workflow builds and pushes `linux/amd64`. To build manually:

```bash
docker buildx build --platform linux/amd64 \
  --file deploy/runpod-agent/Dockerfile \
  --tag YOUR_REGISTRY/opencode-runpod-agent:2.2.2-v2 --push .
```

Use versioned tags or digests. Do not use `latest`.
