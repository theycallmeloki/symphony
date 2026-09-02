defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()
    intents = load_intents()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:runs, load_runs())
      |> assign(:now, DateTime.utc_now())
      |> assign(:intents, intents)
      |> assign(:notice, nil)
      |> assign(:notice_timer, nil)
      |> assign(:intents_filter, "all")
      |> assign(:collapsed, default_collapsed(payload))
      |> assign(:selected_detail, nil)
      |> assign(:detail, nil)
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

    socket =
      socket
      |> assign(:now, DateTime.utc_now())
      |> maybe_refresh_detail()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:runs, load_runs())
     |> assign(:intents, load_intents())
     |> assign(:tracked_repos, load_tracked_repos())
     |> assign(:now, DateTime.utc_now())}
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
         |> put_notice(:success, "Intent #{short_id(intent.id)} registered — dispatched.")
         |> refresh_intents()}

      {:error, {:missing_field, field}} ->
        {:noreply, put_notice(socket, :error, "Missing required field: #{field}")}

      {:error, reason} ->
        {:noreply, put_notice(socket, :error, "Could not register intent: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_intent", %{"id" => id}, socket) when is_binary(id) do
    case SymphonyElixir.Intents.IntentStore.cancel_intent(id) do
      {:ok, _intent} ->
        {:noreply,
         socket
         |> put_notice(:success, "Intent #{short_id(id)} cancelled.")
         |> refresh_intents()}

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
    if socket.assigns.selected_detail == id do
      {:noreply, assign(socket, selected_detail: nil, detail: nil)}
    else
      {:noreply, assign(socket, selected_detail: id, detail: issue_detail_payload(id))}
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
             |> refresh_intents()}

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
             |> refresh_intents()}

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

  defp refresh_intents(socket) do
    assign(socket, :intents, load_intents())
  end

  defp short_id(id) when is_binary(id) do
    case String.split(id, "-") do
      [_prefix, _ts, suffix] -> "int-…#{suffix}"
      _ -> id
    end
  end

  defp short_id(id), do: to_string(id)

  defp default_collapsed(payload) do
    MapSet.new()
    |> maybe_collapse(payload, :rate_limits, &(Map.get(&1, :rate_limits) in [nil, "n/a"]))
    |> maybe_collapse(payload, :running, fn p -> Map.get(p, :running) in [nil, []] end)
    |> maybe_collapse(payload, :blocked, fn p -> Map.get(p, :blocked) in [nil, []] end)
    |> maybe_collapse(payload, :retrying, fn p -> Map.get(p, :retrying) in [nil, []] end)
  end

  defp maybe_collapse(set, payload, key, when_collapsed?) do
    if when_collapsed?.(payload), do: MapSet.put(set, to_string(key)), else: set
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Job queue, agent runs, retry pressure, and token usage for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

      <% end %>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Intents &amp; job queue</h2>
            <p class="section-copy">
              Queue repos or dispatch single jobs, then watch them run. Queued
              jobs wait here until you assign a task and run them; open jobs are
              picked up by the orchestrator automatically.
            </p>
          </div>
          <div class="section-summary">
            <span class={intent_state_badge_class("queued")}><%= count_state(@intents, "queued") %> queued</span>
            <span class={intent_state_badge_class("running")}><%= count_state(@intents, "open") + count_state(@intents, "running") %> active</span>
          </div>
        </div>

        <%= if @notice do %>
          <p class={notice_class(@notice.kind)} role="status">
            <%= @notice.text %>
            <button type="button" class="notice-dismiss" phx-click="dismiss_notice" aria-label="Dismiss">×</button>
          </p>
        <% end %>

        <div class="intent-forms-grid">
          <form class="intent-form" phx-submit="register_intent">
            <h3 class="queue-title">New job</h3>
            <label class="intent-form-field">
              <span>Title</span>
              <input class="intent-form-input" type="text" name="title" required placeholder="e.g. Publish release notes" />
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
              <span>Description</span>
              <textarea
                class="intent-form-input"
                name="description"
                rows="2"
                placeholder="What the agent should accomplish for this job."
              ></textarea>
            </label>
            <div>
              <button class="primary-button" type="submit" phx-disable-with="Registering…">Register job</button>
            </div>
          </form>

          <form class="intent-form" phx-submit="queue_repos">
            <h3 class="queue-title">Queue repositories</h3>
            <p class="form-hint">One URL or owner/name per line — comma or newline separated. Each becomes a queued job awaiting a task.</p>
            <label class="intent-form-field">
              <span>Repos</span>
              <textarea
                class="intent-form-input"
                name="repos"
                rows="4"
                placeholder={"e.g.\ngit@github.com:theycallmeloki/sandman.git\nhttps://github.com/theycallmeloki/symphony.git"}
              ></textarea>
            </label>
            <div>
              <button class="primary-button" type="submit" phx-disable-with="Queuing…">Queue repos as intents</button>
            </div>
          </form>
        </div>

        <div class="queue-chips">
          <h3 class="queue-title">Tracked on sandman</h3>
          <p class="form-hint">
            Repos with a build-bus watch pipeline on the control plane — click a chip to queue a repo job against its latest mirror.
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
                phx-value-repo={tracked.repo}
                phx-value-state={tracked.watch_state}
                title={"Queue a repo job against #{tracked.repo} (watch pipeline #{tracked.watch_pipeline} — #{tracked.watch_state})"}
              >
                <span><%= tracked.repo %></span>
                <span class="chip-count"><%= tracked.watch_state %></span>
              </button>
            </div>
          <% end %>
        </div>

        <div class="queue-block">
          <h3 class="queue-title">Queued — waiting for a task</h3>

          <%= if count_state(@intents, "queued") == 0 do %>
            <p class="empty-state">Nothing queued. Paste repo references in the queue form above, or click a tracked repo above to queue a repo job.</p>
          <% else %>
            <div class="queue-list">
              <%= for intent <- queued_intents(@intents) do %>
                <div class="queue-card">
                  <div class="queue-card-head">
                    <div class="issue-stack">
                      <span class="issue-id"><%= short_id(intent.id) %></span>
                      <span class="intent-title" title={intent.repo || intent.title}><%= intent.title %></span>
                      <span class="muted queue-repo"><%= short_repo(intent.repo) %></span>
                    </div>
                    <div class="queue-card-actions">
                      <form class="queue-task-form" phx-submit="queued_task">
                        <input type="hidden" name="intent_id" value={intent.id} />
                        <textarea
                          class="intent-form-input queue-task-input"
                          name="description"
                          rows="1"
                          placeholder="What should the agent do with this repo?"
                        ><%= intent.description %></textarea>
                        <button class="subtle-button" type="submit" name="action" value="save" phx-disable-with="Saving…">Save task</button>
                        <button class="primary-button" type="submit" name="action" value="run" phx-disable-with="Dispatching…">Assign &amp; run</button>
                      </form>
                      <button
                        type="button"
                        class="subtle-button"
                        phx-click="cancel_intent"
                        phx-value-id={intent.id}
                        data-confirm="Remove this queued job?"
                      >Remove</button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <div class="intent-history">
          <div class="history-head">
            <h3 class="queue-title">Activity</h3>
            <div class="filter-row">
              <button
                type="button"
                class={filter_chip_class(@intents_filter, "all")}
                phx-click="filter_intents"
                phx-value-state="all"
              >All <span class="chip-count"><%= nonqueued_count(@intents) %></span></button>
              <button
                :for={{state, label} <- [{"open", "Open"}, {"running", "Running"}, {"done", "Done"}, {"failed", "Failed"}, {"cancelled", "Cancelled"}]}
                type="button"
                class={filter_chip_class(@intents_filter, state)}
                phx-click="filter_intents"
                phx-value-state={state}
              ><%= label %> <span class="chip-count"><%= count_state(@intents, state) %></span></button>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table data-table-intents">
              <thead>
                <tr>
                  <th>Job</th>
                  <th>State</th>
                  <th>Repo</th>
                  <th>Outcome</th>
                  <th>Updated</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for intent <- displayed_intents(@intents, @intents_filter) do %>
                <tr>
                  <td>
                    <div class="issue-stack">
                      <span class="issue-id"><%= short_id(intent.id) %></span>
                      <span class="intent-title" title={intent.description || intent.title}><%= intent.title %></span>
                      <a class="issue-link" href={"/api/v1/intents/#{intent.id}"}>JSON details</a>
                    </div>
                  </td>
                  <td>
                    <span class={intent_state_badge_class(intent.state)}>
                      <%= intent.state %>
                    </span>
                  </td>
                  <td><%= short_repo(intent.repo) %></td>
                  <td>
                    <div class="detail-stack">
                      <span class="event-text" title={intent_result_summary(intent)}>
                        <%= intent_result_summary(intent) %>
                      </span>
                    </div>
                  </td>
                  <td>
                    <span class="mono numeric" title={intent_stamp(intent) || ""}><%= rel_time(intent_stamp(intent), @now) %></span>
                  </td>
                  <td>
                    <%= if intent.state in ["open", "running"] do %>
                      <button
                        type="button"
                        class="subtle-button"
                        phx-click="cancel_intent"
                        phx-value-id={intent.id}
                        data-confirm="Cancel this job?"
                      >Cancel</button>
                    <% end %>
                  </td>
                </tr>
                <% end %>
                <%= if nonqueued_count(@intents) == 0 or (displayed_intents(@intents, @intents_filter) == []) do %>
                  <tr>
                    <td colspan="6" class="empty-state">No <%= if @intents_filter == "all", do: "", else: "#{@intents_filter} " %>jobs yet.</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <%= unless @payload[:error] do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
            <button type="button" class="collapse-toggle" phx-click="toggle_section" phx-value-key="rate_limits">
              <%= if collapsed?(@collapsed, "rate_limits"), do: "Expand", else: "Collapse" %>
            </button>
          </div>

          <%= if collapsed?(@collapsed, "rate_limits") do %>
            <p class="collapse-summary mono"><%= truncate_text(pretty_value(@payload.rate_limits), 150) %></p>
          <% else %>
            <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
            <div class="section-tools">
              <%= if @payload.running != [] do %>
                <span class="collapse-count state-badge state-badge-active"><%= length(@payload.running) %> running</span>
              <% end %>
              <button type="button" class="collapse-toggle" phx-click="toggle_section" phx-value-key="running">
                <%= if collapsed?(@collapsed, "running"), do: "Expand", else: "Collapse" %>
              </button>
            </div>
          </div>

          <%= if collapsed?(@collapsed, "running") do %>
            <p class="collapse-summary"><%= section_summary(@payload.running, "No active sessions.", "session", "Active sessions:") %></p>
          <% else %>
            <%= if @payload.running == [] do %>
              <p class="empty-state">No active sessions.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-running">
                  <colgroup>
                    <col style="width: 12rem;" />
                    <col style="width: 7.5rem;" />
                    <col style="width: 7rem;" />
                    <col style="width: 8rem;" />
                    <col />
                    <col style="width: 9.5rem;" />
                  </colgroup>
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Session</th>
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
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state)}>
                          <%= entry.state %>
                        </span>
                      </td>
                      <td>
                        <div class="session-stack">
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
                      <td class="numeric"><%= format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, @now)) %> · <%= entry.turn_count %> turns</td>
                      <td>
                        <div class="detail-stack">
                          <span
                            class="event-text"
                            title={entry.last_message || to_string(entry.last_event || "n/a")}
                          ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
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
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
            <button type="button" class="collapse-toggle" phx-click="toggle_section" phx-value-key="blocked">
              <%= if collapsed?(@collapsed, "blocked"), do: "Expand", else: "Collapse" %>
            </button>
          </div>

          <%= if collapsed?(@collapsed, "blocked") do %>
            <p class="collapse-summary"><%= section_summary(@payload.blocked, "No blocked sessions.", "session", "Blocked:") %></p>
          <% else %>
            <%= if @payload.blocked == [] do %>
              <p class="empty-state">No blocked sessions.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table" style="min-width: 760px;">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Session</th>
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
                      <td>
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
                      </td>
                      <td class="mono numeric" title={entry.blocked_at || ""}><%= rel_time(entry.blocked_at, @now) %></td>
                      <td>
                        <div class="detail-stack">
                          <span
                            class="event-text"
                            title={entry.last_message || to_string(entry.last_event || "n/a")}
                          ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
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
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
            <button type="button" class="collapse-toggle" phx-click="toggle_section" phx-value-key="retrying">
              <%= if collapsed?(@collapsed, "retrying"), do: "Expand", else: "Collapse" %>
            </button>
          </div>

          <%= if collapsed?(@collapsed, "retrying") do %>
            <p class="collapse-summary"><%= section_summary(@payload.retrying, "No issues are currently backing off.", "issue", "Backing off:") %></p>
          <% else %>
            <%= if @payload.retrying == [] do %>
              <p class="empty-state">No issues are currently backing off.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table" style="min-width: 680px;">
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
          <% end %>
        </section>
      <% end %>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Run history</h2>
            <p class="section-copy">
              Durable journal of issue runs and agent sessions —
              <%= @runs.issue_count %> issues tracked.
            </p>
          </div>
        </div>

        <%= if @runs.enabled and @runs.issues != [] do %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 820px;">
              <colgroup>
                <col style="width: 12rem;" />
                <col style="width: 8rem;" />
                <col style="width: 5rem;" />
                <col style="width: 6rem;" />
                <col style="width: 11rem;" />
                <col />
                <col style="width: 6.5rem;" />
              </colgroup>
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Status</th>
                  <th>Runs</th>
                  <th>Events</th>
                  <th>Last event</th>
                  <th>Last at</th>
                  <th>Detail</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={run <- @runs.issues}>
                  <td>
                    <div class="issue-stack">
                      <span class="issue-id"><%= run.issue_identifier %></span>
                      <a
                        class="issue-link"
                        href={"/api/v1/issues/#{run.issue_identifier}/runs"}
                      >history JSON</a>
                    </div>
                  </td>
                  <td>
                    <span class={run_status_badge_class(run.status)}>
                      <%= run.status %>
                    </span>
                  </td>
                  <td class="numeric"><%= run.run_count %></td>
                  <td class="numeric"><%= run.event_count %></td>
                  <td>
                    <div class="detail-stack">
                      <span class="event-text" title={run.last_event || "n/a"}><%= run.last_event || "n/a" %></span>
                    </div>
                  </td>
                  <td class="mono numeric" title={run.last_at || ""}><%= rel_time(run.last_at, @now) %></td>
                  <td>
                    <button
                      type="button"
                      class="subtle-button"
                      phx-click="toggle_issue_detail"
                      phx-value-id={run.issue_identifier}
                    ><%= if @selected_detail == run.issue_identifier, do: "Close", else: "Detail" %></button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% else %>
          <p class="empty-state">
            <%= if @runs.enabled, do: "No journaled runs yet.", else: "Run journal disabled (observability.run_journal_enabled)." %>
          </p>
        <% end %>
      </section>

      <%= if @selected_detail do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Job detail — <span class="mono"><%= @selected_detail %></span></h2>
              <p class="section-copy">
                Live journal for this job: events, run attempts, and the latest agent transcript tail.
              </p>
            </div>
            <button
              type="button"
              class="subtle-button"
              phx-click="toggle_issue_detail"
              phx-value-id={@selected_detail}
            >Close</button>
          </div>

          <%= if @detail[:error] do %>
            <p class="empty-state">
              No journal detail for this job yet — the run journal is disabled or nothing has been recorded.
            </p>
          <% else %>
            <div class="queue-block">
              <h3 class="queue-title">Events</h3>
              <div class="table-wrap">
                <table class="data-table data-table-journal">
                  <colgroup>
                    <col style="width: 6.5rem;" />
                    <col style="width: 12rem;" />
                    <col />
                  </colgroup>
                  <thead>
                    <tr>
                      <th>At</th>
                      <th>Event</th>
                      <th>Detail</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={event <- @detail.events}>
                      <td class="mono numeric" title={journal_field(event, "at") || ""}>
                        <%= rel_time(journal_field(event, "at"), @now) %>
                      </td>
                      <td>
                        <span class={journal_event_badge_class(journal_field(event, "event"))}>
                          <%= journal_field(event, "event") || "event" %>
                        </span>
                      </td>
                      <td>
                        <span class="event-text" title={journal_event_summary(event)}>
                          <%= journal_event_summary(event) %>
                        </span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>

            <div class="queue-block">
              <h3 class="queue-title">Runs</h3>
              <%= if @detail.runs == [] do %>
                <p class="empty-state">No run attempts recorded for this job yet.</p>
              <% else %>
                <div class="journal-runs">
                  <span
                    :for={run <- @detail.runs}
                    class={run_status_badge_class(run.status)}
                    title={"Run #{run.run_index}: #{run.status} · #{run.transcript_event_count} transcript events"}
                  >run <%= run.run_index %> — <%= run.status %></span>
                </div>
              <% end %>
            </div>

            <div class="queue-block">
              <h3 class="queue-title">Transcript tail</h3>
              <%= if @detail.transcript == [] do %>
                <p class="empty-state">No agent transcript entries recorded for the latest run yet.</p>
              <% else %>
                <pre class="code-panel"><%= journal_transcript_panel(@detail.transcript, @now) %></pre>
              <% end %>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

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

  defp intent_state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      normalized in ["running", "open"] -> "#{base} state-badge-active"
      normalized in ["queued"] -> "#{base} state-badge-warning"
      normalized in ["done", "completed"] -> "#{base} state-badge-done"
      normalized in ["failed", "blocked", "cancelled"] -> "#{base} state-badge-danger"
      true -> base
    end
  end

  defp intent_result_summary(%{state: state, result: result}) when is_map(result) do
    status = Map.get(result, "status") || Map.get(result, :status)

    cond do
      is_binary(status) and status == "completed" -> "run completed"
      is_binary(status) and status == "blocked" -> "blocked"
      is_binary(status) and status == "failed" -> "run failed"
      state == "cancelled" -> "cancelled"
      true -> ""
    end
  end

  defp intent_result_summary(%{state: state}) when state in ["open", "running"] do
    case state do
      "running" -> "in flight"
      _ -> "waiting for dispatch"
    end
  end

  defp intent_result_summary(%{state: "cancelled"}), do: "cancelled"
  defp intent_result_summary(_intent), do: ""

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

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

  defp count_state(intents, state) do
    Enum.count(intents, &(&1.state == state))
  end

  defp nonqueued_count(intents) do
    Enum.count(intents, &(&1.state != "queued"))
  end

  defp queued_intents(intents) do
    intents
    |> Enum.filter(&(&1.state == "queued"))
    |> Enum.sort_by(&intent_sort_epoch/1, :desc)
  end

  defp displayed_intents(intents, "all") do
    intents
    |> Enum.filter(&(&1.state != "queued"))
    |> Enum.sort_by(&intent_sort_epoch/1, :desc)
  end

  defp displayed_intents(intents, state) do
    intents
    |> Enum.filter(&(&1.state == state))
    |> Enum.sort_by(&intent_sort_epoch/1, :desc)
  end

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

  defp section_summary(list, empty_text, _noun, prefix) when is_list(list) do
    case length(list) do
      0 -> empty_text
      count -> "#{prefix} #{count}"
    end
  end

  defp section_summary(_other, empty_text, _noun, _prefix), do: empty_text

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  # ── Tracked repos (sandman watch pipelines) ──────────────────────────────

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

  # ── Per-job detail panel ─────────────────────────────────────────────────

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

  defp maybe_refresh_detail(socket) do
    case socket.assigns.selected_detail do
      nil -> socket
      id -> assign(socket, :detail, issue_detail_payload(id))
    end
  end

  defp journal_event_badge_class(event) when is_binary(event) do
    base = "state-badge"

    case event do
      "run_started" -> "#{base} state-badge-active"
      "job_started" -> "#{base} state-badge-active"
      "run_finished" -> "#{base} state-badge-done"
      "issue_terminal" -> "#{base} state-badge-done"
      "job_finished" -> "#{base} state-badge-done"
      "build_succeeded" -> "#{base} state-badge-done"
      "delta_emitted" -> "#{base} state-badge-warning"
      "build_submitted" -> "#{base} state-badge-warning"
      _ -> base
    end
  end

  defp journal_event_badge_class(_event), do: "state-badge"

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

      name when is_binary(name) ->
        name

      _ ->
        "event"
    end
  end

  defp journal_event_summary(_event), do: "event"

  defp journal_duration_ms(event) do
    case journal_field(event, "duration_ms") do
      ms when is_integer(ms) -> "#{ms}ms"
      _ -> "-"
    end
  end

  defp head12(head) when is_binary(head), do: String.slice(head, 0, 12)
  defp head12(_head), do: nil

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
end
