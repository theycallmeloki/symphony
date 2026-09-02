defmodule SymphonyElixir.TrackedRepos do
  @moduledoc """
  Tracked repositories on the sandman control plane.

  A repository is *tracked* when a build-bus watch pipeline exists for its
  mirror — a pipeline named `<repo>-watch` (for example `symphony-watch`
  for the `symphony` mirror) that re-triggers on every delta commit. A
  tracked repo is therefore one the dashboard can launch jobs against:
  `fetch/0` lists the tracked mirrors together with their watch pipelines'
  current state, so job launch only offers repos that are actually being
  built.

  The feature is inert unless `SANDMAN_ADDR` names a sandman control
  plane.
  """

  alias SymphonyElixir.RepoDelta

  @http_timeout_ms 15_000

  @type tracked_repo :: %{
          repo: String.t(),
          git_url: String.t() | nil,
          watch_pipeline: String.t(),
          watch_state: String.t() | nil
        }

  @doc """
  Fetches the tracked repositories from the sandman control plane.

  GETs `{base}/api/v1/repos` and `{base}/api/v1/pipelines` with a 15s
  receive timeout. Returns `{:error, :not_configured}` when no `SANDMAN_ADDR`
  is set. Both requests are best-effort, but a failure is never silently
  degraded into a partial list: a failed repos fetch means no mirror list at
  all, and a failed pipelines fetch means trackedness is unknown, so either
  failure yields `{:error, reason}`.
  """
  @spec fetch() :: {:ok, [tracked_repo()]} | {:error, term()}
  def fetch do
    case RepoDelta.sandman_base() do
      nil ->
        {:error, :not_configured}

      base ->
        case Req.get(base <> "/api/v1/repos", receive_timeout: @http_timeout_ms) do
          {:ok, %{status: 200, body: repos}} when is_list(repos) ->
            fetch_pipelines(base, repos)

          {:ok, %{status: status}} ->
            {:error, {:repos_unavailable, status}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Filters `repos` down to the tracked ones and sorts them by repo name.

  A repo is tracked when some pipeline in `pipelines` is named
  `repo <> "-watch"`. When several pipelines share a watch name the first
  one wins; a pipeline without a `state` yields `watch_state: nil`. Each
  tracked repo also carries the binding git clone URL from its watch
  pipeline's input (`input.git.url`) when the pipeline declares one —
  dashboard launches queue that URL so emitted deltas match the binding —
  and `nil` otherwise.
  """
  @spec reconcile([map()], [map()]) :: [tracked_repo()]
  def reconcile(repos, pipelines) do
    by_name =
      Enum.reduce(pipelines, %{}, fn %{"name" => name} = pipeline, acc ->
        Map.put_new(acc, name, pipeline)
      end)

    repos
    |> Enum.flat_map(fn %{"name" => repo} ->
      watch = repo <> "-watch"

      case Map.fetch(by_name, watch) do
        {:ok, pipeline} ->
          [
            %{
              repo: repo,
              git_url: binding_git_url(pipeline),
              watch_pipeline: watch,
              watch_state: pipeline["state"]
            }
          ]

        :error ->
          []
      end
    end)
    |> Enum.sort_by(& &1.repo)
  end

  defp binding_git_url(pipeline) do
    case pipeline do
      %{"input" => %{"git" => %{"url" => url}}} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp fetch_pipelines(base, repos) do
    case Req.get(base <> "/api/v1/pipelines", receive_timeout: @http_timeout_ms) do
      {:ok, %{status: 200, body: pipelines}} when is_list(pipelines) ->
        {:ok, reconcile(repos, pipelines)}

      {:ok, %{status: status}} ->
        {:error, {:pipelines_unavailable, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
