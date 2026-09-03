defmodule SymphonyElixir.AgentRuntime.PiAcp do
  @moduledoc """
  AgentRuntime backend driving pi through `@geohar/pi-acp` (ACP JSON-RPC 2.0
  over stdio; pi-acp spawns `pi --mode rpc` itself).

  Wire protocol (observed against pi-acp 0.3.1 / pi 0.84.4):

    * one JSON-RPC message per line (NDJSON)
    * `session/new` -> result `%{sessionId: ...}` (params need
      `mcpServers: []`)
    * `session/prompt` -> assistant output streams as `session/update`
      notifications whose `update.sessionUpdate` is `agent_message_chunk`
      (`content.text` holds token fragments); the prompt's own response
      (`%{result: %{stopReason: ...}}`) arrives when the turn ends.
    * text chunks accumulate and flush as `:message` updates at turn end —
      one journaled line per turn, matching transcript granularity.

  The first chunk may be pi-acp's "startup info" banner (pi version +
  prompts); it is dropped. `quietStartup: true` in the runtime's pi-acp
  settings suppresses it at the source.

  `command` (default from `pi.command` config, "pi-acp") must be on PATH in
  the runtime and cwd is the issue workspace, so pi's read/bash/edit/write
  operate on the workspace checkout.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.AgentRuntime.ChildEnv

  @behaviour SymphonyElixir.AgentRuntime

  @session_new_id 1
  @prompt_id 2
  @banner ~r/^pi v\d+\.\d+[\s\S]*---/

  defstruct [:port, :session_id, :workspace, :buffer, :banner_seen, :timeout_ms]

  @type t :: %__MODULE__{
          port: port(),
          session_id: String.t(),
          workspace: Path.t(),
          buffer: [String.t()],
          banner_seen: boolean(),
          timeout_ms: pos_integer()
        }

  @impl true
  def start_session(workspace, opts) do
    command = Keyword.get(opts, :command) || Config.settings!().pi.command
    timeout_ms = Keyword.get(opts, :timeout_ms) || Config.settings!().pi.turn_timeout_ms

    with {:ok, exe} <- find_executable(command),
         {:ok, port} <- spawn_port(exe, workspace),
         :ok <- request_session_new(port, workspace),
         {:ok, session_id} <- await_session_new(port, timeout_ms) do
      {:ok,
       %__MODULE__{
         port: port,
         session_id: session_id,
         workspace: workspace,
         buffer: [],
         banner_seen: false,
         timeout_ms: timeout_ms
       }}
    else
      {:error, reason} ->
        Logger.error("pi-acp start_session failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def run_turn(%__MODULE__{} = session, prompt, _issue, opts) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    emit(session, on_message, :session_started, %{session_id: session.session_id})

    send_json(session.port, %{
      "jsonrpc" => "2.0",
      "id" => @prompt_id,
      "method" => "session/prompt",
      "params" => %{
        "sessionId" => session.session_id,
        "prompt" => [%{"type" => "text", "text" => prompt}],
        "requestId" => "turn-#{System.unique_integer([:positive])}"
      }
    })

    case await_turn(session, on_message, session.timeout_ms) do
      {:ok, stop_reason} ->
        Logger.info("pi-acp turn completed session_id=#{session.session_id} stop_reason=#{stop_reason}")
        {:ok, %{session_id: session.session_id, stop_reason: stop_reason}}

      {:error, reason} ->
        Logger.warning("pi-acp turn failed session_id=#{session.session_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def stop_session(%__MODULE__{port: port, session_id: session_id}) do
    # fire-and-forget close; then reap the port
    send_json(port, %{
      "jsonrpc" => "2.0",
      "id" => 99,
      "method" => "session/close",
      "params" => %{"sessionId" => session_id}
    })

    Port.close(port)
    :ok
  end

  # -- port plumbing ----------------------------------------------------------

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> {:error, {:pi_acp_not_found, command}}
      exe -> {:ok, exe}
    end
  end

  defp spawn_port(exe, workspace) do
    pi = Config.settings!().pi

    {command, args} =
      if pi.child_env_isolation do
        # Fail-closed child environment via `env -i`: OTP's spawn `:env`
        # option MERGES over the inherited environment (child = inherited
        # ∪ overrides), so a credential variable in the orchestrator's own
        # environment would still reach the agent. `env -i` gives the child
        # exactly the scoped variables and nothing else — clean-room by
        # construction; env(1) execs the command, so the port keeps the
        # agent's pid and exit status. Disabled only by explicit
        # pi.child_env_isolation=false configuration.
        env_bin = System.find_executable("env") || "/usr/bin/env"

        scoped = ChildEnv.scoped_env(extra_allow: pi.child_env_allow)
        assignments = Enum.map(scoped, fn {name, value} -> "#{name}=#{value}" end)

        {env_bin, ["-i" | assignments] ++ [exe]}
      else
        {exe, []}
      end

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: args,
        cd: workspace
      ])

    {:ok, port}
  catch
    :exit, reason -> {:error, {:spawn_failed, reason}}
  end

  defp send_json(port, payload) when is_port(port) do
    Port.command(port, [Jason.encode!(payload), "\n"])
    :ok
  end

  defp request_session_new(port, workspace) do
    send_json(port, %{
      "jsonrpc" => "2.0",
      "id" => @session_new_id,
      "method" => "session/new",
      "params" => %{
        "protocolVersion" => "1.3",
        "cwd" => workspace,
        "mcpServers" => [],
        "sessionCapabilities" => %{"prompt" => true}
      }
    })

    :ok
  end

  # -- protocol ---------------------------------------------------------------

  defp await_session_new(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_session_new(port, deadline, "")
  end

  defp await_session_new(port, deadline, pending) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :session_new_timeout}
    else
      receive do
        {^port, {:data, data}} ->
          case handle_lines(pending <> data, %{}) do
            {:ok, lines_processed, leftover} ->
              case find_session_id(lines_processed) do
                {:ok, session_id} -> {:ok, session_id}
                {:error, reason} -> {:error, reason}
                :not_found -> await_session_new(port, deadline, leftover)
              end
          end

        {^port, {:exit_status, code}} ->
          {:error, {:pi_acp_exited, code}}
      after
        remaining -> {:error, :session_new_timeout}
      end
    end
  end

  defp find_session_id(lines) do
    Enum.find_value(lines, :not_found, fn
      %{"id" => @session_new_id, "result" => %{"sessionId" => sid}} -> {:ok, sid}
      %{"id" => @session_new_id, "error" => err} -> {:error, {:session_new_error, err}}
      _ -> nil
    end)
  end

  defp await_turn(session, on_message, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_turn(session, on_message, deadline, "")
  end

  defp await_turn(session, on_message, deadline, pending) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flush_text(session, on_message)
      {:error, :turn_timeout}
    else
      receive do
        {port, {:data, data}} when port == session.port ->
          case handle_lines(pending <> data, %{}) do
            {:ok, lines, leftover} ->
              case consume_turn_lines(session, on_message, lines) do
                {:ok, stop_reason} ->
                  {:ok, stop_reason}

                {:error, reason} ->
                  {:error, reason}

                {:continue, updated_session} ->
                  await_turn(updated_session, on_message, deadline, leftover)
              end
          end

        {port, {:exit_status, code}} when port == session.port ->
          flush_text(session, on_message)
          {:error, {:pi_acp_exited, code}}
      after
        remaining ->
          flush_text(session, on_message)
          {:error, :turn_timeout}
      end
    end
  end

  # Returns {:ok, stop_reason} | {:error, reason} when the prompt response
  # arrived, else {:continue, updated_session} with buffer state threaded.
  defp consume_turn_lines(session, on_message, lines) do
    Enum.reduce_while(lines, {:continue, session}, fn line, acc ->
      case acc do
        {:continue, session} ->
          case line do
            %{"method" => "session/update", "params" => %{"update" => update}} ->
              {:cont, {:continue, handle_update(session, on_message, update)}}

            %{"id" => @prompt_id, "result" => %{"stopReason" => reason}} ->
              updated = flush_text(session, on_message)

              emit(updated, on_message, :turn_completed, %{
                session_id: updated.session_id,
                stop_reason: reason
              })

              {:halt, {:ok, reason}}

            %{"id" => @prompt_id, "error" => error} ->
              flush_text(session, on_message)
              {:halt, {:error, {:prompt_error, error}}}

            _ ->
              {:cont, {:continue, session}}
          end

        _ ->
          {:halt, acc}
      end
    end)
  end

  defp handle_update(session, on_message, update) do
    case update do
      %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}} ->
        if banner?(session, text) do
          %{session | banner_seen: true}
        else
          %{session | buffer: [session.buffer, text]}
        end

      %{"sessionUpdate" => "tool_call"} ->
        # A tool is starting: the pi is working but will stream nothing
        # until the tool finishes (or its next message) — surface the
        # activity so the orchestrator's stall watchdog sees liveness
        # through the tool phase instead of killing a working run. The
        # text buffer is flushed first so the transcript stays ordered.
        updated = flush_text(session, on_message)
        emit(updated, on_message, :tool_call, %{session_id: updated.session_id})
        updated

      %{"sessionUpdate" => "agent_message"} ->
        # The pi's commentary after a tool result: same liveness role.
        # tool_call_update streams argument fragments per token and is
        # deliberately ignored — it would flood the journal.
        updated = flush_text(session, on_message)
        emit(updated, on_message, :agent_message, %{session_id: updated.session_id})
        updated

      _ ->
        session
    end
  end

  defp banner?(%{banner_seen: false}, text) when is_binary(text) do
    Regex.match?(@banner, String.trim(text))
  end

  defp banner?(_session, _text), do: false

  defp flush_text(session, on_message) do
    text = IO.iodata_to_binary(session.buffer) |> String.trim()

    if text != "" do
      emit(session, on_message, :message, %{
        "type" => "text",
        "text" => text
      })
    end

    %{session | buffer: []}
  end

  defp emit(session, on_message, event, payload) do
    on_message.(%{
      event: event,
      timestamp: DateTime.utc_now(),
      session_id: session.session_id,
      payload: payload
    })
  end

  defp default_on_message(_update), do: :ok

  # -- NDJSON line splitting ---------------------------------------------------

  # Returns {:ok, decoded_lines, leftover_partial} — feed data + leftover in.
  defp handle_lines(data, _state) do
    split = :binary.split(data, "\n", [:global])
    {complete, [last]} = Enum.split(split, -1)
    decoded = Enum.map(complete, &decode_line/1) |> Enum.reject(&is_nil/1)
    {:ok, decoded, last}
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end
end
