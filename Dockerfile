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

FROM hexpm/erlang:28.1.1-debian-bookworm-20260824-slim
RUN apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null 2>&1 \
 && useradd -m -u 10001 symphony \
 && mkdir -p /app /data \
 && chown -R symphony /app /data
WORKDIR /app
COPY --from=build /build/elixir/bin/symphony /app/bin/symphony
USER symphony
EXPOSE 4000
ENTRYPOINT ["/app/bin/symphony"]
CMD ["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--port", "4000", "--logs-root", "/data/logs", "/app/workflow/WORKFLOW.md"]
