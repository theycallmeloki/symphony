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
RUN apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null 2>&1 \
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
USER symphony
ENV HOME=/home/symphony
EXPOSE 4000
ENTRYPOINT ["/app/bin/symphony"]
CMD ["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--port", "4000", "--logs-root", "/data/logs", "/app/workflow/WORKFLOW.md"]
