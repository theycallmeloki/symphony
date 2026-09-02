defmodule SymphonyElixir.TrackedReposTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TrackedRepos

  describe "reconcile/2" do
    test "lists repos with a matching watch pipeline, sorted by repo name" do
      repos = [%{"name" => "zeta"}, %{"name" => "alpha"}]

      pipelines = [
        %{
          "name" => "zeta-watch",
          "state" => "running",
          "input" => %{"git" => %{"url" => "https://example.com/zeta.git"}}
        },
        %{"name" => "alpha-watch", "state" => "success"}
      ]

      assert TrackedRepos.reconcile(repos, pipelines) == [
               %{
                 repo: "alpha",
                 git_url: nil,
                 watch_pipeline: "alpha-watch",
                 watch_state: "success"
               },
               %{
                 repo: "zeta",
                 git_url: "https://example.com/zeta.git",
                 watch_pipeline: "zeta-watch",
                 watch_state: "running"
               }
             ]
    end

    test "excludes a repo without a watch pipeline" do
      repos = [%{"name" => "orphan"}, %{"name" => "tracked"}]
      pipelines = [%{"name" => "tracked-watch", "state" => "queued"}]

      assert TrackedRepos.reconcile(repos, pipelines) == [
               %{repo: "tracked", git_url: nil, watch_pipeline: "tracked-watch", watch_state: "queued"}
             ]
    end

    test "the first pipeline matching a watch name wins" do
      repos = [%{"name" => "dup"}]

      pipelines = [
        %{"name" => "dup-watch", "state" => "running"},
        %{"name" => "dup-watch", "state" => "success"}
      ]

      assert TrackedRepos.reconcile(repos, pipelines) == [
               %{repo: "dup", git_url: nil, watch_pipeline: "dup-watch", watch_state: "running"}
             ]
    end

    test "empty repos or pipelines yield an empty list" do
      assert TrackedRepos.reconcile([], []) == []

      assert TrackedRepos.reconcile([%{"name" => "nothing"}], []) == []

      assert TrackedRepos.reconcile([], [%{"name" => "orphan-watch", "state" => "running"}]) == []
    end

    test "a watch pipeline without a state yields watch_state nil" do
      repos = [%{"name" => "alpha"}]
      pipelines = [%{"name" => "alpha-watch"}]

      assert TrackedRepos.reconcile(repos, pipelines) == [
               %{repo: "alpha", git_url: nil, watch_pipeline: "alpha-watch", watch_state: nil}
             ]
    end
  end
end
