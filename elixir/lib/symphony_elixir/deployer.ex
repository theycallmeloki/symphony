defmodule SymphonyElixir.Deployer do
  @moduledoc """
  Human-triggered deploy of an awaiting thread's workspace.

  The harness model: an agent run never emits at run end — it parks the
  workspace (dirty) and the thread goes `awaiting`. The human clicks
  Deploy, which emits the parked workspace's edits to the sandman git
  delta receiver, journals `delta_emitted`/`build_submitted` on the
  thread, and hands the build to `BuildFusion` for pipeline tracking
  (watch job → kaniko → registry tag → auto-verify).

  `deploy/1` is safe to call concurrently with a running agent only if
  the workspace is not mid-edit; the deploy API therefore requires the
  thread to be `awaiting` (agent parked, not writing).
  """

  require Logger

  alias SymphonyElixir.{
    AgentRuntime.SessionRegistry,
    BuildFusion,
    Config,
    RepoDelta,
    RunJournal,
    Tracker.Issue
  }
  alias SymphonyElixir.Intents.{Intent, IntentStore}

  @type deploy_result ::
          {:ok, %{head: String.t(), state: :deployed}}
          | {:ok, :no_changes}
          | {:error, term()}

  @doc """
  Deploys an awaiting thread: emits its parked workspace and journals the
  build submission. Returns `{:ok, %{head: head}}` after the delta was
  delivered, `{:ok, :no_changes}` when the workspace holds no edits, or
  `{:error, reason}`.
  """
  @spec deploy(String.t()) :: deploy_result()
  def deploy(intent_id) when is_binary(intent_id) do
    with {:ok, %Intent{state: "awaiting"} = intent} <- fetch_awaiting(intent_id),
         {:ok, workspace} <- parked_workspace(intent),
         {:ok, issue} <- to_issue(intent) do
      do_deploy(issue, intent, workspace)
    end
  end

  @doc """
  The state an intent must be in for a deploy. Exposed for the API layer.
  """
  @spec deployable?(Intent.t()) :: boolean()
  def deployable?(%Intent{state: state, repo: repo}) do
    state == "awaiting" and is_binary(repo) and repo != ""
  end

  @doc """
  The parked workspace's un-committed edit paths — the dry-run view for
  the driver-seat dirty-file list. Reads names only (no content, nothing
  emitted). `{:ok, paths}` for a parked workspace, `{:ok, []}` when the
  tree is clean, or `{:error, reason}` when the thread has no parked
  workspace or the workspace is not a bootstrapped git checkout.
  """
  @spec dirty_files(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def dirty_files(intent_id) when is_binary(intent_id) do
    with {:ok, %Intent{} = intent} <- fetch_intent(intent_id),
         {:ok, workspace} <- parked_workspace(intent) do
      RepoDelta.dirty_paths(workspace)
    end
  end

  defp fetch_intent(intent_id) do
    case IntentStore.get_intent(intent_id) do
      {:ok, %Intent{} = intent} -> {:ok, intent}
      {:error, :not_found} = error -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_awaiting(intent_id) do
    case fetch_intent(intent_id) do
      {:ok, %Intent{} = intent} ->
        if intent.state == "awaiting" do
          {:ok, intent}
        else
          {:error, {:invalid_state, intent.state}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parked_workspace(%Intent{} = intent) do
    case SessionRegistry.workspace(intent.id) do
      workspace when is_binary(workspace) ->
        if File.dir?(workspace) do
          {:ok, workspace}
        else
          {:error, :workspace_missing}
        end

      nil ->
        {:error, :no_parked_workspace}
    end
  end

  # Mirror the redka adapter's intent -> issue shape for the emit path.
  defp to_issue(%Intent{} = intent) do
    {:ok,
     %Issue{
       id: intent.id,
       identifier: intent.id,
       title: intent.title,
       description: intent.description,
       state: intent.state,
       labels: intent.labels || [],
       url: nil,
       repo: intent.repo,
       dispatchable: true,
       created_at: nil,
       updated_at: nil
     }}
  end

  defp do_deploy(issue, intent, workspace) do
    case RepoDelta.emit_delta(workspace, issue, nil) do
      {:ok, :delivered} ->
        case submit_build(issue, intent) do
          {:ok, head} ->
            Logger.info("Deploy delivered issue=#{issue.id} head=#{head}")
            {:ok, %{head: head, state: :deployed}}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, :no_changes} ->
        Logger.info("Deploy requested but workspace has no changes issue=#{issue.id}")
        {:ok, :no_changes}

      {:error, reason} ->
        Logger.warning("Deploy emit failed issue=#{issue.id} reason=#{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Deploy crashed issue=#{issue.id} error=#{Exception.message(error)}")
      {:error, {:deploy_crashed, Exception.message(error)}}
  end

  # Journal the submitted build and hand it to BuildFusion for pipeline
  # tracking. Returns {:ok, mirror_head} once journaled.
  defp submit_build(issue, intent) do
    base = RepoDelta.sandman_base()

    with {:ok, head} when is_binary(head) <-
           RepoDelta.mirror_head(base, issue.repo, RepoDelta.tracked_branch()),
         branch <- RepoDelta.tracked_branch(),
         image <- RepoDelta.repo_name(issue.repo),
         registry <- build_events_registry() do
      payload = %{
        "issue_id" => issue.id,
        "repo" => issue.repo,
        "branch" => branch,
        "head" => head,
        "image" => image,
        "registry" => registry
      }

      journal_event(issue, "delta_emitted", payload)
      journal_event(issue, "build_submitted", payload)

      if is_binary(issue.identifier) do
        BuildFusion.track(issue.identifier, issue.repo, branch, image, registry, head, intent.description)
      end

      {:ok, head}
    else
      {:error, reason} ->
        Logger.warning("Deploy head fetch failed issue=#{issue.id} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp journal_event(issue, event, payload) do
    if RunJournal.enabled?() and is_binary(issue.identifier) and is_binary(issue.repo) do
      RunJournal.record(RunJournal.root(), issue.identifier, event, payload)
    end

    :ok
  end

  defp build_events_registry do
    case Config.settings!().observability |> Map.get(:build_events_registry) do
      registry when is_binary(registry) and registry != "" -> registry
      _ -> BuildFusion.default_registry()
    end
  end
end
