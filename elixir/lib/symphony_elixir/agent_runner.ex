defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with the configured
  agent runtime (codex by default; pi-acp when configured).

  Runs are *threaded*: when the SessionRegistry is live the agent session
  is parked between dispatches, so the next human prompt in the same
  thread resumes the same conversation. A normal run completion never
  emits the workspace — delivery happens only when the human triggers a
  deploy (the harness model). Internal verification intents additionally
  record a verdict (`verify.txt`) to the thread they verify.
  """

  require Logger

  alias SymphonyElixir.{
    AgentRuntime,
    Config,
    PromptBuilder,
    RepoDelta,
    RunJournal,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.AgentRuntime.{SessionPark, SessionRegistry}
  alias SymphonyElixir.Intents.{Intent, IntentStore, ReworkPlan}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        # repo-backed intents get a working copy of the mirrored repo in
        # the workspace before the agent starts (best effort, never fatal)
        RepoDelta.best_effort_bootstrap(workspace, issue, worker_host)

        result =
          try do
            with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
              run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
            end
          after
            Workspace.run_after_run_hook(workspace, issue, worker_host)
          end

        # Verification passes never emit; they record a verdict instead.
        # Harness threads never emit at run end either — delivery happens
        # only via the explicit deploy action on the awaiting thread.
        maybe_record_verify_verdict(result, workspace, issue)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- verification verdicts -------------------------------------------------
  #
  # A verification intent (verify_for set) runs one read-only pass against
  # the built head's tree. When it completes cleanly, its verdict file
  # (`verify.txt`: line 1 SOLVED | NOT_SOLVED | UNCLEAR, then evidence) is
  # journaled onto the thread it verifies. Best effort: never raises, never
  # fails the run.

  defp maybe_record_verify_verdict(:ok, workspace, %Issue{identifier: identifier})
       when is_binary(identifier) do
    case verify_target(identifier) do
      {:verify, verify_for} ->
        record_verify_verdict(workspace, identifier, verify_for)

      :not_verify ->
        :ok
    end
  rescue
    error ->
      Logger.error("verify verdict recording crashed error=#{Exception.message(error)}")
      :ok
  end

  defp maybe_record_verify_verdict(_result, _workspace, _issue), do: :ok

  defp verify_target(identifier) do
    case IntentStore.get_intent(identifier) do
      {:ok, %Intent{verify_for: verify_for}} when is_binary(verify_for) -> {:verify, verify_for}
      _ -> :not_verify
    end
  end

  defp record_verify_verdict(workspace, verify_intent_id, verify_for) do
    verdict_file = Path.join(workspace, "verify.txt")

    case File.read(verdict_file) do
      {:ok, content} ->
        lines = content |> String.split("\n", trim: true)

        case lines do
          [verdict | evidence_lines] ->
            verdict_atom = normalize_verdict(verdict)
            event = verdict_event(verdict_atom)
            plan = apply_rework_plan(verdict_atom, workspace, verify_for)

            payload = %{
              "verify_intent" => verify_intent_id,
              "workspace" => workspace,
              "verdict" => to_string(verdict_atom),
              "evidence" => Enum.join(evidence_lines, "\n"),
              "rework" => rework_summary(plan)
            }

            if RunJournal.enabled?() do
              RunJournal.record(RunJournal.root(), verify_for, event, payload)
              Logger.info("Verification verdict #{event} thread=#{verify_for} verdict=#{verdict_atom}")
            end

          _ ->
            Logger.warning("verify.txt present but unreadable as a verdict verify_intent=#{verify_intent_id}")
        end

      {:error, :enoent} ->
        Logger.warning("verification pass finished without verify.txt verify_intent=#{verify_intent_id}")

      {:error, reason} ->
        Logger.warning("verify.txt read failed verify_intent=#{verify_intent_id} reason=#{inspect(reason)}")
    end

    :ok
  end

  # Rework-plan lifecycle on the thread: a NOT_SOLVED verdict stores the
  # pass's rework.json (replacing any prior plan), a SOLVED verdict clears
  # the plan, an UNCLEAR verdict leaves it untouched. Best effort.
  defp apply_rework_plan(:solved, _workspace, verify_for) do
    IntentStore.record_rework_plan(verify_for, nil)
    nil
  end

  defp apply_rework_plan(:not_solved, workspace, verify_for) do
    plan = ReworkPlan.parse_file(Path.join(workspace, ReworkPlan.file_name()))
    IntentStore.record_rework_plan(verify_for, plan)

    if plan do
      Logger.info("Verification rework plan recorded thread=#{verify_for} items=#{length(plan["items"] || [])}")
    else
      Logger.warning("NOT_SOLVED verdict without a parseable rework.json verify_workspace=#{workspace}")
    end

    plan
  end

  defp apply_rework_plan(:unclear, _workspace, _verify_for), do: nil

  defp rework_summary(nil), do: nil

  defp rework_summary(%{} = plan) do
    %{"summary" => plan["summary"] || "", "item_count" => length(plan["items"] || [])}
  end

  defp normalize_verdict(line) do
    case line |> String.trim() |> String.upcase() do
      "SOLVED" -> :solved
      "NOT_SOLVED" -> :not_solved
      _ -> :unclear
    end
  end

  defp verdict_event(:solved), do: "verify_passed"
  defp verdict_event(:not_solved), do: "verify_failed"
  defp verdict_event(:unclear), do: "verify_unclear"

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    case parked_turn_runner(issue, workspace, codex_update_recipient, opts, worker_host) do
      {:ok, turn_runner} ->
        # The session is parked (owned by the SessionRegistry) and stays
        # alive after this run returns — the thread survives for the next
        # human prompt or a deploy of the parked workspace.
        do_run_codex_turns(turn_runner, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)

      {:error, :not_running} ->
        # No SessionRegistry (unit tests / standalone boot / park opt-in):
        # run with an inline session owned by this task and stop it when
        # the run ends.
        runtime = AgentRuntime.impl()

        with {:ok, session} <- runtime.start_session(workspace, worker_host: worker_host) do
          try do
            turn_runner = fn prompt, turn_issue ->
              runtime.run_turn(
                session,
                prompt,
                turn_issue,
                on_message: codex_message_handler(codex_update_recipient, turn_issue)
              )
            end

            do_run_codex_turns(turn_runner, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
          after
            runtime.stop_session(session)
          end
        end

      {:error, reason} ->
        {:error, {:session_acquire_failed, reason}}
    end
  end

  # A turn runner bound to the issue's parked session: only when the
  # orchestrator dispatched with `park_sessions: true` (the harness
  # runtime) and the SessionRegistry is live. Otherwise falls back to
  # inline (test/legacy) sessions.
  defp parked_turn_runner(%Issue{identifier: identifier} = issue, workspace, codex_update_recipient, opts, _worker_host)
       when is_binary(identifier) do
    if Keyword.get(opts, :park_sessions, false) do
      case SessionRegistry.acquire(identifier, workspace) do
        {:ok, park_pid, mode} ->
          Logger.info("Agent session #{mode} for #{issue_context(issue)} workspace=#{workspace}")

          {:ok,
           fn prompt, turn_issue ->
             SessionPark.run_turn(
               park_pid,
               prompt,
               turn_issue,
               on_message: codex_message_handler(codex_update_recipient, turn_issue)
             )
           end}

        {:error, :not_running} = error ->
          error

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_running}
    end
  end

  defp parked_turn_runner(_issue, _workspace, _codex_update_recipient, _opts, _worker_host) do
    {:error, :not_running}
  end

  defp do_run_codex_turns(turn_runner, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <- turn_runner.(prompt, issue) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            turn_runner,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    issue
    |> PromptBuilder.build_prompt(opts)
    |> prepend_rework_plan(issue)
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  # The first turn of a re-dispatch carries the thread's recorded rework
  # plan (when present and not yet delivered) so the failure of the last
  # verification pass structurally drives this pass. Marked dispatched on
  # delivery; a fresh NOT_SOLVED verdict replaces the plan and re-arms it.
  defp prepend_rework_plan(prompt, %Issue{identifier: identifier}) when is_binary(identifier) do
    with {:ok, %Intent{rework_plan: %{} = plan}} <- IntentStore.get_intent(identifier),
         {:ok, block} <- rework_block(plan) do
      :ok = IntentStore.mark_rework_plan_dispatched(identifier)
      block <> "\n\n" <> prompt
    else
      _ -> prompt
    end
  end

  defp prepend_rework_plan(prompt, _issue), do: prompt

  defp rework_block(%{"dispatched_at" => dispatched}) when is_binary(dispatched), do: :error

  defp rework_block(plan) do
    case ReworkPlan.block(plan) do
      nil -> :error
      block -> {:ok, block}
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
