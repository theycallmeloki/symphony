defmodule SymphonyElixir.BuildFusion do
  @moduledoc """
  Polls sandman build jobs and the container registry to journal build
  lifecycle events (`job_started`, `job_finished`, `build_succeeded`) into
  the per-issue run journal (`RunJournal`).

  A build is tracked per issue with `track/6`. Every tick (`observability
  .build_events_interval_ms`) each pending entry is reconciled against the
  sandman jobs API — looking for a job on the issue's watch pipeline (the
  image name plus `-watch`, overridable via `SANDMAN_WATCH_PIPELINE`) whose
  `inputCommits` contain the tracked head — and against the container
  registry's tag list for the 12-character short head. Events are journaled
  once each: jobs are finished exactly once when they reach a terminal state
  (`success | failure | killed | error`), and the entry is pruned once the
  image is published or after the staleness windows (20 minutes past job
  completion, 60 minutes unconditionally).

  The process only runs when build events are enabled
  (`observability.build_events_enabled`) and a sandman control plane is
  configured (`SANDMAN_ADDR`); otherwise it stays idle and `track/6` is a
  no-op. Because more than one runtime supervisor can coexist in tests (where
  sandman is never configured), the process registers its `__MODULE__` name
  only while active, so idle instances never contend for it.

  The polling logic lives in `reconcile/3`, which is pure: fetchers and the
  journal function are injected so the unit tests never touch the network or
  the journal.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, RepoDelta, RunJournal}

  @default_registry "miladyosregistry.transparentlyrotatableproxy.site"
  @watch_pipeline_env "SANDMAN_WATCH_PIPELINE"
  @http_timeout_ms 15_000
  @job_done_prune_minutes 20
  @max_prune_minutes 60
  @terminal_states ~w(success failure killed error)

  @type entry :: %{
          repo: String.t(),
          branch: String.t(),
          image: String.t(),
          registry: String.t() | nil,
          head: String.t(),
          # the thread's current ask; needed to build the auto-verify prompt
          description: String.t() | nil,
          jobs: MapSet.t(),
          job_done: boolean(),
          built: boolean(),
          verify_started: boolean(),
          tracked_at: DateTime.t() | nil
        }

  # ── Client API ──────────────────────────────────────────────────────────

  @doc "Default container registry host used when none is configured."
  @spec default_registry() :: String.t()
  def default_registry, do: @default_registry

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start tracking a build for an issue (async). `repo_url` is the git clone
  URL, `head` the commit under build; `registry` defaults to the configured
  `observability.build_events_registry` or `default_registry/0` when nil.
  `description` (the thread's current ask) enables the auto-verify pass on
  build success. Lifecycle events are journaled as the build progresses.
  No-op while the process is idle (build events disabled or no sandman
  control plane).
  """
  @spec track(String.t(), String.t(), String.t(), String.t(), String.t() | nil, String.t(), String.t() | nil) ::
          :ok
  def track(issue_identifier, repo_url, branch, image, registry, head, description \\ nil) do
    GenServer.cast(__MODULE__, {:track, issue_identifier, repo_url, branch, image, registry, head, description})
  end

  # ── Pure reconcile core ─────────────────────────────────────────────────

  @doc """
  Reconcile one pending entry against the sandman jobs list and the registry
  tag list.

  `fetchers` holds two zero-arity functions:
    * `:jobs` — returns `{:ok, [%{"id" => .., "pipeline" => .., "state" => .., "inputCommits" => ..}]}`
      or `{:error, term()}`.
    * `:tags` — returns `{:ok, [tag_string]}` or `{:error, term()}`.

  `journal_fn` is invoked as `journal_fn.(event, payload)` (payload is a
  string-keyed map) for every event that should be recorded and must return
  `:ok`.

  Returns `{updated_entry, journaled_events}` while the entry stays pending
  and `{nil, journaled_events}` when it should be pruned. Never raises: fetch
  errors simply leave the entry unchanged.
  """
  @spec reconcile(entry(), map(), (String.t(), map() -> :ok)) :: {entry() | nil, [String.t()]}
  def reconcile(entry, fetchers, journal_fn) do
    {entry, events} = reconcile_jobs(entry, fetchers.jobs, journal_fn, [])
    {entry, events} = reconcile_tags(entry, fetchers.tags, journal_fn, events)

    cond do
      entry.built -> {nil, events}
      stale?(entry, DateTime.utc_now()) -> {nil, events}
      true -> {entry, events}
    end
  end

  @doc """
  Journal one build lifecycle event for an issue, best-effort: no-ops when
  the run journal is disabled and never raises. Adds `"issue_id"` to the
  payload when it is missing.
  """
  @spec journal(String.t(), String.t(), map()) :: :ok
  def journal(issue_identifier, event, payload) when is_binary(event) do
    if RunJournal.enabled?() do
      RunJournal.record(
        RunJournal.root(),
        issue_identifier,
        event,
        Map.put_new(payload, "issue_id", issue_identifier)
      )

      Logger.info("BuildFusion journaled issue=#{issue_identifier} event=#{event}")
      :ok
    else
      :ok
    end
  rescue
    error ->
      Logger.warning(
        "BuildFusion journal failed issue=#{inspect(issue_identifier)} event=#{inspect(event)} error=#{inspect(error)}"
      )

      :ok
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    if active?() do
      register_name(Keyword.get(opts, :name, __MODULE__))
      Process.send_after(self(), :tick, interval_ms())
      Logger.info("BuildFusion active poll_interval_ms=#{interval_ms()} sandman=#{RepoDelta.sandman_base()}")
      {:ok, %{pending: %{}}}
    else
      # Idle: build events disabled or no sandman control plane. Never
      # schedule a tick and never take the registered name.
      {:ok, %{}}
    end
  end

  @impl true
  def handle_cast(
        {:track, issue_identifier, repo_url, branch, image, registry, head, description},
        %{pending: pending} = state
      ) do
    entry = %{
      repo: repo_url,
      branch: branch,
      image: image,
      registry: resolve_registry(registry),
      head: head,
      description: description,
      jobs: MapSet.new(),
      job_done: false,
      built: false,
      verify_started: false,
      tracked_at: DateTime.utc_now()
    }

    # One pending entry per (issue, head): a thread can deploy several
    # builds in sequence, and a new deploy must not clobber an in-flight
    # one's reconciliation.
    {:noreply, %{state | pending: Map.put(pending, pending_key(issue_identifier, head), entry)}}
  end

  def handle_cast({:track, _, _, _, _, _, _, _}, state) do
    # Idle: tracking is a no-op.
    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, %{pending: pending} = state) do
    Process.send_after(self(), :tick, interval_ms())

    pending =
      try do
        reconcile_pending(pending)
      rescue
        error ->
          Logger.error("BuildFusion tick crashed error=#{Exception.message(error)}")
          pending
      end

    {:noreply, %{state | pending: pending}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  # ── Tick internals ──────────────────────────────────────────────────────

  defp reconcile_pending(pending) do
    case RepoDelta.sandman_base() do
      sandman when is_binary(sandman) and sandman != "" ->
        Enum.reduce(pending, %{}, fn {key, entry}, acc ->
          case reconcile_one(key, entry, sandman) do
            nil -> acc
            {_key, updated_entry} -> Map.put(acc, key, updated_entry)
          end
        end)

      _ ->
        pending
    end
  end

  defp reconcile_one(key, entry, sandman) do
    issue_identifier = issue_identifier_from_key(key)
    registry = entry.registry || default_registry()

    fetchers = %{
      jobs: fn -> fetch_jobs(sandman) end,
      tags: fn -> fetch_tags(registry, entry.image) end
    }

    journal_fn = fn event, payload -> journal(issue_identifier, event, payload) end

    case reconcile(entry, fetchers, journal_fn) do
      # reconcile/3 reports a prune as {nil, _journaled}; a bare nil entry
      # must not be wrapped back into the pending map.
      {nil, journaled} ->
        maybe_start_verify(issue_identifier, entry, journaled)
        nil

      {updated, journaled} ->
        if maybe_start_verify(issue_identifier, entry, journaled) do
          {key, %{updated | verify_started: true}}
        else
          {key, updated}
        end
    end
  end

  defp pending_key(issue_identifier, head) do
    issue_identifier <> "|" <> head
  end

  defp issue_identifier_from_key(key) do
    case String.split(key, "|", parts: 2) do
      [identifier, _head] -> identifier
      _ -> key
    end
  end

  # ── Auto-verify ─────────────────────────────────────────────────────────
  #
  # When a tracked build succeeds (the registry carries the short head
  # tag), queue one read-only verification intent against the thread's
  # repo if auto-verify is enabled and no verification is already queued
  # for the thread. The verdict (verify.txt) is journaled onto the thread
  # by AgentRunner when the pass runs. Returns true when a pass was
  # queued so the caller can mark the entry.

  defp maybe_start_verify(issue_identifier, entry, journaled) do
    if "build_succeeded" in journaled and
         not entry.verify_started and
         auto_verify_enabled?() and
         thread_auto_verify_enabled?(issue_identifier) and
         is_binary(entry.description) and
         String.trim(entry.description) != "" and
         is_binary(entry.repo) do
      case verify_thread(issue_identifier, entry) do
        {:ok, _verify_id} -> true
        {:error, _reason} -> false
      end
    else
      false
    end
  end

  defp auto_verify_enabled? do
    case Config.settings() do
      {:ok, settings} -> settings.observability.auto_verify_enabled
      _ -> true
    end
  end

  # A thread registered with the `no-verify` label never auto-spawns a
  # verification pass; the human triggers one explicitly with Verify-again.
  # The label gates only the auto path — manual re-verifies are deliberate.
  defp thread_auto_verify_enabled?(issue_identifier) do
    case SymphonyElixir.Intents.IntentStore.get_intent(issue_identifier) do
      {:ok, intent} -> not SymphonyElixir.Intents.Intent.verify_disabled?(intent)
      _ -> true
    end
  end

  @doc """
  Queues one read-only verification pass against a thread's built head.

  Shared by the auto-verify poller and the manual Verify-again action.
  Deduplicates to a single non-terminal pass per thread; the
  `verification_started` journal event is emitted exactly once per pass.
  """
  @spec verify_thread(String.t(), map()) ::
          {:ok, String.t()} | {:error, :verify_pending | term()}
  def verify_thread(issue_identifier, entry) do
    if no_active_verify?(issue_identifier) do
      create_verify_intent(issue_identifier, entry)
    else
      {:error, :verify_pending}
    end
  end

  @doc false
  @spec no_active_verify?(String.t()) :: boolean()
  def no_active_verify?(issue_identifier) do
    case SymphonyElixir.Intents.IntentStore.list_intents() do
      {:ok, intents} ->
        not Enum.any?(intents, fn intent ->
          intent.verify_for == issue_identifier and
            not SymphonyElixir.Intents.Intent.terminal_state?(intent.state)
        end)

      _ ->
        true
    end
  end

  defp create_verify_intent(issue_identifier, entry) do
    description = """
    READ-ONLY VERIFICATION PASS — do not modify any repository files.

    A prior agent run claimed this request was satisfied, and the change
    was built and deployed to the repository mirror:

      Repository: #{entry.repo}
      Built head: #{entry.head}

    Original request:
    #{String.trim(entry.description)}

    Verify whether the request is actually satisfied by the state of this
    workspace (the repository at the built head): read the relevant code,
    run cheap checks, and reason about it. Do NOT edit or add any
    repository files.

    When you have reached a verdict, write a file named `verify.txt` in
    the workspace root whose first line is exactly one of:

      SOLVED
      NOT_SOLVED
      UNCLEAR

    and whose remaining lines are concise evidence: what you checked and
    what you found. Then finish your turn.
    """

    title =
      "Verify #{String.slice(entry.head, 0, 8)} — " <>
        (issue_identifier |> String.split("-") |> List.last() |> Kernel.||(issue_identifier))

    case SymphonyElixir.Intents.IntentStore.create_intent(%{
           "state" => "queued",
           "title" => title,
           "repo" => entry.repo,
           "description" => description,
           "labels" => ["verify"],
           "verify_for" => issue_identifier
         }) do
      {:ok, %{id: verify_id}} ->
        SymphonyElixir.Intents.IntentStore.activate_intent(verify_id)

        journal(issue_identifier, "verification_started", %{
          "head" => entry.head,
          "verify_intent" => verify_id
        })

        {:ok, verify_id}

      {:error, reason} ->
        Logger.error(
          "verification intent creation failed thread=#{issue_identifier} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp fetch_jobs(sandman) do
    case Req.get(sandman <> "/api/v1/jobs?limit=30", receive_timeout: @http_timeout_ms) do
      {:ok, %{status: 200, body: jobs}} when is_list(jobs) -> {:ok, jobs}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_tags(registry, image) do
    case Req.get("https://#{registry}/v2/#{image}/tags/list", receive_timeout: @http_timeout_ms) do
      {:ok, %{status: 200, body: %{"tags" => tags}}} when is_list(tags) -> {:ok, tags}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Reconcile helpers ───────────────────────────────────────────────────

  defp reconcile_jobs(entry, jobs_fetcher, journal_fn, events) do
    watch = watch_pipeline(entry.image)

    case jobs_fetcher.() do
      {:ok, jobs} when is_list(jobs) ->
        jobs
        |> Enum.filter(&matching_job?(&1, watch, entry.head))
        |> Enum.sort_by(fn job -> Map.fetch!(job, "id") end)
        |> Enum.reduce({entry, events}, fn job, {entry, events} ->
          reconcile_job(entry, job, journal_fn, events)
        end)

      _ ->
        {entry, events}
    end
  end

  defp matching_job?(%{"id" => id} = job, watch, head) when is_binary(id) do
    Map.get(job, "pipeline") == watch and head_in_commits?(head, job)
  end

  defp matching_job?(_job, _watch, _head), do: false

  defp head_in_commits?(head, %{"inputCommits" => commits}) when is_list(commits),
    do: head in commits

  defp head_in_commits?(head, %{"inputCommits" => commits}) when is_binary(commits),
    do: commits == head

  defp head_in_commits?(_head, _job), do: false

  defp reconcile_job(entry, job, journal_fn, events) do
    id = Map.fetch!(job, "id")
    state = Map.get(job, "state") || ""
    terminal? = state in @terminal_states
    seen? = MapSet.member?(entry.jobs, id)

    cond do
      terminal? and seen? and not entry.job_done ->
        # A job first seen running has reached a terminal state: finish it
        # exactly once.
        events = journal_event(journal_fn, "job_finished", job_payload(entry, job), events)
        {%{entry | job_done: true}, events}

      terminal? and not seen? ->
        # First sighting is already terminal: the watch job raced past the
        # poll interval. Record the start (observed state) so the timeline
        # always reads started -> finished, then finish it once.
        events = journal_event(journal_fn, "job_started", job_payload(entry, job), events)

        events = journal_event(journal_fn, "job_finished", job_payload(entry, job), events)
        {%{entry | jobs: MapSet.put(entry.jobs, id), job_done: true}, events}

      seen? ->
        # Already-seen running job: nothing new to journal.
        {entry, events}

      true ->
        events = journal_event(journal_fn, "job_started", job_payload(entry, job), events)
        {%{entry | jobs: MapSet.put(entry.jobs, id)}, events}
    end
  end

  defp job_payload(entry, job) do
    %{
      "repo" => entry.repo,
      "head" => entry.head,
      "job_id" => Map.fetch!(job, "id"),
      "pipeline" => Map.get(job, "pipeline"),
      "state" => Map.get(job, "state") || ""
    }
  end

  defp reconcile_tags(entry, tags_fetcher, journal_fn, events) do
    head_tag = String.slice(entry.head || "", 0, 12)

    case tags_fetcher.() do
      {:ok, tags} when is_list(tags) ->
        if head_tag != "" and head_tag in tags do
          payload = %{
            "repo" => entry.repo,
            "head" => entry.head,
            "image" => entry.image,
            "tag" => head_tag
          }

          events = journal_event(journal_fn, "build_succeeded", payload, events)
          {%{entry | built: true}, events}
        else
          {entry, events}
        end

      _ ->
        {entry, events}
    end
  end

  defp journal_event(journal_fn, event, payload, events) do
    case journal_fn.(event, payload) do
      :ok -> events ++ [event]
      _ -> events
    end
  end

  defp stale?(%{tracked_at: nil}, _now), do: false

  defp stale?(entry, now) do
    minutes = DateTime.diff(now, entry.tracked_at, :minute)
    (entry.job_done and minutes > @job_done_prune_minutes) or minutes > @max_prune_minutes
  end

  defp watch_pipeline(image) when is_binary(image) do
    case System.get_env(@watch_pipeline_env) do
      value when is_binary(value) and value != "" -> value
      _ -> image <> "-watch"
    end
  end

  # ── Config / environment helpers ────────────────────────────────────────

  # Field access goes through Map.get so a settings struct built without the
  # newest fields (e.g. an older workflow config shape) can never crash the
  # supervisor at boot — missing keys simply disable or use defaults.
  defp active? do
    case Config.settings() do
      {:ok, settings} ->
        Map.get(settings.observability, :build_events_enabled, false) and
          RepoDelta.sandman_base() != nil

      _ ->
        false
    end
  end

  defp interval_ms do
    case Config.settings() do
      {:ok, settings} -> Map.get(settings.observability, :build_events_interval_ms, 15_000)
      _ -> 15_000
    end
  end

  defp register_name(name) do
    Process.register(self(), name)
  rescue
    ArgumentError ->
      Logger.warning("BuildFusion name #{inspect(name)} already taken; running unregistered")
  end

  defp resolve_registry(registry) when is_binary(registry) and registry != "", do: registry
  defp resolve_registry(_), do: configured_registry() || default_registry()

  defp configured_registry do
    case Config.settings() do
      {:ok, settings} -> Map.get(settings.observability, :build_events_registry)
      _ -> nil
    end
  end
end
