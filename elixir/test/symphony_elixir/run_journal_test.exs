defmodule SymphonyElixir.RunJournalTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{RunJournal, Workflow}

  defp tmp_root do
    Path.join(
      System.tmp_dir!(),
      "symphony-run-journal-#{System.unique_integer([:positive])}"
    )
  end

  test "records lifecycle events and replays them oldest-first" do
    root = tmp_root()

    try do
      :ok = RunJournal.record(root, "MT/Det-1", "run_started", %{"run_index" => 1, "attempt" => 0})
      :ok = RunJournal.record(root, "MT/Det-1", "run_finished", %{"run_index" => 1, "status" => "completed"})
      :ok = RunJournal.record(root, "MT/Det-1", "run_started", %{"run_index" => 2, "attempt" => 1})

      events = RunJournal.issue_events(root, "MT/Det-1")

      assert length(events) == 3
      assert Enum.map(events, & &1["event"]) == ["run_started", "run_finished", "run_started"]
      assert Enum.map(events, & &1["run_index"]) == [1, 1, 2]
      assert Enum.all?(events, &is_binary(&1["at"]))

      # Unknown issue reads back empty.
      assert RunJournal.issue_events(root, "NOPE-9") == []
    after
      File.rm_rf(root)
    end
  end

  test "appends transcripts per run and supports tail reads" do
    root = tmp_root()

    try do
      :ok = RunJournal.append_transcript(root, "S-1", 1, %{"event" => "notification", "message" => "one"})
      :ok = RunJournal.append_transcript(root, "S-1", 1, %{"event" => "notification", "message" => "two"})
      :ok = RunJournal.append_transcript(root, "S-1", 2, %{"event" => "session_started", "session_id" => "t-9"})

      assert length(RunJournal.transcript_events(root, "S-1", 1)) == 2
      assert [%{"message" => "two"}] = RunJournal.transcript_events(root, "S-1", 1, 1)
      assert [%{"session_id" => "t-9"}] = RunJournal.transcript_events(root, "S-1", 2)

      # Transcripts live in per-run attempt dirs.
      file = RunJournal.transcript_file(root, "S-1", 1)
      assert String.ends_with?(file, "attempt-1/transcript.jsonl")
    after
      File.rm_rf(root)
    end
  end

  test "summarizes journaled issues with derived status" do
    root = tmp_root()

    try do
      :ok = RunJournal.record(root, "A-1", "run_started", %{"run_index" => 1})
      :ok = RunJournal.record(root, "A-1", "run_finished", %{"run_index" => 1, "status" => "failed"})
      :ok = RunJournal.record(root, "A-1", "run_started", %{"run_index" => 2})
      :ok = RunJournal.record(root, "B-2", "run_started", %{"run_index" => 1})

      issues = RunJournal.all_issues(root)

      assert length(issues) == 2

      by_id = Map.new(issues, &{&1.issue_identifier, &1})

      assert by_id["A-1"].status == "running"
      assert by_id["A-1"].run_count == 2
      assert by_id["B-2"].status == "running"
      assert by_id["B-2"].run_count == 1
    after
      File.rm_rf(root)
    end
  end

  test "truncates oversized transcript payloads" do
    root = tmp_root()

    try do
      huge = String.duplicate("x", 300_000)

      :ok =
        RunJournal.append_transcript(root, "S-1", 1, %{
          "event" => "notification",
          "message" => huge
        })

      [%{"message" => stored}] = RunJournal.transcript_events(root, "S-1", 1)
      assert byte_size(stored) < byte_size(huge)
      assert String.contains?(stored, "truncated by RunJournal")
    after
      File.rm_rf(root)
    end
  end

  test "enabled? and root follow workflow observability config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-run-journal-config-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      journal_root = Path.join(test_root, "my-runs")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        observability_run_journal_enabled: true,
        observability_run_journal_root: journal_root
      )

      assert RunJournal.enabled?()
      assert RunJournal.root() == Path.expand(journal_root)
      assert File.exists?(Path.dirname(RunJournal.root())) == false

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        observability_run_journal_enabled: false
      )

      refute RunJournal.enabled?()
    after
      File.rm_rf(test_root)
    end
  end

  test "status derives from last lifecycle event when fabric events follow run_finished" do
    root = tmp_root()

    try do
      :ok = RunJournal.record(root, "A-1", "run_started", %{"run_index" => 1})
      :ok = RunJournal.record(root, "A-1", "run_finished", %{"run_index" => 1, "status" => "completed"})
      :ok = RunJournal.record(root, "A-1", "delta_emitted", %{"repo" => "r"})
      :ok = RunJournal.record(root, "A-1", "build_succeeded", %{"repo" => "r"})

      [issue] = RunJournal.all_issues(root)

      assert issue.status == "completed"
      assert issue.last_event == "build_succeeded"
    after
      File.rm_rf(root)
    end
  end

  test "fabric-only journal falls back to last event for status" do
    root = tmp_root()

    try do
      :ok = RunJournal.record(root, "B-2", "delta_emitted", %{"repo" => "r"})
      :ok = RunJournal.record(root, "B-2", "job_started", %{"repo" => "r", "job_id" => "j-1"})

      [issue] = RunJournal.all_issues(root)

      assert issue.status == "job_started"
      assert issue.last_event == "job_started"
    after
      File.rm_rf(root)
    end
  end

  test "unfinished run keeps running status despite fabric events" do
    root = tmp_root()

    try do
      :ok = RunJournal.record(root, "C-3", "run_started", %{"run_index" => 1})
      :ok = RunJournal.record(root, "C-3", "delta_emitted", %{"repo" => "r"})

      [issue] = RunJournal.all_issues(root)

      assert issue.status == "running"
      assert issue.last_event == "delta_emitted"
    after
      File.rm_rf(root)
    end
  end
end
