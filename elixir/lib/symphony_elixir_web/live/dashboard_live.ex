defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Workbench harness dashboard for Symphony.

  A user writes a prompt; the prompt goes to the pi agent, which works on a
  real checkout and then parks. The thread BLOCKS on "ask satisfied"; the
  operator either deploys the parked workspace or sends the next prompt,
  which resumes the same session. After a deploy, an auto verification pass
  journals its verdict back onto the thread.

  Layout: a thread rail on the left (non-verify intents, newest first), a
  driver seat for the selected thread (phase strip, journal timeline,
  deploy/next-prompt controls), and a collapsible system drawer holding the
  ops tables (running/blocked/retrying, limits and tokens, run history).
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @state_filters [
    {"all", "All"},
    {"awaiting", "Ask satisfied"},
    {"queued", "Queued"},
    {"open", "Open"},
    {"running", "Running"},
    {"done", "Done"},
    {"failed", "Failed"},
    {"cancelled", "Cancelled"}
  ]

  # Canonical thread lifecycle milestones for the phase strip (per latest
  # run cycle): steps are marked done/active/todo from intent state and the
  # journal events recorded after the last run boundary.
  @phase_steps [
    {:queued, "Queued"},
    {:running, "Agent running"},
    {:awaiting, "Ask satisfied"},
    {:deploy, "Deploy & build"},
    {:deployed, "Deployed"},
    {:verifying, "Verifying"},
    {:verdict, "Verdict"}
  ]

  @deploy_events ~w(delta_emitted build_submitted job_started job_finished)
  @verdict_events ~w(verify_passed verify_failed verify_unclear)

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()
    intents = load_intents()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:runs, load_runs())
      |> assign(:now, DateTime.utc_now())
      |> assign_intents(intents)
      |> assign(:notice, nil)
      |> assign(:notice_timer, nil)
      |> assign(:intents_filter, "all")
      |> assign(:collapsed, default_collapsed())
      |> assign(:selected, nil)
      |> assign(:thread, nil)
      |> assign(:detail, nil)
      |> assign(:phase, nil)
      |> assign(:verifications, [])
      |> assign(:expanded_run, nil)
      |> assign(:expanded_transcript, [])
      |> assign(:tracked_repos, load_tracked_repos())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    {:noreply,
     socket
     |> assign(:now, DateTime.utc_now())
     |> maybe_refresh_detail()}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:runs, load_runs())
     |> assign(:now, DateTime.utc_now())
     |> assign_intents(load_intents())
     |> assign(:tracked_repos, load_tracked_repos())
     |> sync_seat(false)}
  end

  @impl true
  def handle_info(:clear_notice, socket) do
    {:noreply, assign(socket, notice: nil, notice_timer: nil)}
  end

  @impl true
  def handle_event("register_intent", params, socket) do
    case SymphonyElixir.Intents.IntentStore.create_intent(params) do
      {:ok, intent} ->
        {:noreply,
         socket
         |> put_notice(:success, "Thread #{short_id(intent.id)} registered — dispatched.")
         |> refresh_intents()
         |> assign(selected: intent.id, expanded_run: nil)
         |> sync_seat(true)}

      {:error, {:missing_field, field}} ->
        {:noreply, put_notice(socket, :error, "Missing required field: #{field}")}

      {:error, reason} ->
        {:noreply, put_notice(socket, :error, "Could not register thread: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_intent", %{"id" => id}, socket) when is_binary(id) do
    case SymphonyElixir.Intents.IntentStore.cancel_intent(id) do
      {:ok, _intent} ->
        {:noreply,
         socket
         |> put_notice(:success, "Intent #{short_id(id)} cancelled.")
         |> refresh_intents()
         |> sync_seat(false)}

      {:error, :invalid_state} ->
        {:noreply, put_notice(socket, :error, "Intent #{short_id(id)} is already terminal.")}

      {:error, reason} ->
        {:noreply, put_notice(socket, :error, "Could not cancel intent #{short_id(id)}: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel_intent", _params, socket) do
    {:noreply, put_notice(socket, :error, "Missing intent id.")}
  end

  @impl true
  def handle_event("queue_repos", %{"repos" => repos}, socket) when is_binary(repos) do
    lines =
      repos
      |> String.split(~r/[\n,]+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {queued, errors} =
      lines
      |> Enum.map(fn repo_ref -> queue_repo_intent(repo_ref) end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    {kind, message} =
      cond do
        queued == [] and errors != [] ->
          {:error, "No repos queued — all failed."}

        errors == [] ->
          {:success, "Queued #{length(queued)} repo intent#{if(length(queued) == 1, do: "", else: "s")}."}

        true ->
          {:error, "Queued #{length(queued)}; #{length(errors)} failed."}
      end

    {:noreply,
     socket
     |> put_notice(kind, message)
     |> refresh_intents()}
  end

  def handle_event("queue_repos", _params, socket) do
    {:noreply, put_notice(socket, :error, "Paste repo URLs or owner/name lines to queue.")}
  end

  @impl true
  def handle_event("queue_tracked_repo", %{"repo" => repo}, socket)
      when is_binary(repo) and repo != "" do
    case queue_repo_intent(repo) do
      {:ok, intent} ->
        {:noreply,
         socket
         |> put_notice(:success, "Queued repo intent #{short_id(intent.id)} for #{repo_slug(repo)}.")
         |> refresh_intents()}

      {:error, reason} ->
        {:noreply, put_notice(socket, :error, "Could not queue #{repo_slug(repo)}: #{inspect(reason)}")}
    end
  end

  def handle_event("queue_tracked_repo", _params, socket) do
    {:noreply, put_notice(socket, :error, "Missing repo reference.")}
  end

  @impl true
  def handle_event("toggle_issue_detail", %{"id" => id}, socket) when is_binary(id) do
    if socket.assigns.selected == id do
      {:noreply,
       socket
       |> assign(selected: nil, expanded_run: nil)
       |> sync_seat(false)}
    else
      {:noreply,
       socket
       |> assign(selected: id, expanded_run: nil)
       |> sync_seat(true)}
    end
  end

  def handle_event("toggle_issue_detail", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "queued_task",
        %{"intent_id" => id, "description" => description, "action" => action},
        socket
      )
      when is_binary(id) do
    trimmed = String.trim(description || "")

    cond do
      action == "run" and trimmed == "" ->
        {:noreply, put_notice(socket, :error, "Assign a task description before running.")}

      action == "run" ->
        case SymphonyElixir.Intents.IntentStore.assign_and_activate_intent(id, %{description: trimmed}) do
          {:ok, intent} ->
            {:noreply,
             socket
             |> put_notice(:success, "#{short_id(intent.id)} dispatched — agent picked it up.")
             |> refresh_intents()
             |> sync_seat(false)}

          {:error, :invalid_state} ->
            {:noreply, put_notice(socket, :error, "#{short_id(id)} is not queued anymore.")}

          {:error, reason} ->
            {:noreply, put_notice(socket, :error, "Could not run #{short_id(id)}: #{inspect(reason)}")}
        end

      action == "save" ->
        case SymphonyElixir.Intents.IntentStore.assign_intent(id, %{description: trimmed}) do
          {:ok, intent} ->
            {:noreply,
             socket
             |> put_notice(:success, "Task saved for #{short_id(intent.id)}.")
             |> refresh_intents()
             |> sync_seat(false)}

          {:error, :invalid_state} ->
            {:noreply, put_notice(socket, :error, "#{short_id(id)} is not queued anymore.")}

          {:error, reason} ->
            {:noreply, put_notice(socket, :error, "Could not save task for #{short_id(id)}: #{inspect(reason)}")}
        end

      true ->
        {:noreply, put_notice(socket, :error, "Unknown action.")}
    end
  end

  def handle_event("queued_task", _params, socket) do
    {:noreply, put_notice(socket, :error, "Missing intent id.")}
  end

  @impl true
  def handle_event("deploy_intent", %{"id" => id}, socket) when is_binary(id) do
    case SymphonyElixir.Deployer.deploy(id) do
      {:ok, %{head: head}} ->
        {:noreply,
         socket
         |> put_notice(:success, "Deployed #{head12(head)} — build submitted and tracked.")
         |> refresh_journal()}

      {:ok, :no_changes} ->
        {:noreply, put_notice(socket, :error, "Nothing to deploy — the parked workspace holds no changes.")}

      {:error, {:invalid_state, state}} ->
        {:noreply, put_notice(socket, :error, "Cannot deploy — thread is #{state}; deploy requires ask satisfied.")}

      {:error, :no_parked_workspace} ->
        {:noreply, put_notice(socket, :error, "Cannot deploy — no parked workspace for this thread.")}

      {:error, :workspace_missing} ->
        {:noreply, put_notice(socket, :error, "Cannot deploy — the workspace directory is missing.")}

      {:error, reason} ->
        {:noreply, put_notice(socket, :error, "Deploy failed: #{inspect(reason)}")}
    end
  end

  def handle_event("deploy_intent", _params, socket) do
    {:noreply, put_notice(socket, :error, "Missing intent id.")}
  end

  @impl true
  def handle_event("send_prompt", %{"thread_id" => id, "description" => description}, socket)
      when is_binary(id) do
    trimmed = String.trim(description || "")

    if trimmed == "" do
      {:noreply, put_notice(socket, :error, "Type the next prompt before sending.")}
    else
      case SymphonyElixir.Intents.IntentStore.assign_and_activate_intent(id, %{description: trimmed}) do
        {:ok, intent} ->
          {:noreply,
           socket
           |> put_notice(:success, "Next prompt sent to #{short_id(intent.id)} — agent resumed.")
           |> refresh_intents()
           |> sync_seat(false)}

        {:error, :invalid_state} ->
          {:noreply, put_notice(socket, :error, "#{short_id(id)} is not awaiting anymore.")}

        {:error, reason} ->
          {:noreply, put_notice(socket, :error, "Could not send prompt: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("send_prompt", _params, socket) do
    {:noreply, put_notice(socket, :error, "Missing thread id.")}
  end

  @impl true
  def handle_event("close_thread", %{"id" => id}, socket) when is_binary(id) do
    case SymphonyElixir.Intents.IntentStore.close_intent(id) do
      {:ok, _intent} ->
        {:noreply,
         socket
         |> put_notice(:success, "Thread #{short_id(id)} closed.")
         |> refresh_intents()
         |> sync_seat(false)}

      {:error, :invalid_state} ->
        {:noreply, put_notice(socket, :error, "Only an ask-satisfied thread can be closed.")}

      {:error, reason} ->
        {:noreply, put_notice(socket, :error, "Could not close thread: #{inspect(reason)}")}
    end
  end

  def handle_event("close_thread", _params, socket) do
    {:noreply, put_notice(socket, :error, "Missing thread id.")}
  end

  @impl true
  def handle_event("new_thread", _params, socket) do
    {:noreply,
     socket
     |> assign(selected: nil, expanded_run: nil)
     |> sync_seat(false)}
  end

  @impl true
  def handle_event("toggle_run_transcript", %{"run" => run}, socket) do
    case Integer.parse(run) do
      {index, ""} ->
        expanded = if socket.assigns.expanded_run == index, do: nil, else: index

        {:noreply,
         socket
         |> assign(expanded_run: expanded)
         |> refresh_expanded_transcript()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_run_transcript", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("dismiss_notice", _params, socket) do
    {:noreply, assign(socket, notice: nil, notice_timer: nil)}
  end

  @impl true
  def handle_event("filter_intents", %{"state" => state}, socket) when is_binary(state) do
    {:noreply, assign(socket, :intents_filter, state)}
  end

  def handle_event("filter_intents", _params, socket) do
    {:noreply, assign(socket, :intents_filter, "all")}
  end

  @impl true
  def handle_event("toggle_section", %{"key" => key}, socket) when is_binary(key) do
    collapsed = socket.assigns.collapsed
    new_state = if MapSet.member?(collapsed, key), do: MapSet.delete(collapsed, key), else: MapSet.put(collapsed, key)
    {:noreply, assign(socket, :collapsed, new_state)}
  end

  def handle_event("toggle_section", _params, socket) do
    {:noreply, socket}
  end

  defp queue_repo_intent(repo_ref) do
    slug = repo_slug(repo_ref)

    SymphonyElixir.Intents.IntentStore.create_intent(%{
      "state" => "queued",
      "title" => "Repo job: #{slug}",
      "repo" => repo_ref,
      "labels" => ["repo-queue"]
    })
  end

  defp repo_slug(repo_ref) do
    repo_ref
    |> String.trim()
    |> String.trim_trailing(".git")
    |> String.split(["/", ":"], trim: true)
    |> List.last()
    |> Kernel.||("repo")
  end

  defp put_notice(socket, kind, text) do
    if socket.assigns.notice_timer, do: Process.cancel_timer(socket.assigns.notice_timer)
    timer = Process.send_after(self(), :clear_notice, 4_500)
    assign(socket, notice: %{kind: kind, text: text}, notice_timer: timer)
  end

  defp assign_intents(socket, intents) do
    socket
    |> assign(:intents, intents)
    |> assign(:threads, thread_list(intents))
  end

  defp refresh_intents(socket) do
    assign_intents(socket, load_intents())
  end

  defp short_id(id) when is_binary(id) do
    case String.split(id, "-") do
      [_prefix, _ts, suffix] -> "int-…#{suffix}"
      _ -> id
    end
  end

  defp short_id(id), do: to_string(id)

  defp default_collapsed do
    MapSet.new(["drawer"])
  end

  # ── Seat (selected thread) sync ────────────────────────────────────────

  # Re-resolve the selected thread struct and its verification passes from
  # the current intent list. With reload?=true the journal detail is read
  # again immediately; otherwise only the in-memory projections (thread,
  # verifications, phase) are recomputed — the 1s tick refreshes detail.
  defp sync_seat(socket, reload?) do
    intents = socket.assigns.intents

    case socket.assigns.selected do
      nil ->
        assign(socket, thread: nil, detail: nil, phase: nil, verifications: [], expanded_run: nil, expanded_transcript: [])

      id ->
        case Enum.find(intents, &(&1.id == id and &1.verify_for == nil)) do
          nil ->
            assign(socket, thread: nil, detail: nil, phase: nil, verifications: [], expanded_run: nil, expanded_transcript: [])

          thread ->
            verifications = verification_intents(intents, id)
            socket = socket |> assign(thread: thread, verifications: verifications)

            if reload? do
              refresh_journal(socket)
            else
              refresh_phase(socket)
            end
        end
    end
  end

  defp refresh_phase(socket) do
    case {socket.assigns.thread, socket.assigns.detail} do
      {nil, _detail} -> assign(socket, :phase, nil)
      {thread, detail} -> assign(socket, :phase, phase_for(thread, detail, socket.assigns.verifications))
    end
  end

  # Journal detail + phase + expanded transcript, re-read from disk.
  defp refresh_journal(socket) do
    case socket.assigns.thread do
      nil ->
        socket

      thread ->
        detail = issue_detail_payload(thread.id)

        socket
        |> assign(detail: detail)
        |> refresh_phase()
        |> refresh_expanded_transcript()
    end
  end

  defp maybe_refresh_detail(socket), do: refresh_journal(socket)

  defp refresh_expanded_transcript(socket) do
    case {socket.assigns.thread, socket.assigns.expanded_run} do
      {nil, _run} -> assign(socket, :expanded_transcript, [])
      {_thread, nil} -> assign(socket, :expanded_transcript, [])
      {thread, run_index} -> assign(socket, :expanded_transcript, thread_transcript(thread.id, run_index))
    end
  end

  defp thread_list(intents) do
    intents
    |> Enum.reject(&verify_intent?/1)
    |> Enum.sort_by(&intent_sort_epoch/1, :desc)
  end

  defp verify_intent?(%{verify_for: verify_for}) when is_binary(verify_for), do: true
  defp verify_intent?(%{labels: labels}), do: "verify" in (labels || [])
  defp verify_intent?(_), do: false

  defp verification_intents(intents, thread_id) do
    intents
    |> Enum.filter(&(&1.verify_for == thread_id))
    |> Enum.sort_by(&intent_sort_epoch/1, :desc)
  end

  defp thread_for_id(threads, id) do
    Enum.find(threads, &(&1.id == id))
  end

  defp thread_transcript(identifier, run_index) do
    if SymphonyElixir.RunJournal.enabled?() do
      try do
        SymphonyElixir.RunJournal.transcript_events(
          SymphonyElixir.RunJournal.root(),
          identifier,
          run_index,
          80
        )
      rescue
        _ -> []
      end
    else
      []
    end
  end

  # ── Phase strip ────────────────────────────────────────────────────────

  defp phase_for(thread, detail, verifications) do
    events = detail_events(detail)
    all_keys = event_keys(events)
    tail_keys = event_keys(journal_tail(events))
    state = thread.state

    verifying_open? =
      Enum.any?(verifications, &(&1.state in ~w(queued open running awaiting)))

    current =
      cond do
        state == "queued" -> :queued
        state in ~w(open running) -> :running
        state in ~w(done failed cancelled) -> :terminal
        true -> awaiting_subphase(tail_keys, verifying_open?)
      end

    chips =
      Enum.map(@phase_steps, fn {key, label} ->
        %{key: key, label: label, status: step_status(key, state, current, all_keys, tail_keys, events, verifying_open?)}
      end)

    %{
      current: current,
      chips: chips,
      hint: phase_hint(current, state),
      verdict: tail_verdict(journal_tail(events)),
      terminal: terminal_info(state)
    }
  end

  defp awaiting_subphase(tail_keys, verifying_open?) do
    cond do
      Enum.any?(@verdict_events, &(&1 in tail_keys)) -> :verdict
      verifying_open? or "verification_started" in tail_keys -> :verifying
      "build_succeeded" in tail_keys -> :deployed
      Enum.any?(@deploy_events, &(&1 in tail_keys)) -> :deploy
      true -> :awaiting
    end
  end

  defp step_status(:queued, state, _current, _all_keys, _tail_keys, _events, _verifying_open?) do
    if state == "queued", do: :active, else: :todo
  end

  defp step_status(:running, state, _current, all_keys, _tail_keys, _events, _verifying_open?) do
    cond do
      state in ~w(open running) -> :active
      state in ~w(awaiting done) -> :done
      state == "failed" -> :done
      "run_started" in all_keys -> :done
      true -> :todo
    end
  end

  defp step_status(:awaiting, state, current, _all_keys, _tail_keys, events, _verifying_open?) do
    cond do
      state == "awaiting" and current == :awaiting -> :active
      current in [:deploy, :deployed, :verifying, :verdict] -> :done
      state == "done" -> :done
      state in ~w(failed cancelled) and completed_run?(events) -> :done
      true -> :todo
    end
  end

  defp step_status(:deploy, _state, current, _all_keys, tail_keys, _events, _verifying_open?) do
    if Enum.any?(@deploy_events, &(&1 in tail_keys)) do
      if current == :deploy, do: :active, else: :done
    else
      :todo
    end
  end

  defp step_status(:deployed, _state, current, _all_keys, tail_keys, _events, _verifying_open?) do
    if "build_succeeded" in tail_keys do
      if current == :deployed, do: :active, else: :done
    else
      :todo
    end
  end

  defp step_status(:verifying, _state, current, _all_keys, tail_keys, _events, verifying_open?) do
    if verifying_open? or "verification_started" in tail_keys do
      if current == :verifying, do: :active, else: :done
    else
      :todo
    end
  end

  defp step_status(:verdict, _state, current, _all_keys, tail_keys, _events, _verifying_open?) do
    if Enum.any?(@verdict_events, &(&1 in tail_keys)) do
      if current == :verdict, do: :active, else: :done
    else
      :todo
    end
  end

  defp completed_run?(events) do
    events
    |> Enum.reverse()
    |> Enum.find(&(journal_field(&1, "event") == "run_finished"))
    |> Kernel.then(fn event ->
      case event do
        nil -> false
        event -> journal_field(event, "status") not in [nil, "failed", "blocked", "cancelled"]
      end
    end)
  end

  defp phase_hint(:queued, _state),
    do: "Queued — assign a task below to dispatch this thread to the agent."

  defp phase_hint(:running, _state), do: "Agent working — workspace events stream below in real time."
  defp phase_hint(:awaiting, _state), do: "Ask satisfied — deploy the workspace or send the next prompt."
  defp phase_hint(:deploy, _state), do: "Delta emitted — build submitted; watching the watch pipeline."
  defp phase_hint(:deployed, _state), do: "Build succeeded — image published; auto-verification is next."
  defp phase_hint(:verifying, _state), do: "Verification pass running against the built head."
  defp phase_hint(:verdict, _state), do: "Verification finished — the verdict and evidence are below."

  defp phase_hint(:terminal, state) do
    case state do
      "done" -> "Thread closed. Start a new thread to begin another ask."
      "failed" -> "Thread ended in failure. Start a new thread for a fresh ask."
      "cancelled" -> "Thread cancelled."
    end
  end

  defp terminal_info(nil), do: nil

  defp terminal_info(state) when state in ~w(done failed cancelled) do
    label =
      case state do
        "done" -> "Closed"
        "failed" -> "Failed"
        "cancelled" -> "Cancelled"
      end

    %{state: state, label: label}
  end

  defp terminal_info(_state), do: nil

  defp detail_events(%{events: events}) when is_list(events), do: events
  defp detail_events(_detail), do: []

  defp event_keys(events) do
    events
    |> Enum.map(&journal_field(&1, "event"))
    |> Enum.reject(&is_nil/1)
  end

  # Events recorded after the last run boundary: the current cycle's
  # deploy/build/verify activity that follows an ask-satisfied run.
  defp journal_tail(events) do
    case Enum.with_index(events)
         |> Enum.reverse()
         |> Enum.find(fn {event, _i} ->
           journal_field(event, "event") in ~w(run_finished issue_terminal)
         end) do
      nil -> events
      {_event, index} -> Enum.drop(events, index + 1)
    end
  end

  defp tail_verdict([]), do: nil

  defp tail_verdict(events) do
    events
    |> Enum.reverse()
    |> Enum.find(fn event -> journal_field(event, "event") in @verdict_events end)
  end

  defp thread_state_label(state) do
    case state do
      "awaiting" -> "ask satisfied"
      "running" -> "running"
      other -> other
    end
  end

  defp thread_state_chip_class(state) do
    case state do
      "awaiting" -> "state-badge state-badge-awaiting wb-pulse"
      _ -> intent_state_badge_class(state)
    end
  end

  defp driver_next_action(%{state: "queued"}, _phase), do: "Assign task"
  defp driver_next_action(%{state: state}, _phase) when state in ~w(open running), do: "Monitor run"

  defp driver_next_action(%{state: "awaiting"}, %{current: current})
       when current in [:deploy, :deployed, :verifying] do
    "Watch verification"
  end

  defp driver_next_action(%{state: "awaiting"}, %{current: :verdict}), do: "Review verdict"
  defp driver_next_action(%{state: "awaiting"}, _phase), do: "Deploy or prompt"
  defp driver_next_action(%{state: "done"}, _phase), do: "Closed"
  defp driver_next_action(%{state: "failed"}, _phase), do: "Inspect failure"
  defp driver_next_action(%{state: "cancelled"}, _phase), do: "Cancelled"
  defp driver_next_action(_thread, _phase), do: "Inspect"

  defp driver_phase_label(%{current: current}) do
    current
    |> to_string()
    |> String.replace("_", " ")
  end

  defp driver_phase_label(_phase), do: "loading"

  defp detail_run_count(%{runs: runs}) when is_list(runs), do: length(runs)
  defp detail_run_count(_detail), do: 0

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <section class="wb-shell">
      <header class="wb-topbar">
        <div class="wb-brand">
          <p class="eyebrow">Symphony Workbench</p>
          <h1 class="wb-title">Thread Harness</h1>
          <p class="wb-copy">
            <%= thread_count(@threads, "all") %> thread<%= if thread_count(@threads, "all") == 1, do: "", else: "s" %>
            · <%= thread_count(@threads, "awaiting") %> ask satisfied
            · <%= thread_count(@threads, "queued") %> queued
            · <%= verify_count(@intents) %> verification <%= if verify_count(@intents) == 1, do: "pass", else: "passes" %>
          </p>
        </div>

        <div class="wb-topbar-right">
          <div class="wb-stats">
            <span class="wb-stat">
              <span class="wb-stat-label">Running</span>
              <span class="wb-stat-value numeric"><%= payload_count(@payload, :running) %></span>
            </span>
            <span class="wb-stat">
              <span class="wb-stat-label">Blocked</span>
              <span class="wb-stat-value numeric"><%= payload_count(@payload, :blocked) %></span>
            </span>
            <span class="wb-stat">
              <span class="wb-stat-label">Retrying</span>
              <span class="wb-stat-value numeric"><%= payload_count(@payload, :retrying) %></span>
            </span>
            <span class="wb-stat">
              <span class="wb-stat-label">Tokens</span>
              <span class="wb-stat-value numeric"><%= payload_tokens(@payload) %></span>
            </span>
          </div>

          <div class="status-stack wb-live-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>

          <span class="wb-now mono" title={DateTime.to_iso8601(@now)}><%= clock(@now) %> UTC</span>

          <div class="wb-actions">
            <button
              type="button"
              class="collapse-toggle wb-ops-toggle"
              phx-click="toggle_section"
              phx-value-key="drawer"
              title="Toggle the system drawer (running agents, rate limits, run history)"
            >
              <%= if collapsed?(@collapsed, "drawer"), do: "Show ops", else: "Hide ops" %>
              <span class="chip-count"><%= ops_count(@payload) %></span>
            </button>
            <button type="button" class="primary-button wb-new-thread" phx-click="new_thread" title="Start composing a brand-new thread">
              New thread
            </button>
          </div>
        </div>
      </header>

      <%= if @notice do %>
        <p class={notice_class(@notice.kind)} role="status">
          <%= @notice.text %>
          <button type="button" class="notice-dismiss" phx-click="dismiss_notice" aria-label="Dismiss">×</button>
        </p>
      <% end %>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Snapshot unavailable</h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% end %>

      <.command_center threads={@threads} payload={@payload} intents={@intents} now={@now} />

      <div class="wb-body">
        <aside class="wb-rail">
          <div class="wb-rail-head">
            <span class="wb-rail-title">Threads</span>
            <button type="button" class="wb-rail-new" phx-click="new_thread" title="Start a brand-new thread">
              New thread
            </button>
          </div>

          <div class="rail-filter" role="group" aria-label="Filter threads by state">
            <button
              :for={{state, label} <- state_filters()}
              type="button"
              class={filter_chip_class(@intents_filter, state)}
              phx-click="filter_intents"
              phx-value-state={state}
            >
              <%= label %>
              <span class="chip-count"><%= thread_count(@threads, state) %></span>
            </button>
          </div>

          <div class="rail-list">
            <%= for intent <- displayed_threads(@threads, @intents_filter) do %>
              <button
                type="button"
                class={thread_row_class(@selected, intent)}
                phx-click="toggle_issue_detail"
                phx-value-id={intent.id}
                title={intent.description || intent.title}
              >
                <span class="thread-row-title"><%= intent.title %></span>
                <span class="thread-row-sub">
                  <span><%= short_repo(intent.repo) %></span>
                  <span>·</span>
                  <span class="mono numeric" title={intent_stamp(intent) || ""}><%= rel_time(intent_stamp(intent), @now) %></span>
                </span>
                <span class={thread_state_chip_class(intent.state)}>
                  <%= thread_state_label(intent.state) %>
                </span>
              </button>
            <% end %>

            <%= if displayed_threads(@threads, @intents_filter) == [] do %>
              <p class="rail-empty">
                <%= if @intents_filter == "all" do
                  "No threads yet. Start one below."
                else
                  "No #{@intents_filter} threads."
                end %>
              </p>
            <% end %>
          </div>
        </aside>

        <section class="wb-seat">
          <%= if @thread == nil do %>
            <.compose_hero tracked_repos={@tracked_repos} />
          <% else %>
            <.driver_seat thread={@thread} detail={@detail} phase={@phase} verifications={@verifications} now={@now} expanded_run={@expanded_run} expanded_transcript={@expanded_transcript} />
          <% end %>
        </section>
      </div>

      <.system_drawer payload={@payload} runs={@runs} threads={@threads} selected={@selected} collapsed={@collapsed} now={@now} />
    </section>
    """
  end

  attr(:threads, :list, default: [])
  attr(:payload, :map, default: nil)
  attr(:intents, :list, default: [])
  attr(:now, :map, required: true)

  defp command_center(assigns) do
    assigns =
      assigns
      |> assign(:operator_count, thread_count(assigns.threads, "awaiting") + payload_count(assigns.payload, :blocked))
      |> assign(:oldest_operator_wait, oldest_operator_wait(assigns.threads, assigns.now))

    ~H"""
    <section class="harness-command" aria-label="Harness command center">
      <div class="harness-command-head">
        <div>
          <p class="eyebrow">Control loop</p>
          <h2 class="harness-command-title">Run many Codex sessions from one driver seat</h2>
        </div>
        <div class={operator_load_class(@operator_count)}>
          <span class="operator-load-value numeric"><%= @operator_count %></span>
          <span class="operator-load-label">operator action<%= if @operator_count == 1, do: "", else: "s" %></span>
        </div>
      </div>

      <div class="harness-lanes">
        <div class={lane_card_class(thread_count(@threads, "queued"))}>
          <span class="lane-kicker">Intake</span>
          <strong class="lane-value numeric"><%= thread_count(@threads, "queued") %></strong>
          <span class="lane-label">queued threads</span>
        </div>
        <div class={lane_card_class(payload_count(@payload, :running))}>
          <span class="lane-kicker">Execution</span>
          <strong class="lane-value numeric"><%= payload_count(@payload, :running) %></strong>
          <span class="lane-label">active sessions</span>
        </div>
        <div class={lane_card_class(thread_count(@threads, "awaiting"), "lane-card-attention")}>
          <span class="lane-kicker">Driver seat</span>
          <strong class="lane-value numeric"><%= thread_count(@threads, "awaiting") %></strong>
          <span class="lane-label">ask-satisfied</span>
        </div>
        <div class={lane_card_class(verify_count(@intents))}>
          <span class="lane-kicker">Assurance</span>
          <strong class="lane-value numeric"><%= verify_count(@intents) %></strong>
          <span class="lane-label">verification passes</span>
        </div>
        <div class={lane_card_class(payload_count(@payload, :blocked), "lane-card-danger")}>
          <span class="lane-kicker">Interrupts</span>
          <strong class="lane-value numeric"><%= payload_count(@payload, :blocked) %></strong>
          <span class="lane-label">blocked sessions</span>
        </div>
      </div>

      <div class="harness-hints">
        <span>
          Next operator wait:
          <strong><%= @oldest_operator_wait %></strong>
        </span>
        <span>
          Runtime:
          <strong class="numeric"><%= runtime_summary(@payload, @now) %></strong>
        </span>
        <span>
          Tokens:
          <strong class="numeric"><%= payload_tokens(@payload) %></strong>
        </span>
      </div>
    </section>
    """
  end

  attr(:tracked_repos, :list, default: [])

  defp compose_hero(assigns) do
    ~H"""
    <div class="seat-compose">
      <div class="compose-head">
        <p class="eyebrow">No thread selected</p>
        <h2 class="compose-title">Start a new thread</h2>
        <p class="compose-copy">
          Describe the ask — the pi agent works on a real checkout in its workspace. When the
          run parks on ask satisfied, open the thread here to deploy the changes or send the
          next prompt to resume the same session.
        </p>
      </div>

      <div class="compose-grid">
        <form class="intent-form compose-form" phx-submit="register_intent">
          <h3 class="queue-title">New thread</h3>
          <label class="intent-form-field">
            <span>Title</span>
            <input class="intent-form-input" type="text" name="title" required placeholder="e.g. Implement the retry backoff" />
          </label>
          <div class="intent-form-row">
            <label class="intent-form-field intent-form-field-repo">
              <span>Repo (optional)</span>
              <input class="intent-form-input" type="text" name="repo" placeholder="milady/project" />
            </label>
            <label class="intent-form-field intent-form-field-labels">
              <span>Labels (comma)</span>
              <input class="intent-form-input" type="text" name="labels" placeholder="symphony-pilot, infra" />
            </label>
          </div>
          <label class="intent-form-field">
            <span>First prompt</span>
            <textarea
              class="intent-form-input"
              name="description"
              rows="3"
              placeholder="What the agent should accomplish in this thread."
            ></textarea>
          </label>
          <div>
            <button class="primary-button" type="submit" phx-disable-with="Registering…">Start thread</button>
          </div>
        </form>

        <div class="compose-column">
          <div class="queue-chips compose-chips">
            <h3 class="queue-title">Tracked on sandman</h3>
            <p class="form-hint">
              Repos with a build-bus watch pipeline on the control plane — click a chip to queue a new thread against its latest mirror.
            </p>

            <%= if @tracked_repos == [] do %>
              <p class="empty-state">No tracked repos (SANDMAN_ADDR unset or nothing watched).</p>
            <% else %>
              <div class="queue-chips-list">
                <button
                  :for={tracked <- @tracked_repos}
                  type="button"
                  class="queue-chip"
                  phx-click="queue_tracked_repo"
                  phx-value-repo={tracked.git_url || tracked.repo}
                  phx-value-state={tracked.watch_state}
                  title={"Queue a repo job against #{tracked.repo} (#{tracked.git_url || tracked.repo}; watch pipeline #{tracked.watch_pipeline} — #{tracked.watch_state})"}
                >
                  <span><%= tracked.repo %></span>
                  <span class="chip-count"><%= tracked.watch_state %></span>
                </button>
              </div>
            <% end %>
          </div>

          <form class="intent-form compose-form compose-batch" phx-submit="queue_repos">
            <h3 class="queue-title">Batch queue repos</h3>
            <p class="form-hint">One URL or owner/name per line — each becomes a queued thread awaiting a task in the rail.</p>
            <label class="intent-form-field">
              <span>Repos</span>
              <textarea
                class="intent-form-input"
                name="repos"
                rows="3"
                placeholder={"e.g.\ngit@github.com:theycallmeloki/sandman.git\nhttps://github.com/theycallmeloki/symphony.git"}
              ></textarea>
            </label>
            <div>
              <button class="primary-button" type="submit" phx-disable-with="Queuing…">Queue as threads</button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  attr(:thread, :map, required: true)
  attr(:detail, :map, default: nil)
  attr(:phase, :map, default: nil)
  attr(:verifications, :list, default: [])
  attr(:expanded_run, :integer, default: nil)
  attr(:expanded_transcript, :list, default: [])
  attr(:now, :map, required: true)

  defp driver_seat(assigns) do
    ~H"""
    <div class="seat-head">
      <div class="seat-title-block">
        <div class="seat-title-row">
          <h2 class="seat-title"><%= @thread.title %></h2>
          <span class={thread_state_chip_class(@thread.state)}><%= thread_state_label(@thread.state) %></span>
        </div>
        <div class="seat-sub">
          <span class="mono seat-id" title={@thread.id}><%= short_id(@thread.id) %></span>
          <%= if @thread.repo do %>
            <span class="seat-repo"><%= @thread.repo %></span>
          <% end %>
          <span class="muted">updated <span class="mono numeric" title={intent_stamp(@thread) || ""}><%= rel_time(intent_stamp(@thread), @now) %></span></span>
          <a class="issue-link" href={"/api/v1/intents/#{@thread.id}"}>intent JSON</a>
        </div>
      </div>

      <div class="seat-actions">
        <%= if @thread.state in ~w(open running queued) do %>
          <button
            type="button"
            class="subtle-button"
            phx-click="cancel_intent"
            phx-value-id={@thread.id}
            data-confirm="Cancel this thread?"
          >Cancel</button>
        <% end %>
      </div>
    </div>

    <div class="driver-brief" aria-label="Selected thread operating brief">
      <div class="driver-brief-cell driver-brief-primary">
        <span class="driver-brief-label">Next action</span>
        <strong><%= driver_next_action(@thread, @phase) %></strong>
      </div>
      <div class="driver-brief-cell">
        <span class="driver-brief-label">Run phase</span>
        <strong><%= driver_phase_label(@phase) %></strong>
      </div>
      <div class="driver-brief-cell">
        <span class="driver-brief-label">Attempts</span>
        <strong class="numeric"><%= detail_run_count(@detail) %></strong>
      </div>
      <div class="driver-brief-cell">
        <span class="driver-brief-label">Verifications</span>
        <strong class="numeric"><%= length(@verifications) %></strong>
      </div>
    </div>

    <div class="seat-body">
      <div class="phase-card">
        <div class="phase-track">
          <%= for step <- phase_chips(@phase) do %>
            <span class={phase_step_class(step)}>
              <%= step.label %>
            </span>
          <% end %>
        </div>

        <div class="seat-state-block">
          <%= cond do %>
            <% @thread.state == "awaiting" and @phase != nil and @phase.current == :awaiting -> %>
              <div class="block-banner">
                <span class="wb-pulse-dot wb-pulse-dot-amber"></span>
                <div>
                  <span class="block-title">Ask satisfied — thread parked</span>
                  <span class="block-copy">
                    The agent believes the ask is done and its workspace is dirty. Deploy the
                    workspace, or send the next prompt to resume this thread.
                  </span>
                </div>
              </div>

            <% @phase && @phase.current in [:deploy, :deployed, :verifying, :verdict] -> %>
              <p class="phase-caption">
                <%= @phase.hint %>
                <span class="muted">— the thread is still parked on ask satisfied; deploy or send the next prompt whenever ready.</span>
              </p>

            <% @thread.state == "queued" -> %>
              <p class="phase-caption">Queued — this thread is waiting for a task. Assign one below to dispatch it.</p>

            <% @thread.state in ~w(open running) -> %>
              <div class="working-indicator">
                <span class="wb-pulse-dot"></span>
                Agent working — workspace events stream below.
              </div>

            <% @phase && @phase.current == :terminal && @phase.terminal -> %>
              <div class="terminal-banner">
                <span class={phase_terminal_class(@phase.terminal.state)}><%= @phase.terminal.label %></span>
                <span class="muted"><%= @phase.hint %></span>
              </div>

            <% true -> %>
          <% end %>
        </div>

        <%= if @phase && @phase.verdict do %>
          <.verdict_bar event={@phase.verdict} />
        <% end %>
      </div>

      <.seat_controls thread={@thread} phase={@phase} />

      <div class="verifications-block">
        <h3 class="queue-title">Verification passes</h3>

        <%= if @verifications == [] do %>
          <p class="empty-state compact">
            <%= if @thread.state == "awaiting", do: "No verification yet — deploy this thread to trigger an auto-verify pass.", else: "No verification passes recorded for this thread." %>
          </p>
        <% else %>
          <div class="verify-list">
            <div
              :for={verify <- @verifications}
              class="verify-entry"
              title={verify.description || verify.title}
            >
              <span class={intent_state_badge_class(verify.state)}><%= verify.state %></span>
              <span class="verify-title"><%= verify.title %></span>
              <span class="mono numeric verify-time"><%= rel_time(intent_stamp(verify), @now) %></span>
              <a class="issue-link" href={"/api/v1/intents/#{verify.id}"}>details</a>
            </div>
          </div>
        <% end %>
      </div>

      <.journal_block detail={@detail} expanded_run={@expanded_run} expanded_transcript={@expanded_transcript} now={@now} />
    </div>
    """
  end

  attr(:event, :map, required: true)

  defp verdict_bar(assigns) do
    ~H"""
    <div class={verdict_bar_class(@event)}>
      <div class="verdict-head">
        <span class={verdict_head_class(@event)}>
          <%= verdict_head_label(@event) %>
        </span>
        <span class="mono verdict-meta">
          <%= if journal_field(@event, "verify_intent") do %>
            verify <%= short_id(journal_field(@event, "verify_intent")) %>
          <% end %>
          <%= if journal_field(@event, "head") do %>
            · <%= head12(journal_field(@event, "head")) %>
          <% end %>
        </span>
      </div>
      <div class="verdict-evidence">
        <%= verdict_evidence(@event) %>
      </div>
    </div>
    """
  end

  attr(:thread, :map, required: true)
  attr(:phase, :map, default: nil)

  defp seat_controls(assigns) do
    ~H"""
    <div class="seat-controls">
      <%= cond do %>
        <% @thread.state == "queued" -> %>
          <div class="controls-row">
            <div class="controls-block">
              <h3 class="queue-title">Assign a task</h3>
              <form class="prompt-form" phx-submit="queued_task">
                <input type="hidden" name="intent_id" value={@thread.id} />
                <textarea
                  class="intent-form-input prompt-input"
                  name="description"
                  rows="2"
                  placeholder="What should the agent do with this thread?"
                ><%= @thread.description || "" %></textarea>
                <div class="prompt-actions">
                  <button class="subtle-button" type="submit" name="action" value="save" phx-disable-with="Saving…">Save task</button>
                  <button class="primary-button" type="submit" name="action" value="run" phx-disable-with="Dispatching…">Assign &amp; run</button>
                </div>
              </form>
            </div>
          </div>

        <% @thread.state in ~w(open running) -> %>
          <div class="controls-row working-row">
            <div class="working-indicator">
              <span class="wb-pulse-dot"></span>
              Agent working
            </div>
            <span class="muted controls-note">Cancel stops the run; the thread cannot be deployed until it parks on ask satisfied.</span>
          </div>

        <% @thread.state == "awaiting" -> %>
          <div class="controls-row awaiting-row">
            <div class="controls-block">
              <div class="controls-title-row">
                <h3 class="queue-title">Deploy the workspace</h3>
                <span class="muted controls-note">Emit the parked edits to the git delta receiver and submit a build.</span>
              </div>
              <button
                type="button"
                class="primary-button deploy-button"
                phx-click="deploy_intent"
                phx-value-id={@thread.id}
                data-confirm="Deploy this workspace (emit delta and submit build)?"
                disabled={not deployable_thread?(@thread)}
                title={if deployable_thread?(@thread), do: "Emit the parked workspace and submit a build", else: "Deploy needs a repo on the thread"}
              >Deploy &amp; build</button>
            </div>

            <div class="controls-block">
              <div class="controls-title-row">
                <h3 class="queue-title">Next prompt</h3>
                <span class="muted controls-note">Resumes the same parked agent session in this thread.</span>
              </div>
              <form class="prompt-form" phx-submit="send_prompt">
                <input type="hidden" name="thread_id" value={@thread.id} />
                <textarea
                  class="intent-form-input prompt-input"
                  name="description"
                  rows="2"
                  placeholder="Type the next prompt to resume this thread…"
                ></textarea>
                <div class="prompt-actions">
                  <button class="primary-button" type="submit" phx-disable-with="Sending…">Send</button>
                </div>
              </form>
            </div>
          </div>

          <div class="controls-row secondary-row">
            <button
              type="button"
              class="secondary"
              phx-click="close_thread"
              phx-value-id={@thread.id}
              data-confirm="Close this thread? The parked agent session will be stopped."
            >Close thread</button>
            <button
              type="button"
              class="subtle-button"
              phx-click="cancel_intent"
              phx-value-id={@thread.id}
              data-confirm="Cancel this thread?"
            >Cancel</button>
            <button type="button" class="subtle-button" phx-click="new_thread">Start new thread</button>
          </div>

        <% @phase && @phase.terminal -> %>
          <div class="controls-row terminal-row">
            <p class="empty-state">
              <%= if @thread.state == "done", do: "This thread is closed — its workspace was parked and the session stopped.", else: "This thread ended as #{@thread.state}." %>
            </p>
            <button type="button" class="primary-button" phx-click="new_thread">Start new thread</button>
          </div>

        <% true -> %>
      <% end %>
    </div>
    """
  end

  attr(:detail, :map, default: nil)
  attr(:expanded_run, :integer, default: nil)
  attr(:expanded_transcript, :list, default: [])
  attr(:now, :map, required: true)

  defp journal_block(assigns) do
    ~H"""
    <div class="journal-block">
      <h3 class="queue-title">Journal</h3>

      <%= cond do %>
        <% @detail == nil -> %>
          <p class="empty-state">Journal loading…</p>

        <% @detail[:error] -> %>
          <p class="empty-state">
            No journal detail for this thread yet — the run journal is disabled or nothing has been recorded.
          </p>

        <% true -> %>
          <div class="timeline">
            <%= for event <- journal_timeline(@detail) do %>
              <div class="timeline-item">
                <span class="timeline-time mono numeric" title={journal_field(event, "at") || ""}>
                  <%= rel_time(journal_field(event, "at"), @now) %>
                </span>
                <span class={timeline_badge_class(event)}>
                  <%= journal_event_label(journal_field(event, "event")) %>
                </span>
                <span class="timeline-summary event-text" title={journal_event_summary(event)}>
                  <%= journal_event_summary(event) %>
                </span>
              </div>
            <% end %>

            <%= if journal_timeline(@detail) == [] do %>
              <p class="empty-state compact">No journal events yet — activity appears as the agent runs.</p>
            <% end %>
          </div>

          <div class="journal-runs-block">
            <h3 class="queue-title">Runs</h3>
            <%= if @detail.runs == [] do %>
              <p class="empty-state compact">No run attempts recorded yet.</p>
            <% else %>
              <div class="journal-runs">
                <button
                  :for={run <- @detail.runs}
                  type="button"
                  class={run_chip_class(@expanded_run, run)}
                  phx-click="toggle_run_transcript"
                  phx-value-run={run.run_index}
                  title={"Run #{run.run_index}: #{run.status} · #{run.transcript_event_count} transcript events — click to expand"}
                >run <%= run.run_index %> — <%= run.status %></button>
              </div>
            <% end %>
          </div>

          <div class="transcript-block">
            <div class="transcript-head">
              <h3 class="queue-title">
                <%= if @expanded_run, do: "Transcript — run #{@expanded_run}", else: "Transcript — latest run tail" %>
              </h3>
              <span class="muted transcript-caption">
                <%= if @expanded_run, do: "refreshed live", else: "streaming tail, refreshed each second" %>
              </span>
            </div>

            <%= if current_transcript(@expanded_transcript, @expanded_run, @detail) == [] do %>
              <p class="empty-state compact">No agent transcript entries recorded for this run yet.</p>
            <% else %>
              <pre class="code-panel transcript-panel"><%= journal_transcript_panel(current_transcript(@expanded_transcript, @expanded_run, @detail), @now) %></pre>
            <% end %>
          </div>
      <% end %>
    </div>
    """
  end

  attr(:payload, :map, default: nil)
  attr(:runs, :map, default: nil)
  attr(:threads, :list, default: [])
  attr(:selected, :string, default: nil)
  attr(:collapsed, :map, default: nil)
  attr(:now, :map, required: true)

  defp system_drawer(assigns) do
    ~H"""
    <aside class={"wb-drawer" <> if collapsed?(@collapsed, "drawer"), do: "", else: " wb-drawer-open"}>
      <div class="drawer-head">
        <div>
          <span class="drawer-title">System</span>
          <span class="muted drawer-sub">running · blocked · limits · history</span>
        </div>
        <button type="button" class="collapse-toggle" phx-click="toggle_section" phx-value-key="drawer">Close</button>
      </div>

      <div class="drawer-body">
        <div class="ops-card">
          <h3 class="queue-title">Limits &amp; tokens</h3>
          <%= if @payload[:error] do %>
            <p class="empty-state">Snapshot unavailable.</p>
          <% else %>
            <div class="token-stack ops-tokens">
              <span>Total: <span class="mono numeric"><%= format_int(@payload.codex_totals.total_tokens) %></span></span>
              <span class="muted">
                In <span class="mono numeric"><%= format_int(@payload.codex_totals.input_tokens) %></span>
                / Out <span class="mono numeric"><%= format_int(@payload.codex_totals.output_tokens) %></span>
                · runtime <span class="mono numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></span>
              </span>
            </div>
            <%= if Map.get(@payload, :rate_limits) not in [nil, "n/a"] do %>
              <details class="ops-details">
                <summary>Rate limits</summary>
                <pre class="code-panel ops-pre"><%= pretty_value(@payload.rate_limits) %></pre>
              </details>
            <% else %>
              <p class="empty-state compact">No upstream rate-limit snapshot available.</p>
            <% end %>
          <% end %>
        </div>

        <div class="ops-card">
          <h3 class="queue-title">Running sessions</h3>
          <p class="ops-summary">Active agent sessions — last known activity and token usage.</p>
          <%= unless @payload[:error] do %>
            <%= if @payload.running == [] do %>
              <p class="empty-state">No active sessions.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table ops-table">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Runtime</th>
                      <th>Codex update</th>
                      <th>Tokens</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.running}>
                      <td>
                        <div class="issue-stack">
                          <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                          <%= if entry.session_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              data-label="Copy ID"
                              data-copy={entry.session_id}
                              onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                            >
                              Copy ID
                            </button>
                          <% else %>
                            <span class="muted">n/a</span>
                          <% end %>
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state)}>
                          <%= entry.state %>
                        </span>
                      </td>
                      <td class="numeric"><%= format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, @now)) %> · <%= entry.turn_count %> turns</td>
                      <td>
                        <div class="detail-stack">
                          <span class="event-text" title={entry.last_message || to_string(entry.last_event || "n/a")}>
                            <%= entry.last_message || to_string(entry.last_event || "n/a") %>
                          </span>
                          <span class="muted event-meta">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              · <span class="mono numeric" title={entry.last_event_at}><%= rel_time(entry.last_event_at, @now) %></span>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div class="token-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% else %>
            <p class="empty-state">Snapshot unavailable.</p>
          <% end %>
        </div>

        <div class="ops-card">
          <h3 class="queue-title">Blocked sessions</h3>
          <p class="ops-summary">Issues paused because Codex requested operator input or approval.</p>
          <%= unless @payload[:error] do %>
            <%= if @payload.blocked == [] do %>
              <p class="empty-state">No blocked sessions.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table ops-table">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Blocked at</th>
                      <th>Last update</th>
                      <th>Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.blocked}>
                      <td>
                        <div class="issue-stack">
                          <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state || "Blocked")}>
                          <%= entry.state || "Blocked" %>
                        </span>
                      </td>
                      <td class="mono numeric" title={entry.blocked_at || ""}><%= rel_time(entry.blocked_at, @now) %></td>
                      <td>
                        <div class="detail-stack">
                          <span class="event-text" title={entry.last_message || to_string(entry.last_event || "n/a")}>
                            <%= entry.last_message || to_string(entry.last_event || "n/a") %>
                          </span>
                          <span class="muted event-meta">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              · <span class="mono numeric" title={entry.last_event_at}><%= rel_time(entry.last_event_at, @now) %></span>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td><%= entry.error || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% else %>
            <p class="empty-state">Snapshot unavailable.</p>
          <% end %>
        </div>

        <div class="ops-card">
          <h3 class="queue-title">Retry queue</h3>
          <p class="ops-summary">Issues waiting for the next retry window.</p>
          <%= unless @payload[:error] do %>
            <%= if @payload.retrying == [] do %>
              <p class="empty-state">No issues are currently backing off.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table ops-table">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>Attempt</th>
                      <th>Due at</th>
                      <th>Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.retrying}>
                      <td>
                        <div class="issue-stack">
                          <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        </div>
                      </td>
                      <td><%= entry.attempt %></td>
                      <td class="mono numeric" title={entry.due_at || ""}><%= rel_time(entry.due_at, @now) %></td>
                      <td><%= entry.error || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% else %>
            <p class="empty-state">Snapshot unavailable.</p>
          <% end %>
        </div>

        <div class="ops-card">
          <h3 class="queue-title">Run history</h3>
          <p class="ops-summary">
            Durable journal of issue runs and agent sessions —
            <%= if @runs, do: "#{@runs.issue_count} issues", else: "0 issues" %>
            · <%= run_count(@runs) %> runs · <%= event_count(@runs) %> events.
          </p>

          <%= if @runs && @runs.enabled && @runs.issues != [] do %>
            <div class="table-wrap">
              <table class="data-table ops-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Status</th>
                    <th>Runs</th>
                    <th>Last event</th>
                    <th>Last at</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={run <- @runs.issues}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= run.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/issues/#{run.issue_identifier}/runs"}>history JSON</a>
                      </div>
                    </td>
                    <td>
                      <span class={run_status_badge_class(run.status)}>
                        <%= run.status %>
                      </span>
                    </td>
                    <td class="numeric"><%= run.run_count %></td>
                    <td>
                      <div class="detail-stack">
                        <span class="event-text" title={run.last_event || "n/a"}><%= run.last_event || "n/a" %></span>
                      </div>
                    </td>
                    <td class="mono numeric" title={run.last_at || ""}><%= rel_time(run.last_at, @now) %></td>
                    <td>
                      <%= if thread_for_id(@threads, run.issue_identifier) do %>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="toggle_issue_detail"
                          phx-value-id={run.issue_identifier}
                        ><%= if @selected == run.issue_identifier, do: "In seat", else: "Open thread" %></button>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% else %>
            <p class="empty-state">
              <%= if @runs && @runs.enabled, do: "No journaled runs yet.", else: "Run journal disabled (observability.run_journal_enabled)." %>
            </p>
          <% end %>
        </div>
      </div>
    </aside>
    """
  end

  # ── Payload / runs / intents loaders ────────────────────────────────────

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_runs do
    Presenter.runs_payload()
  end

  defp load_intents do
    case SymphonyElixir.Intents.IntentStore.list_intents() do
      {:ok, intents} -> intents
      {:error, _reason} -> []
    end
  end

  defp load_tracked_repos do
    try do
      case SymphonyElixir.TrackedRepos.fetch() do
        {:ok, repos} when is_list(repos) -> repos
        _ -> []
      end
    rescue
      _ -> []
    end
  end

  defp issue_detail_payload(identifier) do
    try do
      case Presenter.issue_runs_payload(identifier) do
        {:ok, detail} when is_map(detail) -> detail
        _ -> %{error: true}
      end
    rescue
      _ -> %{error: true}
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp state_filters, do: @state_filters

  # ── Display helpers (badges, chips, labels) ────────────────────────────

  defp intent_state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      normalized in ["awaiting"] -> "#{base} state-badge-awaiting wb-pulse"
      normalized in ["running", "open"] -> "#{base} state-badge-active"
      normalized in ["queued"] -> "#{base} state-badge-warning"
      normalized in ["done", "completed"] -> "#{base} state-badge-done"
      normalized in ["failed", "blocked", "cancelled"] -> "#{base} state-badge-danger"
      true -> base
    end
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp run_status_badge_class(status) do
    base = "state-badge"
    normalized = status |> to_string() |> String.downcase()

    cond do
      normalized in ["running"] -> "#{base} state-badge-active"
      normalized in ["done", "completed"] -> "#{base} state-badge-active"
      normalized in ["failed", "blocked"] -> "#{base} state-badge-danger"
      true -> base
    end
  end

  defp thread_row_class(selected, intent) do
    base = "thread-row"
    if selected == intent.id, do: "#{base} thread-row-active", else: base
  end

  defp phase_chips(nil), do: []

  defp phase_chips(%{chips: chips}) when is_list(chips), do: chips

  defp phase_chips(_phase), do: []

  defp phase_step_class(%{key: key, status: :active}) when key in [:awaiting] do
    "phase-step phase-step-active phase-step-awaiting-active"
  end

  defp phase_step_class(%{key: key, status: :active}) when key in [:running, :verifying] do
    "phase-step phase-step-active phase-step-live"
  end

  defp phase_step_class(%{status: :active}), do: "phase-step phase-step-active"
  defp phase_step_class(%{status: :done}), do: "phase-step phase-step-done"
  defp phase_step_class(%{status: :todo}), do: "phase-step"

  defp phase_terminal_class(state) do
    case state do
      "done" -> "state-badge state-badge-done"
      "failed" -> "state-badge state-badge-danger"
      "cancelled" -> "state-badge state-badge-warning"
      _ -> "state-badge"
    end
  end

  defp deployable_thread?(%{repo: repo, state: state}) do
    state == "awaiting" and is_binary(repo) and repo != ""
  end

  defp deployable_thread?(_thread), do: false

  defp timeline_badge_class(event) do
    "state-badge timeline-badge " <> journal_event_badge_base(journal_field(event, "event"))
  end

  defp journal_event_badge_base(event) when is_binary(event) do
    case event do
      "run_started" -> "state-badge-active"
      "job_started" -> "state-badge-active"
      "verification_started" -> "state-badge-warning"
      "verify_unclear" -> "state-badge-warning"
      "run_finished" -> "state-badge-done"
      "issue_terminal" -> "state-badge-done"
      "job_finished" -> "state-badge-done"
      "build_succeeded" -> "state-badge-done"
      "verify_passed" -> "state-badge-done"
      "verify_failed" -> "state-badge-danger"
      "delta_emitted" -> "state-badge-warning"
      "build_submitted" -> "state-badge-warning"
      _ -> ""
    end
  end

  defp journal_event_badge_base(_event), do: ""

  defp journal_event_label(event) when is_binary(event) do
    case event do
      "run_started" -> "run started"
      "run_finished" -> "run finished"
      "issue_terminal" -> "issue terminal"
      "delta_emitted" -> "delta emitted"
      "build_submitted" -> "build submitted"
      "job_started" -> "job started"
      "job_finished" -> "job finished"
      "build_succeeded" -> "build succeeded"
      "verification_started" -> "verification started"
      "verify_passed" -> "verify passed"
      "verify_failed" -> "verify failed"
      "verify_unclear" -> "verify unclear"
      other -> other
    end
  end

  defp journal_event_label(_event), do: "event"

  defp journal_event_summary(event) when is_map(event) do
    case journal_field(event, "event") do
      "run_started" ->
        run = journal_field(event, "run_index") || "?"
        worker = journal_field(event, "worker_host") || "n/a"
        "run #{run} started (worker #{worker})"

      "run_finished" ->
        run = journal_field(event, "run_index") || "?"
        status = journal_field(event, "status") || "finished"
        "run #{run} #{status} (#{journal_duration_ms(event)})"

      "delta_emitted" ->
        head = head12(journal_field(event, "head")) || "?"
        image = journal_field(event, "image") || journal_field(event, "repo") || "?"
        "delta → #{head} #{image}"

      "build_submitted" ->
        "build submitted #{journal_field(event, "image") || "?"}"

      "job_started" ->
        "watch job #{journal_field(event, "job_id") || "?"} running"

      "job_finished" ->
        "watch job #{journal_field(event, "job_id") || "?"} #{journal_field(event, "state") || "finished"}"

      "build_succeeded" ->
        "image #{journal_field(event, "image") || "?"}:#{journal_field(event, "tag") || "?"} published"

      "verification_started" ->
        head = head12(journal_field(event, "head"))
        verify = journal_field(event, "verify_intent")
        has_verify = is_binary(verify) and verify != ""
        has_head = is_binary(head) and head != ""

        "verification started" <>
          (if has_verify, do: " (verify #{short_id(verify)}", else: "") <>
          (if has_head, do: " · #{head}", else: "") <>
          (if has_verify or has_head, do: ")", else: "")

      "verify_passed" ->
        verdict_summary(event, "passed")

      "verify_failed" ->
        verdict_summary(event, "failed")

      "verify_unclear" ->
        verdict_summary(event, "unclear")

      name when is_binary(name) ->
        name

      _ ->
        "event"
    end
  end

  defp journal_event_summary(_event), do: "event"

  defp verdict_summary(event, verb) do
    evidence = journal_field(event, "evidence") || ""
    verdict = journal_field(event, "verdict") || verb

    "verification #{verb} (#{verdict})" <>
      if evidence == "", do: "", else: " — #{truncate_text(one_line(evidence), 140)}"
  end

  defp one_line(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp one_line(_other), do: ""

  defp verdict_bar_class(event) do
    base = "verdict-bar"

    case journal_field(event, "event") do
      "verify_passed" -> "#{base} verdict-bar-passed"
      "verify_failed" -> "#{base} verdict-bar-failed"
      "verify_unclear" -> "#{base} verdict-bar-unclear"
      _ -> base
    end
  end

  defp verdict_head_class(event) do
    case journal_field(event, "event") do
      "verify_passed" -> "verdict-label verdict-label-passed"
      "verify_failed" -> "verdict-label verdict-label-failed"
      "verify_unclear" -> "verdict-label verdict-label-unclear"
      _ -> "verdict-label"
    end
  end

  defp verdict_head_label(event) do
    case journal_field(event, "event") do
      "verify_passed" -> "Verification passed"
      "verify_failed" -> "Verification failed"
      "verify_unclear" -> "Verification unclear"
      _ -> "Verification"
    end
  end

  defp verdict_evidence(event) do
    evidence = journal_field(event, "evidence") || ""

    if evidence == "" do
      "No evidence was recorded for this verdict."
    else
      truncate_text(evidence, 400)
    end
  end

  defp journal_duration_ms(event) do
    case journal_field(event, "duration_ms") do
      ms when is_integer(ms) -> "#{ms}ms"
      _ -> "-"
    end
  end

  defp head12(head) when is_binary(head), do: String.slice(head, 0, 12)
  defp head12(_head), do: nil

  defp run_chip_class(expanded_run, run) do
    base = "state-badge run-chip"

    if expanded_run == run.run_index do
      "#{base} run-chip-active"
    else
      base
    end
  end

  defp current_transcript(expanded_transcript, expanded_run, detail) do
    if expanded_run do
      expanded_transcript
    else
      case detail do
        %{transcript: transcript} when is_list(transcript) -> transcript
        _ -> []
      end
    end
  end

  defp journal_timeline(nil), do: []

  defp journal_timeline(%{events: events}) when is_list(events) do
    events
    |> Enum.reverse()
    |> Enum.take(300)
  end

  defp journal_timeline(_detail), do: []

  defp journal_transcript_panel(transcript, now) when is_list(transcript) do
    transcript
    |> Enum.map(&journal_transcript_line(&1, now))
    |> Enum.join("\n")
  end

  defp journal_transcript_panel(_transcript, _now), do: ""

  defp journal_transcript_line(entry, now) when is_map(entry) do
    at = rel_time(journal_field(entry, "at"), now)
    event = journal_field(entry, "event") || "agent"

    message =
      entry
      |> journal_field("message")
      |> journal_message_text()
      |> truncate_text(400)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if message == "", do: "#{at}  #{event}", else: "#{at}  #{event}: #{message}"
  end

  defp journal_transcript_line(_entry, _now), do: ""

  defp journal_message_text(message) when is_binary(message), do: message
  defp journal_message_text(nil), do: ""
  defp journal_message_text(other), do: inspect(other, pretty: false, limit: :infinity)

  defp journal_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, to_string(key))
      value -> value
    end
  end

  defp journal_field(_map, _key), do: nil

  # ── Filtering / counting ────────────────────────────────────────────────

  defp thread_count(threads, "all"), do: length(threads)

  defp thread_count(threads, state) do
    Enum.count(threads, &(&1.state == state))
  end

  defp verify_count(intents) do
    intents
    |> Enum.count(&(verify_intent?(&1) and &1.state in ~w(queued open running awaiting)))
  end

  defp payload_count(%{counts: counts}, key) when is_map(counts) do
    Map.get(counts, key, 0)
  end

  defp payload_count(_payload, _key), do: 0

  defp payload_tokens(%{codex_totals: totals}) when is_map(totals) do
    format_int(Map.get(totals, :total_tokens))
  end

  defp payload_tokens(_payload), do: "n/a"

  defp runtime_summary(%{codex_totals: _totals} = payload, now) do
    format_runtime_seconds(total_runtime_seconds(payload, now))
  rescue
    _ -> "n/a"
  end

  defp runtime_summary(_payload, _now), do: "n/a"

  defp ops_count(payload) do
    running = payload_count(payload, :running)
    blocked = payload_count(payload, :blocked)
    retrying = payload_count(payload, :retrying)

    if running + blocked + retrying == 0 do
      nil
    else
      to_string(running + blocked + retrying)
    end
  end

  defp displayed_threads(threads, "all"), do: threads

  defp displayed_threads(threads, state) do
    Enum.filter(threads, &(&1.state == state))
  end

  defp oldest_operator_wait(threads, now) do
    threads
    |> Enum.filter(&(&1.state == "awaiting"))
    |> Enum.map(&intent_stamp/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&DateTime.to_unix/1)
    |> case do
      [] -> "none"
      [oldest | _] -> rel_time(oldest, now)
    end
  end

  defp operator_load_class(0), do: "operator-load"
  defp operator_load_class(_count), do: "operator-load operator-load-hot"

  defp lane_card_class(0), do: "lane-card"
  defp lane_card_class(_count), do: "lane-card lane-card-active"

  defp lane_card_class(0, extra_class), do: "lane-card #{extra_class}"
  defp lane_card_class(_count, extra_class), do: "lane-card lane-card-active #{extra_class}"

  defp run_count(%{issues: issues}) when is_list(issues) do
    Enum.reduce(issues, 0, fn issue, acc -> acc + issue.run_count end)
  end

  defp run_count(_runs), do: 0

  defp event_count(%{issues: issues}) when is_list(issues) do
    Enum.reduce(issues, 0, fn issue, acc -> acc + issue.event_count end)
  end

  defp event_count(_runs), do: 0

  # ── Time / formatting ───────────────────────────────────────────────────

  defp intent_sort_epoch(intent) do
    case intent_stamp(intent) do
      %DateTime{} = datetime -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end

  defp intent_stamp(intent) do
    (intent.updated_at || intent.created_at)
    |> parse_datetime()
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp rel_time(nil, _now), do: "n/a"

  defp rel_time(value, now) when is_binary(value) do
    case parse_datetime(value) do
      nil -> value
      datetime -> rel_time(datetime, now)
    end
  end

  defp rel_time(%DateTime{} = datetime, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, datetime, :second), 0)

    cond do
      seconds < 5 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h #{rem(div(seconds, 60), 60)}m ago"
      seconds < 7 * 86_400 -> "#{div(seconds, 86_400)}d #{rem(div(seconds, 86_400), 3_600)}h ago"
      true -> to_string(DateTime.to_date(datetime))
    end
  end

  defp clock(%DateTime{} = now) do
    "#{String.pad_leading(to_string(now.hour), 2, "0")}:#{String.pad_leading(to_string(now.minute), 2, "0")}:#{String.pad_leading(to_string(now.second), 2, "0")}"
  end

  defp clock(_now), do: "--:--:--"

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp short_repo(nil), do: "n/a"
  defp short_repo(""), do: "n/a"

  defp short_repo(repo) when is_binary(repo) do
    repo_slug(repo)
  end

  defp short_repo(_repo), do: "n/a"

  defp truncate_text(text, limit) when is_binary(text) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "…", else: text
  end

  defp truncate_text(_other, _limit), do: "n/a"

  defp collapsed?(collapsed, key) do
    MapSet.member?(collapsed, key)
  end

  defp notice_class(:success), do: "notice notice-success"
  defp notice_class(:error), do: "notice notice-error"
  defp notice_class(_other), do: "notice"

  defp filter_chip_class(filter, state) do
    base = "filter-chip"
    if filter == state, do: "#{base} filter-chip-active", else: base
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  # ── Components ──────────────────────────────────────────────────────────

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil
end
