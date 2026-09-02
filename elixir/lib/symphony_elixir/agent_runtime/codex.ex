defmodule SymphonyElixir.AgentRuntime.Codex do
  @moduledoc """
  AgentRuntime backend for the reference codex app-server runner.

  Thin pass-through to `SymphonyElixir.Codex.AppServer` — the codex path is
  unchanged, it just lives behind the `AgentRuntime` seam now.
  """

  alias SymphonyElixir.Codex.AppServer

  @behaviour SymphonyElixir.AgentRuntime

  @impl true
  def start_session(workspace, opts), do: AppServer.start_session(workspace, opts)

  @impl true
  def run_turn(session, prompt, issue, opts),
    do: AppServer.run_turn(session, prompt, issue, opts)

  @impl true
  def stop_session(session), do: AppServer.stop_session(session)
end
