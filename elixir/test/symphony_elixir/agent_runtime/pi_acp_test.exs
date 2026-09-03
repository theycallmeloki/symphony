defmodule SymphonyElixir.AgentRuntime.PiAcpTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.PiAcp

  @moduletag :tmp_dir

  # A stub pi-acp: speaks the observed ACP NDJSON surface (session/new ->
  # sessionId; session/prompt -> banner chunk + text chunks + end_turn
  # response) so the adapter is testable without pi installed.
  defp write_stub(tmp_dir) do
    script = Path.join(tmp_dir, "stub-pi-acp")
    File.write!(script, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *session/new*)
          echo '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"stub-session-1"}}'
          ;;
        *session/prompt*)
          echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"stub-session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"pi v0.99.9 --- startup banner, drop me"}}}}'
          echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"stub-session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello from"}}}}'
          echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"stub-session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":" the stub"}}}}'
          echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"stub-session-1","update":{"sessionUpdate":"tool_call"}}}'
          echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"stub-session-1","update":{"sessionUpdate":"agent_message"}}}'
          echo '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}'
          ;;
        *session/close*)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(script, 0o755)
    script
  end

  test "drives a pi-acp session: session_started, banner dropped, text flushed, turn_completed",
       %{tmp_dir: tmp_dir} do
    stub = write_stub(tmp_dir)
    workspace = Path.join(tmp_dir, "ws")
    File.mkdir_p!(workspace)

    {:ok, session} = PiAcp.start_session(workspace, command: stub, timeout_ms: 5_000)
    assert session.session_id == "stub-session-1"

    received =
      for turn <- 1..1 do
        {:ok, _} =
          PiAcp.run_turn(session, "do the thing", %{}, on_message: fn msg -> send(self(), {:upd, turn, msg}) end)

        collect(5)
      end
      |> List.flatten()

    assert Enum.map(received, & &1.event) ==
             [:session_started, :message, :tool_call, :agent_message, :turn_completed]

    text_update = Enum.find(received, &(&1.event == :message))
    assert text_update.payload["text"] == "hello from the stub"
    assert text_update.session_id == "stub-session-1"

    completed = Enum.find(received, &(&1.event == :turn_completed))
    assert completed.payload.stop_reason == "end_turn"

    assert :ok = PiAcp.stop_session(session)
  end

  test "tool activity is surfaced so the stall watchdog sees liveness",
       %{tmp_dir: tmp_dir} do
    stub = write_stub(tmp_dir)
    workspace = Path.join(tmp_dir, "ws")
    File.mkdir_p!(workspace)

    {:ok, session} = PiAcp.start_session(workspace, command: stub, timeout_ms: 5_000)

    {:ok, _} =
      PiAcp.run_turn(session, "do the thing", %{}, on_message: fn msg -> send(self(), {:upd, msg}) end)

    events = collect_updates(8)

    # the tool_call + agent_message sessionUpdates are surfaced as events
    # (mid-turn liveness for the orchestrator), text flushes before them
    assert Enum.any?(events, &(&1.event == :tool_call))
    assert Enum.any?(events, &(&1.event == :agent_message))
    assert Enum.any?(events, &(&1.event == :turn_completed))

    assert :ok = PiAcp.stop_session(session)
  end

  test "start_session fails fast when the command is missing" do
    assert {:error, {:pi_acp_not_found, "definitely-not-a-real-pi-acp"}} =
             PiAcp.start_session("/tmp", command: "definitely-not-a-real-pi-acp")
  end

  defp collect(0), do: []
  defp collect(n) do
    receive do
      {:upd, _, msg} -> [msg | collect(n - 1)]
    after
      5_000 -> []
    end
  end

  defp collect_updates(0), do: []
  defp collect_updates(n) do
    receive do
      {:upd, msg} -> [msg | collect_updates(n - 1)]
    after
      5_000 -> []
    end
  end
end
