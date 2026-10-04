# BEAM versions match .tool-versions; all stages use Debian bookworm/glibc.
ARG BEAM_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.1-debian-bookworm-20260918-slim
ARG PYTHON_IMAGE=python:3.11-slim-bookworm
FROM ${BEAM_IMAGE} AS builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
COPY assets assets
COPY sidecar/semantic/models.v1.json sidecar/semantic/models.v1.json
COPY sidecar/prompt_guard/models.v1.json sidecar/prompt_guard/models.v1.json
COPY sidecar/tokenizer/models.v1.json sidecar/tokenizer/models.v1.json
COPY sidecar/tokenizer/granite.v1.json sidecar/tokenizer/granite.v1.json
RUN mix compile && mix assets.deploy
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${PYTHON_IMAGE} AS ner-builder
WORKDIR /build
COPY sidecar/ner/requirements.lock ./
RUN python -m venv /opt/ner && /opt/ner/bin/pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.8.0 && /opt/ner/bin/pip install --no-cache-dir -r requirements.lock
COPY sidecar/ner ./
RUN /opt/ner/bin/python models.py download /models

FROM ${PYTHON_IMAGE} AS semantic-builder
WORKDIR /build
COPY sidecar/semantic/requirements.lock ./
RUN python -m venv /opt/semantic && /opt/semantic/bin/pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.8.0 && /opt/semantic/bin/pip install --no-cache-dir -r requirements.lock
COPY sidecar/semantic ./
RUN /opt/semantic/bin/python models.py download /semantic-models

COPY sidecar/prompt_guard /build/prompt_guard
ARG WITH_PROMPT_GUARD=0
RUN --mount=type=secret,id=hf_token mkdir -p /prompt-guard-models && \
    if [ "$WITH_PROMPT_GUARD" = 1 ]; then \
      test -s /run/secrets/hf_token && HF_TOKEN="$(cat /run/secrets/hf_token)" && export HF_TOKEN && \
      HF_HOME=/tmp/prompt-guard-download HF_HUB_CACHE=/tmp/prompt-guard-download/hub \
      /opt/semantic/bin/python /build/prompt_guard/models.py download /prompt-guard-models && \
      rm -rf /tmp/prompt-guard-download; \
    elif [ "$WITH_PROMPT_GUARD" != 0 ]; then exit 1; fi

FROM ${PYTHON_IMAGE} AS runner
ARG WITH_PROMPT_GUARD=0
ENV PROMPT_GUARD_ENABLED=${WITH_PROMPT_GUARD} PROMPT_GUARD_BASE_URL=http://127.0.0.1:8004 PROMPT_GUARD_MODELS_DIR=/app/prompt-guard-models
COPY sidecar/tokenizer/requirements.lock /tmp/tokenizer-requirements.lock
RUN python -m venv /opt/tokenizer && /opt/tokenizer/bin/pip install --no-cache-dir -r /tmp/tokenizer-requirements.lock
COPY sidecar/tokenizer /app/tokenizer
RUN /opt/tokenizer/bin/python /app/tokenizer/models.py download /app/tokenizer-models
RUN /opt/tokenizer/bin/python /app/tokenizer/models.py download-granite /app/granite-tokenizer-models
ENV GRANITE_TOKENIZER_MODELS_DIR=/app/granite-tokenizer-models
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 libncurses6 libgomp1 openssl ca-certificates tini curl bash && rm -rf /var/lib/apt/lists/* && useradd --uid 10001 --create-home app
WORKDIR /app
COPY --from=builder --chown=app:app /app/_build/prod/rel/ai_control ./
COPY --from=ner-builder /opt/ner /opt/ner
COPY --from=ner-builder /models /app/models
COPY --chown=app:app sidecar/ner /app/ner
COPY --from=semantic-builder /opt/semantic /opt/semantic
COPY --from=semantic-builder /semantic-models /app/semantic-models
COPY --from=semantic-builder --chown=app:app /prompt-guard-models /app/prompt-guard-models
COPY --chown=app:app sidecar/prompt_guard /app/prompt_guard
COPY --chown=app:app sidecar/semantic /app/semantic
COPY --chmod=755 docker/start docker/healthcheck /app/docker/
COPY --chown=app:app scripts/approval_release_smoke.exs /app/scripts/approval_release_smoke.exs
ENV LANG=C.UTF-8 PHX_SERVER=true PORT=4000 NER_BASE_URL=http://127.0.0.1:8001 SEMANTIC_BASE_URL=http://127.0.0.1:8003 TOKENIZER_BASE_URL=http://127.0.0.1:8002 TOKENIZER_MODELS_DIR=/app/tokenizer-models STANZA_RESOURCES_DIR=/app/models SEMANTIC_MODELS_DIR=/app/semantic-models HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 PYTHONDONTWRITEBYTECODE=1
USER app
EXPOSE 4000
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 CMD ["/app/docker/healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/docker/start"]
