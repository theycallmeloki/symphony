defmodule SymphonyElixir.BuildFusionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.BuildFusion

  @repo "https://git.example.com/acme/widget.git"
  @head String.duplicate("a", 40)
  @head_tag String.slice(@head, 0, 12)
  @watch "widget-watch"

  setup do
    previous = System.get_env("SANDMAN_WATCH_PIPELINE")
    restore_env("SANDMAN_WATCH_PIPELINE", nil)

    on_exit(fn ->
      restore_env("SANDMAN_WATCH_PIPELINE", previous)
    end)

    :ok
  end

  defp entry(overrides \\ []) do
    Map.merge(
      %{
        repo: @repo,
        branch: "main",
        image: "widget",
        registry: "registry.example.com",
        head: @head,
        jobs: MapSet.new(),
        job_done: false,
        built: false,
        tracked_at: DateTime.utc_now()
      },
      Map.new(overrides)
    )
  end

  defp job(id, state, input_commits \\ [@head]) do
    %{"id" => id, "pipeline" => @watch, "state" => state, "inputCommits" => input_commits}
  end

  defp jobs_fetcher(jobs), do: fn -> {:ok, jobs} end
  defp tags_fetcher(tags), do: fn -> {:ok, tags} end

  defp journal_harness do
    {:ok, pid} = Agent.start_link(fn -> [] end)

    journal_fn = fn event, payload ->
      Agent.update(pid, &[{event, payload} | &1])
      :ok
    end

    {journal_fn, fn -> Agent.get(pid, &Enum.reverse/1) end}
  end

  test "journals job_started for an unseen running job and keeps the entry pending" do
    {journal_fn, calls} = journal_harness()

    {updated, journaled} =
      BuildFusion.reconcile(
        entry(),
        %{jobs: jobs_fetcher([job("j1", "running")]), tags: tags_fetcher([])},
        journal_fn
      )

    assert journaled == ["job_started"]
    assert [{"job_started", payload}] = calls.()
    assert payload["job_id"] == "j1"
    assert payload["pipeline"] == @watch
    assert payload["state"] == "running"
    assert payload["repo"] == @repo
    assert payload["head"] == @head

    refute updated == nil
    assert MapSet.member?(updated.jobs, "j1")
    refute updated.job_done
    refute updated.built
  end

  test "revisiting the same running job journals nothing" do
    {journal_fn, calls} = journal_harness()

    {updated, ["job_started"]} =
      BuildFusion.reconcile(
        entry(),
        %{jobs: jobs_fetcher([job("j1", "running")]), tags: tags_fetcher([])},
        journal_fn
      )

    {again, journaled} =
      BuildFusion.reconcile(
        updated,
        %{jobs: jobs_fetcher([job("j1", "running")]), tags: tags_fetcher([])},
        journal_fn
      )

    assert journaled == []
    assert [{"job_started", _}] = calls.()
    refute again == nil
    assert MapSet.member?(again.jobs, "j1")
    refute again.job_done
  end

  test "journals job_started + job_finished for an unseen terminal job (first sighting raced the poll)" do
    {journal_fn, calls} = journal_harness()

    {updated, journaled} =
      BuildFusion.reconcile(
        entry(),
        %{jobs: jobs_fetcher([job("j1", "success")]), tags: tags_fetcher([])},
        journal_fn
      )

    assert journaled == ["job_started", "job_finished"]

    assert [{"job_started", started}, {"job_finished", finished}] = calls.()
    assert started["job_id"] == "j1"
    assert started["pipeline"] == @watch
    assert started["state"] == "success"
    assert started["repo"] == @repo
    assert started["head"] == @head
    assert finished["job_id"] == "j1"
    assert finished["pipeline"] == @watch
    assert finished["state"] == "success"
    assert finished["repo"] == @repo
    assert finished["head"] == @head

    refute updated == nil
    assert updated.job_done
    assert MapSet.member?(updated.jobs, "j1")
  end

  test "a running job that later reaches a terminal state is finished exactly once" do
    {journal_fn, calls} = journal_harness()

    {running_entry, ["job_started"]} =
      BuildFusion.reconcile(
        entry(),
        %{jobs: jobs_fetcher([job("j1", "running")]), tags: tags_fetcher([])},
        journal_fn
      )

    {done_entry, journaled} =
      BuildFusion.reconcile(
        running_entry,
        %{jobs: jobs_fetcher([job("j1", "failure")]), tags: tags_fetcher([])},
        journal_fn
      )

    assert journaled == ["job_finished"]
    # calls() accumulates across both reconciles in this test: the first
    # reconcile journaled job_started, the second only job_finished.
    assert [{"job_started", _}, {"job_finished", payload}] = calls.()
    assert payload["job_id"] == "j1"
    assert payload["state"] == "failure"
    assert done_entry.job_done

    # The same terminal job on later ticks is not finished again.
    {again, journaled} =
      BuildFusion.reconcile(
        done_entry,
        %{jobs: jobs_fetcher([job("j1", "failure")]), tags: tags_fetcher([])},
        journal_fn
      )

    assert journaled == []
    assert again.job_done
    assert [{"job_started", _}, {"job_finished", _}] = calls.()
  end

  test "a published head tag journals build_succeeded and prunes the entry" do
    {journal_fn, calls} = journal_harness()

    {pruned, journaled} =
      BuildFusion.reconcile(
        entry(),
        %{jobs: jobs_fetcher([]), tags: tags_fetcher([@head_tag])},
        journal_fn
      )

    assert pruned == nil
    assert journaled == ["build_succeeded"]
    assert [{"build_succeeded", payload}] = calls.()
    assert payload["tag"] == @head_tag
    assert payload["image"] == "widget"
    assert payload["repo"] == @repo
    assert payload["head"] == @head
  end

  test "without the published tag the entry stays pending and nothing is journaled" do
    {journal_fn, calls} = journal_harness()

    {updated, journaled} =
      BuildFusion.reconcile(
        entry(),
        %{jobs: jobs_fetcher([]), tags: tags_fetcher([])},
        journal_fn
      )

    assert journaled == []
    assert calls.() == []
    refute updated == nil
    assert updated.built == false
    assert updated.job_done == false
    assert updated.jobs == MapSet.new()
  end

  test "jobs on other pipelines or other heads are ignored" do
    {journal_fn, calls} = journal_harness()

    other_pipeline = Map.put(job("j2", "running"), "pipeline", "widget-other")
    other_head = Map.put(job("j3", "running"), "inputCommits", [String.duplicate("b", 40)])

    {updated, journaled} =
      BuildFusion.reconcile(
        entry(),
        %{jobs: jobs_fetcher([other_pipeline, other_head]), tags: tags_fetcher([])},
        journal_fn
      )

    assert journaled == []
    assert calls.() == []
    assert updated.jobs == MapSet.new()
  end

  test "matches when inputCommits is a single string equal to the head" do
    {journal_fn, _calls} = journal_harness()

    string_commits = Map.put(job("j4", "running"), "inputCommits", @head)

    {updated, journaled} =
      BuildFusion.reconcile(
        entry(),
        %{jobs: jobs_fetcher([string_commits]), tags: tags_fetcher([])},
        journal_fn
      )

    assert journaled == ["job_started"]
    assert MapSet.member?(updated.jobs, "j4")
  end

  test "SANDMAN_WATCH_PIPELINE overrides the derived watch pipeline" do
    restore_env("SANDMAN_WATCH_PIPELINE", "custom-watch")
    {journal_fn, _calls} = journal_harness()

    custom = %{"id" => "j9", "pipeline" => "custom-watch", "state" => "running", "inputCommits" => [@head]}

    {updated, journaled} =
      BuildFusion.reconcile(
        entry(),
        %{jobs: jobs_fetcher([custom]), tags: tags_fetcher([])},
        journal_fn
      )

    assert journaled == ["job_started"]
    assert MapSet.member?(updated.jobs, "j9")
  end

  test "fetch errors leave the entry pending without journaling" do
    {journal_fn, calls} = journal_harness()

    {updated, journaled} =
      BuildFusion.reconcile(
        entry(),
        %{jobs: fn -> {:error, :timeout} end, tags: fn -> {:error, :timeout} end},
        journal_fn
      )

    assert journaled == []
    assert calls.() == []
    refute updated == nil
    assert updated.jobs == MapSet.new()
    assert updated.built == false
  end

  test "a stale entry is pruned without journaling anything" do
    {journal_fn, calls} = journal_harness()

    old_entry = entry(tracked_at: DateTime.add(DateTime.utc_now(), -61, :minute))

    {pruned, journaled} =
      BuildFusion.reconcile(
        old_entry,
        %{jobs: jobs_fetcher([]), tags: tags_fetcher([])},
        journal_fn
      )

    assert pruned == nil
    assert journaled == []
    assert calls.() == []
  end

  test "a done entry older than twenty minutes is pruned" do
    {journal_fn, _calls} = journal_harness()

    done_old = entry(job_done: true, tracked_at: DateTime.add(DateTime.utc_now(), -21, :minute))

    {pruned, journaled} =
      BuildFusion.reconcile(
        done_old,
        %{jobs: jobs_fetcher([]), tags: tags_fetcher([])},
        journal_fn
      )

    assert pruned == nil
    assert journaled == []
  end

  test "a fresh done entry without a published tag stays pending" do
    {journal_fn, calls} = journal_harness()

    # A finished entry always carries the finished job id (job_finished was
    # journaled when the job reached its terminal state).
    done_fresh = entry(job_done: true, jobs: MapSet.new(["j1"]))

    {updated, journaled} =
      BuildFusion.reconcile(
        done_fresh,
        %{jobs: jobs_fetcher([job("j1", "success")]), tags: tags_fetcher([])},
        journal_fn
      )

    # The already-finished job is not re-journaled while waiting on the image.
    assert journaled == []
    assert calls.() == []
    refute updated == nil
    assert updated.job_done
    assert MapSet.member?(updated.jobs, "j1")
  end

  test "default_registry matches the shared registry constant" do
    assert BuildFusion.default_registry() == "miladyosregistry.transparentlyrotatableproxy.site"
  end
end
