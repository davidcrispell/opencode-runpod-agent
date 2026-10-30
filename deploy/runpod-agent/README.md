# OpenCode on Runpod with a local DeepSeek model

This image runs two processes in one Runpod Pod:

- `llama-server` on `127.0.0.1:8000` for the sharded GGUF model.
- OpenCode on `0.0.0.0:4096` for the password-protected web UI and agent API.

The model endpoint is not exposed publicly. OpenCode can read, edit, and execute commands only from `/workspace/agent` by default. Attempts to access other directories are denied, and destructive shell commands, pushes, and resets require approval.
Only the local `runpod-local` model provider is allowed; OpenCode's bundled cloud providers are blocked by policy.

This fork is not affiliated with or endorsed by the OpenCode project.

## Build

From the repository root:

```bash
docker buildx build \
  --platform linux/amd64 \
  --file deploy/runpod-agent/Dockerfile \
  --tag YOUR_REGISTRY/opencode-runpod-agent:2.2.2-v1 \
  --push \
  .
```

Use an explicit versioned tag. Do not deploy `latest`.

## Runpod template

Configure the Pod with:

- Container image: the versioned image built above.
- Exposed HTTP port: `4096`.
- Volume mount: `/workspace`.
- Start SSH: optional.
- CUDA floor: `13.0` for the pinned CUDA 13 llama.cpp image.

Required environment variables:

| Variable | Purpose |
| --- | --- |
| `HF_BUCKET_ID` | Hugging Face Bucket ID containing the sharded GGUF model. |
| `HF_BUCKET_PREFIX` | Bucket prefix such as `Q2_K`. |
| `HF_TOKEN` | Hugging Face token with access to the bucket. |
| `LLAMA_API_KEY` | Random bearer token used only between OpenCode and llama-server. |
| `OPENCODE_PASSWORD` | Password for the OpenCode web UI and API. |

Optional environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `AGENT_WORKSPACE` | `/workspace/agent` | Directory the agent may act in. |
| `LLAMA_CTX_SIZE` | `32768` | Model context length. Lower this if KV-cache allocation fails. |
| `LLAMA_MAX_TOKENS` | `4096` | Maximum generated tokens per model request. |
| `LLAMA_PARALLEL` | `1` | Concurrent llama-server slots. |
| `OPENCODE_PORT` | `4096` | OpenCode web/API port. |

Store all tokens and passwords as Runpod secrets. Do not commit them.

After the Pod becomes ready, open:

```text
https://POD_ID-4096.proxy.runpod.net
```

Sign in as `opencode` with `OPENCODE_PASSWORD`. Create or clone projects under `/workspace/agent`; actions taken by the agent occur inside the Pod, not on your computer.

## Notes

- OpenCode is pinned to `v2.2.2`; its Linux archive SHA-256 is verified during the image build.
- The llama.cpp base image is pinned by digest.
- OpenCode updates are disabled inside the container so an upstream release cannot silently change the running harness.
- The configured model advertises tool support. Actual tool-call reliability still depends on the model and its llama.cpp chat template.
