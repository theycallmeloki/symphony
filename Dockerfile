# Symphony — escript runtime image (erlang 28.1.1 / elixir 1.19.5)
FROM hexpm/elixir:1.19.5-erlang-28.1.1-debian-bookworm-20260824-slim AS build
RUN apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null 2>&1
WORKDIR /build
COPY elixir/ /build/elixir/
WORKDIR /build/elixir
RUN mix local.hex --force >/dev/null 2>&1 \
 && mix local.rebar --force >/dev/null 2>&1 \
 && mix deps.get --only prod >/dev/null 2>&1 \
 && MIX_ENV=prod mix compile >/dev/null 2>&1 \
 && MIX_ENV=prod mix escript.build 2>&1 | tail -1

FROM node:22-bookworm-slim AS pi-runtime
RUN npm install -g --no-audit --no-fund @earendil-works/pi-coding-agent @geohar/pi-acp

FROM hexpm/erlang:28.1.1-debian-bookworm-20260824-slim
RUN apt-get update -qq && apt-get install -y -qq git ca-certificates python3 python3-pip curl >/dev/null 2>&1 \
 && useradd -m -u 10001 symphony \
 && mkdir -p /app /data /home/symphony/.pi/agent/extensions /home/symphony/.pi/pi-acp \
 && chown -R symphony /app /data /home/symphony \
 && chmod 700 /home/symphony/.pi
WORKDIR /app
COPY --from=build /build/elixir/bin/symphony /app/bin/symphony
# pi agent runtime (node + pi + pi-acp); config lives at $HOME/.pi, injected
# as a k8s secret volume (never baked into the image)
COPY --from=pi-runtime /usr/local/bin /usr/local/bin
COPY --from=pi-runtime /usr/local/lib/node_modules /usr/local/lib/node_modules
# sandman CLI — the stable public interface this app's sandman client
# shells out to (RepoDelta delta/head, BuildFusion job query, TrackedRepos
# listings), instead of reaching into sandman's HTTP API. Pinned to the
# release the daemon fleet runs so the CLI and daemon evolve together;
# bump SANDMAN_VERSION to the fleet's release when sandman releases.
ARG SANDMAN_VERSION=v0.2.50
RUN set -e; \
    curl -fsSL -o /tmp/sandman-linux-amd64 "https://github.com/theycallmeloki/sandman/releases/download/v${SANDMAN_VERSION}/sandman-linux-amd64" && \
    curl -fsSL -o /tmp/sandman.sha256 "https://github.com/theycallmeloki/sandman/releases/download/v${SANDMAN_VERSION}/sandman-linux-amd64.sha256" && \
    (cd /tmp && sha256sum -c sandman.sha256) && \
    install -m 0755 /tmp/sandman-linux-amd64 /usr/local/bin/sandman && \
    rm -f /tmp/sandman-linux-amd64 /tmp/sandman.sha256 && \
    command -v sandman >/dev/null
USER symphony
ENV HOME=/home/symphony
EXPOSE 4000
ENTRYPOINT ["/app/bin/symphony"]
CMD ["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--port", "4000", "--logs-root", "/data/logs", "/app/workflow/WORKFLOW.md"]
