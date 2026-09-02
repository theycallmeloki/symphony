defmodule SymphonyElixir.Tracker.Redka do
  @moduledoc """
  Tracker adapter that exposes dashboard-registered intents as issues.

  Intents are read from `SymphonyElixir.Intents.IntentStore`. Each intent is
  dispatchable as an issue whose `id`/`identifier` is the intent id (so the
  workspace and journal derive from it). The adapter implements
  `notify_run_finished/3` to move an intent to a terminal state when the
  orchestrator closes its run — this is what lets intents operate as jobs:
  open intents get picked up, runs complete, and the intent lands in
  `done`/`failed` without the continuation retry churn of read-only trackers.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Intents.{Intent, IntentStore}
  alias SymphonyElixir.Tracker.Issue

  # failed/blocked land terminal. A normal completion lands `awaiting` —
  # the thread's ask is satisfied and the workspace is parked for the human
  # (deploy or next prompt) — except internal verification passes, which
  # are one-shot and close to `done`.
  @failed_outcomes %{"failed" => "failed", "blocked" => "failed"}

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    with {:ok, intents} <- IntentStore.list_intents_by_state(state_names) do
      {:ok, Enum.map(intents, &to_issue/1)}
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    {found, not_found} =
      issue_ids
      |> Enum.map(&IntentStore.get_intent/1)
      |> Enum.split_with(&match?({:ok, _}, &1))

    case Enum.find(not_found, &(&1 != {:error, :not_found})) do
      nil ->
        {:ok, Enum.map(found, fn {:ok, intent} -> to_issue(intent) end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Run-outcome transition for intent-backed issues.

  Maps orchestrator run outcomes to intent states: a normal completion
  parks the thread in `awaiting` (ask satisfied — deploy or next prompt),
  an internal verification pass closes to `done`, and `failed`/`blocked`
  go terminal as `failed`. Intents that were cancelled or already terminal
  are left untouched.
  """
  @spec notify_run_finished(String.t(), String.t(), map()) :: :ok
  def notify_run_finished(issue_id, status, details) when is_binary(issue_id) and is_binary(status) do
    result = %{
      "status" => status,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "error" => Map.get(details || %{}, "error")
    }

    case {status, IntentStore.get_intent(issue_id)} do
      {"completed", {:ok, %Intent{verify_for: verify_for}}}
      when is_binary(verify_for) ->
        # internal verification pass: one-shot, close it terminal
        set_terminal(issue_id, "done", result)

      {"completed", {:ok, _intent}} ->
        # normal completion: park the thread for the human
        case IntentStore.complete_to_awaiting(issue_id, result) do
          {:ok, _} -> :ok
          {:error, :not_found} -> :ok
          {:error, reason} -> warn(issue_id, status, reason)
        end

      {"completed", _} ->
        :ok

      {status, _} ->
        case Map.get(@failed_outcomes, status) do
          nil -> :ok
          intent_state -> set_terminal(issue_id, intent_state, result)
        end
    end

    :ok
  end

  defp set_terminal(issue_id, intent_state, result) do
    case IntentStore.set_terminal_state(issue_id, intent_state, result) do
      {:ok, _intent} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> warn(issue_id, intent_state, reason)
    end
  end

  defp warn(issue_id, status, reason) do
    require Logger
    Logger.warning("Redka tracker transition failed issue_id=#{issue_id} status=#{status} reason=#{inspect(reason)}")
    :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  defp to_issue(%{id: id} = intent) do
    %Issue{
      id: id,
      identifier: id,
      title: intent.title,
      description: intent.description,
      state: intent.state,
      labels: intent.labels || [],
      url: nil,
      repo: intent.repo,
      dispatchable: true,
      created_at: parse_datetime(intent.created_at),
      updated_at: parse_datetime(intent.updated_at)
    }
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
