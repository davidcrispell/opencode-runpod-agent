FROM ghcr.io/ggml-org/llama.cpp:server-cuda13-b11870@sha256:2ac42bff86574137dd69b1c8ad85330729d8292e1b4fac0639b67a722c4e9558

ARG OPENCODE_VERSION=2.2.2
ARG OPENCODE_SHA256=31c9dd2e77ac080aa6b9b6a06785fcfba5cfa795644ced62e88841f2b90c6dc0

USER root

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates curl git python3 python3-pip tini \
    && python3 -m pip install --break-system-packages --no-cache-dir "huggingface_hub==1.30.0" \
    && curl --fail --location --silent --show-error \
        "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-x64-baseline.tar.gz" \
        --output /tmp/opencode.tar.gz \
    && echo "${OPENCODE_SHA256}  /tmp/opencode.tar.gz" | sha256sum --check --strict \
    && tar -xzf /tmp/opencode.tar.gz -C /usr/local/bin opencode \
    && chmod 0755 /usr/local/bin/opencode \
    && opencode --version \
    && rm -f /tmp/opencode.tar.gz \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY deploy/runpod-agent/opencode.json /opt/runpod-agent/opencode.json
COPY deploy/runpod-agent/start.sh /opt/runpod-agent/start.sh
RUN chmod 0444 /opt/runpod-agent/opencode.json \
    && chmod 0755 /opt/runpod-agent/start.sh

ENV OPENCODE_CONFIG=/opt/runpod-agent/opencode.json \
    OPENCODE_CONFIG_PROJECT_DISABLE=true \
    OPENCODE_DISABLE_CLAUDE_CODE=true \
    OPENCODE_DISABLE_MODELS_FETCH=true \
    XDG_DATA_HOME=/workspace/.opencode/data \
    XDG_CACHE_HOME=/workspace/.opencode/cache \
    XDG_STATE_HOME=/workspace/.opencode/state

EXPOSE 4096

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/runpod-agent/start.sh"]
