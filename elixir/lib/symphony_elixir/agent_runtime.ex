defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Agent runtime seam behind the orchestrator's per-issue agent runs.

  `AgentRunner` needs three operations from whatever agent executes a work
  item — spawn a session bound to the issue workspace, run one prompt turn
  (streaming updates through an `on_message` callback), and stop the
  session. Today two backends implement the contract:

    * `SymphonyElixir.AgentRuntime.Codex` — the reference runner (codex
      app-server, JSON-RPC over stdio) — the default.
    * `SymphonyElixir.AgentRuntime.PiAcp` — pi driven through the
      `@geohar/pi-acp` ACP adapter (ACP JSON-RPC over stdio; pi-acp spawns
      `pi --mode rpc` under the hood).

  The active backend is selected by `agent.runtime` in the workflow config
  (`:codex` | `:pi_acp`). Update messages emitted through `on_message`
  follow the codex adapter's shape (`%{event: atom, payload: map,
  session_id: ...}`) so orchestrator journaling, the runs API and the
  dashboard are backend-agnostic.
  """

  alias SymphonyElixir.Config

  @type session :: term()
  @type update :: map()

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}
  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @doc "Active runtime module per agent.runtime config."
  @spec impl() :: module()
  def impl do
    case Config.settings!().agent.runtime do
      :pi_acp -> SymphonyElixir.AgentRuntime.PiAcp
      _ -> SymphonyElixir.AgentRuntime.Codex
    end
  end
end
