defmodule SymphonyElixir.RunJournal do
  @moduledoc """
  Durable per-issue run journal and agent-session transcript capture.

  The orchestrator keeps live run state in memory; this module is the on-disk
  history that survives restarts and powers the runs API and dashboard.

  Layout under the journal root (default `<workflow-dir>/symphony-runs`, see
  `observability.run_journal_root`):

      <root>/<issue_key>/runs.jsonl                  lifecycle events, one JSON per line
      <root>/<issue_key>/attempt-<N>/transcript.jsonl  agent-session events for run N

  `issue_key` uses the same sanitizer as workspaces (`Workspace.workspace_key/1`).
  `N` is the 1-based run index (`retry_attempt + 1`).

  Every write is best-effort: journal failures are logged and never break
  orchestration. Events are written with string keys so JSON round-trips are
  lossless for readers.
  """

  require Logger

  alias SymphonyElixir.{Config, Workspace}

  @type event :: map()

  @run_log "runs.jsonl"
  @transcript_log "transcript.jsonl"
  @max_payload_bytes 250_000

  # ── Root resolution ──────────────────────────────────────────────────────

  @doc "Whether journaling is enabled (`observability.run_journal_enabled`)."
  @spec enabled?() :: boolean()
  def enabled? do
    case Config.settings() do
      {:ok, settings} -> settings.observability.run_journal_enabled
      _ -> false
    end
  end

  @doc "Configured journal root (falls back to `<workflow-dir>/symphony-runs`)."
  @spec root() :: Path.t()
  def root do
    root(Config.settings!().observability.run_journal_root)
  end

  @doc "Resolve a configured journal root; `nil` yields the default location."
  @spec root(nil | String.t()) :: Path.t()
  def root(nil) do
    workspace_root = Config.local_workspace_root()
    Path.join(Path.dirname(workspace_root), "symphony-runs")
  end

  def root(configured_root) when is_binary(configured_root) do
    workflow_dir = SymphonyElixir.Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()
    Path.expand(configured_root, workflow_dir)
  end

  # ── Paths ────────────────────────────────────────────────────────────────

  @doc "Directory holding all journal data for an issue."
  @spec issue_dir(Path.t(), String.t()) :: Path.t()
  def issue_dir(root, issue_identifier) do
    Path.join(root, Workspace.workspace_key(issue_identifier))
  end

  @doc "Directory holding transcript data for one run attempt."
  @spec run_dir(Path.t(), String.t(), pos_integer()) :: Path.t()
  def run_dir(root, issue_identifier, run_index) when is_integer(run_index) and run_index > 0 do
    Path.join([issue_dir(root, issue_identifier), "attempt-#{run_index}"])
  end

  @doc "Path to the lifecycle log for an issue."
  @spec runs_file(Path.t(), String.t()) :: Path.t()
  def runs_file(root, issue_identifier), do: Path.join(issue_dir(root, issue_identifier), @run_log)

  @doc "Path to the transcript log for one run attempt."
  @spec transcript_file(Path.t(), String.t(), pos_integer()) :: Path.t()
  def transcript_file(root, issue_identifier, run_index) do
    Path.join(run_dir(root, issue_identifier, run_index), @transcript_log)
  end

  # ── Lifecycle records ────────────────────────────────────────────────────

  @doc """
  Append a lifecycle event for an issue.

  `event` is a map; `event_type` is stored as the `"event"` key and the current
  UTC timestamp as `"at"` (ISO-8601). Returns `:ok`.
  """
  @spec record(Path.t(), String.t(), String.t(), map()) :: :ok
  def record(root, issue_identifier, event_type, event) when is_binary(issue_identifier) do
    line =
      event
      |> Map.put("event", event_type)
      |> Map.put("at", iso8601_now())
      |> Map.put("identifier", issue_identifier)

    append_line(runs_file(root, issue_identifier), line)
  end

  @doc "Append an agent-session event to the transcript of a specific run."
  @spec append_transcript(Path.t(), String.t(), pos_integer(), map()) :: :ok
  def append_transcript(root, issue_identifier, run_index, event)
      when is_binary(issue_identifier) and is_integer(run_index) and run_index > 0 do
    line =
      event
      |> Map.put("at", iso8601_now())

    append_line(transcript_file(root, issue_identifier, run_index), line)
  end

  # ── Reads ────────────────────────────────────────────────────────────────

  @doc "Decoded lifecycle events for an issue, oldest first."
  @spec issue_events(Path.t(), String.t()) :: [event()]
  def issue_events(root, issue_identifier) do
    read_lines(runs_file(root, issue_identifier))
  end

  @doc "Decoded transcript events for a run, oldest first; `tail` limits to the last N."
  @spec transcript_events(Path.t(), String.t(), pos_integer(), nil | pos_integer()) :: [event()]
  def transcript_events(root, issue_identifier, run_index, tail \\ nil) do
    lines = read_lines(transcript_file(root, issue_identifier, run_index))

    case tail do
      n when is_integer(n) and n > 0 -> Enum.take(lines, -n)
      _ -> lines
    end
  end

  @doc """
  Summary of every journaled issue: identifier, run count, latest event and
  timestamp, derived status (see `status_from_event/1`).
  """
  @spec all_issues(Path.t()) :: [map()]
  def all_issues(root) do
    root
    |> list_issue_identifiers()
    |> Enum.map(fn identifier ->
      events = issue_events(root, identifier)
      latest = List.last(events)
      display_identifier = journal_identifier(events) || identifier

      %{
        issue_identifier: display_identifier,
        run_count: count_runs(events),
        event_count: length(events),
        status: latest && status_from_event(latest),
        last_event: latest && latest["event"],
        last_at: latest && latest["at"]
      }
    end)
    |> Enum.sort_by(fn issue -> issue.last_at || "0000-01-01T00:00:00.000Z" end)
    |> Enum.reverse()
  rescue
    _ -> []
  end

  @doc "Derive a coarse status from the most recent lifecycle event."
  @spec status_from_event(event()) :: String.t()
  def status_from_event(%{"event" => "issue_terminal"}), do: "done"
  def status_from_event(%{"event" => "run_finished", "status" => "blocked"}), do: "blocked"
  def status_from_event(%{"event" => "run_finished", "status" => "failed"}), do: "failed"
  def status_from_event(%{"event" => "run_finished"}), do: "completed"
  def status_from_event(%{"event" => "run_started"}), do: "running"
  def status_from_event(%{"event" => event}) when is_binary(event), do: event
  def status_from_event(_), do: "unknown"

  # ── Internals ────────────────────────────────────────────────────────────

  defp count_runs(events) do
    events
    |> Enum.count(&(&1["event"] == "run_started"))
  end

  defp journal_identifier(events) do
    Enum.find_value(events, fn event ->
      case event do
        %{"identifier" => identifier} when is_binary(identifier) and identifier != "" -> identifier
        _ -> nil
      end
    end)
  end

  defp append_line(path, line) do
    if File.mkdir_p(Path.dirname(path)) do
      payload =
        line
        |> trim_payload_fields()
        |> Jason.encode!()

      case File.open(path, [:append, :utf8]) do
        {:ok, io} ->
          result = IO.binwrite(io, payload <> "\n")
          File.close(io)
          result

        {:error, reason} ->
          Logger.warning("RunJournal append failed for #{path}: #{inspect(reason)}")
          :ok
      end
    else
      Logger.warning("RunJournal mkdir_p failed for #{path}")
      :ok
    end
  rescue
    error ->
      Logger.warning("RunJournal append error for #{path}: #{inspect(error)}")
      :ok
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case Jason.decode(line) do
            {:ok, event} -> event
            _ -> %{"event" => "undecodable", "line" => line}
          end
        end)

      {:error, _reason} ->
        []
    end
  rescue
    _ -> []
  end

  defp list_issue_identifiers(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          entry != ".git" and not String.starts_with?(entry, ".")
        end)
        |> Enum.filter(fn entry ->
          # Only directories that actually hold a journal (ignore stray files).
          File.dir?(Path.join(root, entry))
        end)

      _ ->
        []
    end
  end

  # Guard journal size: truncate oversized message payloads before encoding.
  defp trim_payload_fields(line) do
    case Map.fetch(line, "message") do
      {:ok, message} when is_binary(message) and byte_size(message) > @max_payload_bytes ->
        Map.put(
          line,
          "message",
          String.slice(message, 0, @max_payload_bytes) <>
            "\n...[truncated by RunJournal, #{byte_size(message) - @max_payload_bytes} bytes dropped]"
        )

      _ ->
        line
    end
  end

  defp iso8601_now do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
