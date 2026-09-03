defmodule SymphonyElixir.AgentRuntime.SessionPark do
  @moduledoc """
  One parked agent session per issue thread.

  An agent session is an OS port owned by whatever process opened it, so a
  session cannot outlive the `AgentRunner` task that normally runs a turn.
  `SessionPark` is a dedicated long-lived process per issue that owns the
  session port and executes turns on demand, staying alive between
  dispatches: the human sends the next prompt in the same thread, the
  orchestrator dispatches again, and `AgentRunner` resumes the *same*
  agent session — full conversation, no context loss (the
  github-automation "one dumb runner, session continues" pattern).

  Protocol (plain messages, one consumer):

    * `{:run_turn, from, prompt, issue, on_message}` — run one prompt turn
      on the owned session, streaming updates through `on_message`, and
      reply `{:turn_result, result}`.
    * `{:stop_session, from}` — close the agent session, reply `:stopped`,
      and exit.
    * `{:DOWN, _, :process, registry_pid, _}` — the SessionRegistry died;
      close the session and exit.

  The park is created by `SessionRegistry` (which blocks for readiness) and
  monitored by it; the park monitors the registry back so an orphaned park
  cannot leak an agent process. If the park itself crashes mid-turn the
  port dies with it; the registry removes the mapping and the next
  dispatch starts a fresh session.
  """

  require Logger

  alias SymphonyElixir.AgentRuntime

  @doc false
  # Spawns the park process; it starts the agent session synchronously and
  # reports readiness to `owner_pid` (the SessionRegistry), which blocks
  # for it.
  def start(issue_id, workspace, owner_pid) when is_pid(owner_pid) do
    {:ok, spawn(fn -> park_main(issue_id, workspace, owner_pid) end)}
  end

  @doc "Run one turn on a parked session. Blocks until the turn resolves."
  @spec run_turn(pid(), String.t(), SymphonyElixir.Tracker.Issue.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_turn(park_pid, prompt, issue, opts) when is_pid(park_pid) and is_binary(prompt) do
    ref = Process.monitor(park_pid)
    on_message = Keyword.get(opts, :on_message)

    send(park_pid, {:run_turn, self(), prompt, issue, on_message})

    receive do
      {:turn_result, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^park_pid, reason} ->
        {:error, {:session_park_down, reason}}
    end
  end

  @doc "Close the parked session (used by the registry on terminal threads)."
  @spec stop(pid()) :: :ok
  def stop(park_pid) when is_pid(park_pid) do
    send(park_pid, {:stop_session, self()})
    :ok
  end

  @doc "Hard-stop a parked session: kill the process so an in-flight turn aborts and the port closes."
  @spec kill(pid()) :: :ok
  def kill(park_pid) when is_pid(park_pid) do
    Process.exit(park_pid, :kill)
    :ok
  end

  defp park_main(_issue_id, workspace, owner_pid) do
    # the creating registry owns this park's lifecycle: if it dies, close
    # the session so no pi process leaks
    Process.monitor(owner_pid)

    case AgentRuntime.impl().start_session(workspace, []) do
      {:ok, session} ->
        send(owner_pid, {:park_ready, self(), {:ok, session}})
        loop(session)

      {:error, reason} ->
        send(owner_pid, {:park_ready, self(), {:error, reason}})
    end
  end

  defp loop(session) do
    receive do
      {:run_turn, from, prompt, issue, on_message} ->
        opts = if is_function(on_message, 1), do: [on_message: on_message], else: []

        result =
          case AgentRuntime.impl().run_turn(session, prompt, issue, opts) do
            {:ok, %{} = turn} -> {:ok, turn}
            {:error, reason} -> {:error, reason}
            other -> {:error, {:unexpected_turn_result, other}}
          end

        send(from, {:turn_result, result})
        loop(session)

      {:stop_session, from} ->
        AgentRuntime.impl().stop_session(session)
        send(from, :stopped)

      {:DOWN, _ref, :process, _registry_pid, _reason} ->
        AgentRuntime.impl().stop_session(session)
    end
  end
end
