defmodule SymphonyElixir.AgentRuntime.SessionRegistry do
  @moduledoc """
  Owns the parked per-thread agent sessions.

  One `SessionPark` process per issue keeps the pi session (an OS port)
  alive between orchestrator dispatches so a thread's conversation
  survives across human prompts. The registry:

    * `acquire/2` — returns the live park for an issue, starting one (and
      its agent session) on first use. Blocking while the session boots.
    * `workspace/1` — the parked workspace path (needed by the deploy
      action to emit the thread's dirty tree).
    * `stop/1` — kills the park (aborting any in-flight turn) and drops
      the mapping; called when a thread reaches a terminal state
      (IntentStore hook) or is explicitly stopped.
    * monitors every park and auto-cleans on crash, so a dead pi process
      never leaves a stale mapping.

  Inert when the process is not running (unit tests without the supervisor
  tree): `acquire` returns `{:error, :not_running}` and callers fall back
  to inline sessions.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.AgentRuntime.SessionPark

  @session_start_timeout_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    # The registry is a node-wide singleton keyed by name; test trees that
    # boot extra AgentRuntimeSupervisors must not clash with the app tree's
    # registry, so a second registration is ignored (those trees do not
    # park sessions anyway — parking is opt-in per dispatch).
    case GenServer.start_link(__MODULE__, %{}, name: name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> :ignore
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the parked session for an issue thread, starting one on first
  use. `{:ok, pid, :new}` when a fresh session was started, `{:ok, pid,
  :resumed}` when an existing parked session is reused, `{:error, reason}`
  when the session could not start or no registry is running.
  """
  @spec acquire(String.t(), Path.t()) :: {:ok, pid(), :new | :resumed} | {:error, term()}
  def acquire(issue_id, workspace) when is_binary(issue_id) and is_binary(workspace) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:acquire, issue_id, workspace}, 40_000)
      _ -> {:error, :not_running}
    end
  end

  @doc "The parked workspace path for an issue, or nil when nothing is parked."
  @spec workspace(String.t()) :: String.t() | nil
  def workspace(issue_id) when is_binary(issue_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:workspace, issue_id})
      _ -> nil
    end
  end

  @doc "Parked-session info map for an issue, or nil."
  @spec info(String.t()) :: map() | nil
  def info(issue_id) when is_binary(issue_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:info, issue_id})
      _ -> nil
    end
  end

  @doc """
  Stops a thread's parked session (kills the park, aborting any in-flight
  turn) and drops the mapping. Safe to call for unknown issues.
  """
  @spec stop(String.t()) :: :ok
  def stop(issue_id) when is_binary(issue_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:stop, issue_id})
      _ -> :ok
    end
  end

  @doc "Number of parked sessions (observability)."
  @spec count() :: non_neg_integer()
  def count do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :count)
      _ -> 0
    end
  end

  # -- GenServer -----------------------------------------------------------

  @impl true
  def init(_state), do: {:ok, %{parks: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, issue_id, workspace}, _from, state) do
    case Map.get(state.parks, issue_id) do
      %{pid: pid} when is_pid(pid) ->
        {:reply, {:ok, pid, :resumed}, state}

      _ ->
        case start_park(state, issue_id, workspace) do
          {:ok, park, state} -> {:reply, {:ok, park.pid, :new}, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:workspace, issue_id}, _from, state) do
    {:reply, get_in(state.parks, [issue_id, :workspace]), state}
  end

  def handle_call({:info, issue_id}, _from, state) do
    case Map.get(state.parks, issue_id) do
      nil ->
        {:reply, nil, state}

      park ->
        {:reply,
         %{
           issue_id: issue_id,
           workspace: park.workspace,
           session_id: park.session_id,
           parked_at: park.parked_at
         }, state}
    end
  end

  def handle_call(:count, _from, state) do
    {:reply, map_size(state.parks), state}
  end

  @impl true
  def handle_cast({:stop, issue_id}, state) do
    {:noreply, drop_park(state, issue_id)}
  end

  @impl true
  def handle_info({:park_ready, pid, {:ok, _session}}, state) do
    # Normally consumed by start_park's blocking receive; this clause only
    # catches a ready that arrived after a timeout/drop race — the entry is
    # gone, so kill the stray park.
    if Enum.any?(state.parks, fn {_issue_id, park} -> park.pid == pid end) do
      {:noreply, state}
    else
      SessionPark.kill(pid)
      {:noreply, state}
    end
  end

  def handle_info({:park_ready, _pid, {:error, _reason}}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {issue_id, state} ->
        Logger.warning(
          "SessionRegistry park down issue_id=#{issue_id} reason=#{inspect(reason)}; next dispatch starts a fresh session"
        )

        state =
          if match?(%{pid: ^pid}, Map.get(state.parks, issue_id)) do
            %{state | parks: Map.delete(state.parks, issue_id)}
          else
            state
          end

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- internals -----------------------------------------------------------

  defp start_park(state, issue_id, workspace) do
    {:ok, pid} = SessionPark.start(issue_id, workspace, self())
    ref = Process.monitor(pid)

    state = %{
      state
      | parks: Map.put(state.parks, issue_id, %{
          pid: pid,
          workspace: workspace,
          session_id: nil,
          parked_at: DateTime.utc_now()
        }),
        monitors: Map.put(state.monitors, ref, issue_id)
    }

    receive do
      {:park_ready, ^pid, {:ok, session}} ->
        session_id = Map.get(session, :session_id)
        state = put_in(state, [:parks, issue_id, :session_id], session_id)
        park = Map.fetch!(state.parks, issue_id)
        {:ok, park, state}

      {:park_ready, ^pid, {:error, reason}} ->
        state = drop_park(state, issue_id)
        {:error, reason, state}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        state = drop_park(state, issue_id)
        {:error, {:session_park_start_failed, reason}, state}
    after
      @session_start_timeout_ms ->
        Process.demonitor(ref, [:flush])
        state = drop_park(state, issue_id)
        {:error, :session_start_timeout, state}
    end
  end

  defp drop_park(state, issue_id) do
    case Map.get(state.parks, issue_id) do
      nil ->
        state

      %{pid: pid} = park ->
        SessionPark.kill(pid)
        _ = park

        {refs, monitors} =
          Enum.split_with(state.monitors, fn {_ref, owner} -> owner == issue_id end)

        Enum.each(refs, fn {ref, _owner} -> Process.demonitor(ref, [:flush]) end)

        %{state | parks: Map.delete(state.parks, issue_id), monitors: monitors}
    end
  end
end
