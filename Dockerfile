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

FROM ${PYTHON_IMAGE} AS runner
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 libncurses6 libgomp1 openssl ca-certificates tini curl bash && rm -rf /var/lib/apt/lists/* && useradd --uid 10001 --create-home app
WORKDIR /app
COPY --from=builder --chown=app:app /app/_build/prod/rel/ai_control ./
COPY --from=ner-builder /opt/ner /opt/ner
COPY --from=ner-builder /models /app/models
COPY --chown=app:app sidecar/ner /app/ner
COPY --chmod=755 docker/start docker/healthcheck /app/docker/
ENV LANG=C.UTF-8 PHX_SERVER=true PORT=4000 NER_BASE_URL=http://127.0.0.1:8001 STANZA_RESOURCES_DIR=/app/models PYTHONDONTWRITEBYTECODE=1
USER app
EXPOSE 4000
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 CMD ["/app/docker/healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/docker/start"]
