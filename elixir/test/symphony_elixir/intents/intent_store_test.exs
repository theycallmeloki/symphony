defmodule SymphonyElixir.Intents.IntentStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Intents.Intent
  alias SymphonyElixir.Intents.IntentStore

  setup do
    :ets.delete_all_objects(:symphony_intents)
    :ok
  end

  describe "create_intent/1" do
    test "creates an open intent with normalized fields" do
      assert {:ok, intent} =
               IntentStore.create_intent(%{
                 "title" => "  Publish release notes  ",
                 "description" => "Write and publish v1.0 release notes",
                 "repo" => "milady/project",
                 "labels" => ["Symphony-Pilot", "symphony-pilot", "infra"]
               })

      assert intent.id =~ ~r/^int-/
      assert intent.state == "open"
      assert intent.title == "Publish release notes"
      assert intent.labels == ["symphony-pilot", "infra"]
      assert intent.repo == "milady/project"
      refute is_nil(intent.created_at)
      refute is_nil(intent.updated_at)
    end

    test "accepts atom keys" do
      assert {:ok, %Intent{title: "T"}} = IntentStore.create_intent(%{title: "T"})
    end

    test "rejects missing title" do
      assert {:error, {:missing_field, :title}} = IntentStore.create_intent(%{"description" => "no title"})
    end

    test "rejects invalid initial state" do
      assert {:error, {:invalid_state, "bogus"}} =
               IntentStore.create_intent(%{"title" => "T", "state" => "bogus"})
    end

    test "honors a client-supplied id" do
      assert {:ok, %Intent{id: "int-fixed"}} = IntentStore.create_intent(%{"title" => "T", "id" => "int-fixed"})
      assert {:ok, %Intent{id: "int-fixed"}} = IntentStore.get_intent("int-fixed")
    end
  end

  describe "list_intents/0 + list_intents_by_state/1" do
    test "lists intents newest first" do
      {:ok, first} = IntentStore.create_intent(%{"title" => "first"})
      Process.sleep(5)
      {:ok, second} = IntentStore.create_intent(%{"title" => "second"})

      assert {:ok, intents} = IntentStore.list_intents()
      assert Enum.map(intents, & &1.id) == [second.id, first.id]
    end

    test "filters by state (case-insensitive)" do
      {:ok, open} = IntentStore.create_intent(%{"title" => "open one"})
      {:ok, done} = IntentStore.create_intent(%{"title" => "done one"})
      :ok = terminal(done.id, "done")

      assert {:ok, [only_open]} = IntentStore.list_intents_by_state(["open"])
      assert only_open.id == open.id

      assert {:ok, [only_done]} = IntentStore.list_intents_by_state(["DONE"])
      assert only_done.id == done.id
    end
  end

  describe "set_terminal_state/3 + cancel_intent/1" do
    test "moves an open intent to done with a result" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})

      assert {:ok, updated} =
               IntentStore.set_terminal_state(intent.id, "done", %{"status" => "completed"})

      assert updated.state == "done"
      assert updated.result["status"] == "completed"

      assert {:ok, %Intent{state: "done"} = fetched} = IntentStore.get_intent(intent.id)
      assert fetched.result["status"] == "completed"
    end

    test "terminal states are final" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})
      {:ok, _} = IntentStore.set_terminal_state(intent.id, "failed", %{"status" => "failed"})

      assert {:error, :invalid_state} =
               IntentStore.set_terminal_state(intent.id, "done", %{"status" => "completed"})
    end

    test "cancel marks cancelled" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})
      assert {:ok, %Intent{state: "cancelled"}} = IntentStore.cancel_intent(intent.id)
    end

    test "unknown id returns not_found" do
      assert {:error, :not_found} = IntentStore.cancel_intent("int-missing")
    end

    test "a cancelled thread recovers to awaiting only via the explicit recovery transition" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})
      assert {:ok, %Intent{state: "cancelled"}} = IntentStore.cancel_intent(intent.id)

      # a run's own completion must NOT resurrect a cancel (notify_run_finished
      # keeps terminal intents untouched)
      assert {:error, :invalid_state} = IntentStore.complete_to_awaiting(intent.id)

      # the operator's explicit recovery (deploy of the parked workspace)
      # re-parks the thread so it continues its lifecycle
      assert {:ok, %Intent{state: "awaiting"}} =
               IntentStore.recover_cancelled_intent(intent.id, %{"status" => "recovered"})

      # and an awaiting thread can still be closed
      assert {:ok, %Intent{state: "done"}} = IntentStore.close_intent(intent.id)
    end
  end

  describe "queued intents + activate/assign" do
    test "creates intents in the queued state" do
      {:ok, intent} =
        IntentStore.create_intent(%{
          "title" => "Repo job: sandman",
          "repo" => "git@github.com:theycallmeloki/sandman.git",
          "state" => "queued",
          "labels" => ["repo-queue"]
        })

      assert intent.state == "queued"
      assert {:ok, [%Intent{id: id}]} = IntentStore.list_intents_by_state(["queued"])
      assert id == intent.id
    end

    test "activate moves queued to open" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job", "state" => "queued"})

      assert {:ok, %Intent{state: "open"}} = IntentStore.activate_intent(intent.id)
      assert {:ok, %Intent{state: "open"}} = IntentStore.get_intent(intent.id)
    end

    test "activate rejects non-queued intents" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})
      assert {:error, :invalid_state} = IntentStore.activate_intent(intent.id)
      assert {:ok, %Intent{state: "open"}} = IntentStore.get_intent(intent.id)
    end

    test "park moves open back to queued" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job"})
      assert {:ok, %Intent{state: "queued"}} = IntentStore.park_intent(intent.id)
    end

    test "assign updates the description while staying queued" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job", "state" => "queued"})

      assert {:ok, %Intent{state: "queued", description: "audit the README"}} =
               IntentStore.assign_intent(intent.id, %{description: "audit the README"})
    end

    test "assign_and_activate sets the task and dispatches" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job", "state" => "queued"})

      assert {:ok, %Intent{state: "open", description: "run the tests"}} =
               IntentStore.assign_and_activate_intent(intent.id, %{description: "run the tests"})
    end

    test "queued intents can still be cancelled" do
      {:ok, intent} = IntentStore.create_intent(%{"title" => "job", "state" => "queued"})
      assert {:ok, %Intent{state: "cancelled"}} = IntentStore.cancel_intent(intent.id)
    end
  end

  defp terminal(id, state) do
    {:ok, _} = IntentStore.set_terminal_state(id, state, %{"status" => state})
    :ok
  end
end
