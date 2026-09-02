defmodule SymphonyElixir.Tracker.RedkaTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Intents.IntentStore
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.Redka

  setup do
    :ets.delete_all_objects(:symphony_intents)
    :ok
  end

  describe "fetch_issues_by_states/1" do
    test "maps open intents to dispatchable issues" do
      {:ok, intent} =
        IntentStore.create_intent(%{
          "title" => "Ship the thing",
          "description" => "Do the work",
          "repo" => "milady/project",
          "labels" => ["symphony-pilot"]
        })

      {:ok, [issue]} = Redka.fetch_issues_by_states(["open"])

      assert %Issue{} = issue
      assert issue.id == intent.id
      assert issue.identifier == intent.id
      assert issue.title == "Ship the thing"
      assert issue.description == "Do the work"
      assert issue.state == "open"
      assert issue.labels == ["symphony-pilot"]
      assert issue.dispatchable
      assert issue.url == nil
    end

    test "excludes terminal intents" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "done job"})
      {:ok, _} = IntentStore.set_terminal_state(intent.id, "done", %{"status" => "completed"})

      assert {:ok, []} = Redka.fetch_issues_by_states(["open"])
      assert {:ok, [%Issue{state: "done"}]} = Redka.fetch_issues_by_states(["done"])
    end
  end

  describe "fetch_issues_by_ids/1" do
    test "returns issues by id regardless of state" do
      {:ok, open} = IntentStore.create_intent(%{"title" => "open"})
      {:ok, done} = IntentStore.create_intent(%{"title" => "done"})
      {:ok, _} = IntentStore.set_terminal_state(done.id, "done", %{"status" => "completed"})

      assert {:ok, issues} = Redka.fetch_issues_by_ids([open.id, done.id])
      assert length(issues) == 2
      assert Enum.map(issues, & &1.state) |> Enum.sort() == ["done", "open"]
    end

    test "missing ids are skipped" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "present"})
      assert {:ok, [%Issue{id: id}]} = Redka.fetch_issues_by_ids([intent.id, "int-missing"])
      assert id == intent.id
    end
  end

  describe "notify_run_finished/3" do
    test "completed parks the thread in awaiting (ask satisfied, human turn)" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})

      assert :ok = Redka.notify_run_finished(intent.id, "completed", %{})

      assert {:ok, %{state: "awaiting", result: result}} = IntentStore.get_intent(intent.id)
      assert result["status"] == "completed"
      assert is_binary(result["at"])
    end

    test "completed closes an internal verification pass to done" do
      {:ok, intent} =
        IntentStore.create_intent(%{
          "title" => "job",
          "verify_for" => "int-original-abc123",
          "labels" => ["verify"]
        })

      assert :ok = Redka.notify_run_finished(intent.id, "completed", %{})

      assert {:ok, %{state: "done"}} = IntentStore.get_intent(intent.id)
    end

    test "an awaiting thread re-opens with the next prompt" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})
      :ok = Redka.notify_run_finished(intent.id, "completed", %{})

      {:ok, %{state: "open"}} =
        IntentStore.assign_and_activate_intent(intent.id, %{description: "next prompt"})

      assert {:ok, %{description: "next prompt"}} = IntentStore.get_intent(intent.id)
    end

    test "failed closes the intent as failed with error" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})

      assert :ok = Redka.notify_run_finished(intent.id, "failed", %{"error" => "agent exited"})

      assert {:ok, %{state: "failed", result: %{"error" => "agent exited"}}} =
               IntentStore.get_intent(intent.id)
    end

    test "blocked closes the intent as failed" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})
      assert :ok = Redka.notify_run_finished(intent.id, "blocked", %{"error" => "needs input"})
      assert {:ok, %{state: "failed"}} = IntentStore.get_intent(intent.id)
    end

    test "unknown outcomes and ids are ignored" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})
      assert :ok = Redka.notify_run_finished(intent.id, "some_unknown_status", %{})
      assert {:ok, %{state: "open"}} = IntentStore.get_intent(intent.id)
      assert :ok = Redka.notify_run_finished("int-missing", "completed", %{})
    end

    test "terminal intents are left untouched" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})
      {:ok, _} = IntentStore.set_terminal_state(intent.id, "cancelled", %{"reason" => "user"})

      assert :ok = Redka.notify_run_finished(intent.id, "completed", %{})
      assert {:ok, %{state: "cancelled"}} = IntentStore.get_intent(intent.id)
    end
  end
end
