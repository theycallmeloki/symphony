defmodule SymphonyElixir.RepoDelta do
  @moduledoc """
  Repository deltas for intent-backed agent runs.

  When an intent carries a `repo` (an https clone URL of an external git
  repository mirrored into a sandman control plane) and `SANDMAN_ADDR`
  names that control plane, a run's workspace becomes a real working copy
  of the mirror:

  * `bootstrap/3` materializes the mapped repository's head tree into the
    workspace as a fresh git checkout (one base commit), so the agent
    edits real files with full repository context instead of an empty
    scratch directory.
  * `emit_delta/3` runs after the agent finishes and delivers the
    workspace's edits back to sandman's git delta receiver (`POST
    /api/v1/git/delta`) — changed and added file contents plus deleted
    paths, applied by the control plane onto the mapped repository as one
    new commit that re-triggers any pipeline bound to the repo URL. This
    is the sandman-native "keep editing the codebase with patches" loop:
    the runtime never pushes, never holds credentials, and the checkout
    itself is left untouched.

  Both steps are best-effort and local-only (worker-host execution is not
  supported yet): failures log and never fail or alter the agent run.
  The feature is inert unless `SANDMAN_ADDR` is set and the intent has a
  `repo`, so non-repo workflows are unchanged.
  """

  require Logger

  alias SymphonyElixir.Tracker.Issue

  @marker ".sandman-src"
  @tracked_branch_env "SANDMAN_DEFAULT_BRANCH"
  @default_branch "master"
  @http_timeout_ms 15_000

  @spec sandman_base() :: String.t() | nil
  def sandman_base do
    case System.get_env("SANDMAN_ADDR") do
      nil -> nil
      "" -> nil
      addr -> String.trim_trailing(addr, "/")
    end
  end

  @spec tracked_branch() :: String.t()
  def tracked_branch do
    case System.get_env(@tracked_branch_env) do
      branch when is_binary(branch) and branch != "" -> branch
      _ -> @default_branch
    end
  end

  @doc """
  Whether repo-delta handling applies to an issue: it carries a repo and a
  sandman control plane is configured.
  """
  @spec enabled?(Issue.t()) :: boolean()
  def enabled?(%Issue{repo: repo}) when is_binary(repo) and repo != "" do
    sandman_base() != nil
  end

  def enabled?(_issue), do: false

  @doc """
  Best-effort workspace bootstrap: logs failures, never raises.
  """
  @spec best_effort_bootstrap(Path.t(), Issue.t(), String.t() | nil) :: :ok
  def best_effort_bootstrap(workspace, issue, worker_host) do
    case bootstrap(workspace, issue, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("RepoDelta bootstrap skipped #{issue_log(issue)} reason=#{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Best-effort delta emission: logs failures, never raises.
  """
  @spec best_effort_emit(Path.t(), Issue.t(), String.t() | nil) :: :ok
  def best_effort_emit(workspace, issue, worker_host) do
    case emit_delta(workspace, issue, worker_host) do
      {:ok, _detail} ->
        :ok

      {:error, reason} ->
        Logger.warning("RepoDelta emit skipped #{issue_log(issue)} reason=#{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Materializes the mapped repository's head into `workspace` as a real git
  checkout (one base commit) and records the mirror revision in
  `.sandman-src`. Returns `:ok`, or `{:error, reason}`; a repo that is not
  mapped on the control plane (no head yet) yields `{:error, :not_mapped}`
  and leaves the workspace empty — the run proceeds without repository
  context, exactly as before.
  """
  @spec bootstrap(Path.t(), Issue.t(), String.t() | nil) :: :ok | {:error, term()}
  def bootstrap(_workspace, _issue, worker_host) when is_binary(worker_host) do
    {:error, {:remote_workspace_unsupported, worker_host}}
  end

  def bootstrap(_workspace, %Issue{repo: repo}, _worker_host)
      when not is_binary(repo) or repo == "" do
    {:error, :no_repo}
  end

  def bootstrap(workspace, %Issue{repo: repo}, nil) when is_binary(repo) do
    with {:ok, base} <- require_sandman(),
         {:ok, head_id, revision} <- mapped_head(base, repo_name(repo), tracked_branch()),
         {:ok, paths} <- list_files(base, head_id),
         {:ok, tree} <- fetch_tree(base, head_id, paths),
         :ok <- write_tree(workspace, tree),
         :ok <- init_git_checkout(workspace, repo, revision),
         :ok <- write_marker(workspace, repo, revision) do
      Logger.info("RepoDelta bootstrapped workspace=#{workspace} repo=#{repo} head=#{revision}")
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def bootstrap(_workspace, _issue, _worker_host), do: {:error, :no_repo}

  @doc """
  Delivers the workspace's edits (vs its bootstrap commit) to the sandman
  git delta receiver. Only runs when this workspace was bootstrapped (it
  carries a `.sandman-src` marker) — arbitrary workspaces are never
  emitted. Returns `{:ok, :no_changes}` when the agent changed nothing.
  """
  @spec emit_delta(Path.t(), Issue.t(), String.t() | nil) ::
          {:ok, :delivered | :no_changes} | {:error, term()}
  def emit_delta(_workspace, _issue, worker_host) when is_binary(worker_host) do
    {:error, {:remote_workspace_unsupported, worker_host}}
  end

  def emit_delta(workspace, _issue, nil) do
    with {:ok, base} <- require_sandman(),
         {:ok, %{"url" => repo, "branch" => branch, "revision" => revision}} <-
           read_marker(workspace),
         {:ok, head} <- git_ok(workspace, ["rev-parse", "HEAD"]) do
      {files, deleted} = worktree_delta(workspace)

      if map_size(files) == 0 and deleted == [] do
        {:ok, :no_changes}
      else
        payload = %{
          "url" => repo,
          "branch" => branch,
          "revision" => head,
          "base" => revision,
          "files" => files,
          "deleted" => deleted,
          "private" => false
        }

        case Req.post(
               base <> "/api/v1/git/delta",
               json: payload,
               receive_timeout: @http_timeout_ms
             ) do
          {:ok, %{status: 200}} ->
            Logger.info("RepoDelta delivered #{map_size(files)} changed / #{length(deleted)} deleted repo=#{repo}")

            {:ok, :delivered}

          {:ok, %{status: status, body: body}} ->
            {:error, {:delta_rejected, status, body}}

          {:error, reason} ->
            {:error, {:delta_transport, reason}}
        end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # -- sandman mirror access ----------------------------------------------

  defp require_sandman do
    case sandman_base() do
      nil -> {:error, :sandman_not_configured}
      base -> {:ok, base}
    end
  end

  @doc """
  The mapped repository name for a clone URL: last path segment without
  the `.git` suffix.
  """
  @spec repo_name(String.t()) :: String.t()
  def repo_name(url) do
    url
    |> String.trim_trailing(".git")
    |> String.trim_trailing("/")
    |> String.split("/")
    |> List.last()
  end

  # head of the mapped repo: its commit id plus the recorded external
  # revision (.git/HEAD marker), which is the delta base the control plane
  # will verify. A missing marker falls back to the commit id.
  defp mapped_head(base, repo, branch) do
    path = "/api/v1/repos/#{URI.encode(repo)}/branches/#{URI.encode(branch)}/head"

    case Req.get(base <> path, receive_timeout: @http_timeout_ms) do
      {:ok, %{status: 200, body: %{"id" => head_id}}} ->
        case marker_revision(base, head_id) do
          {:ok, revision} -> {:ok, head_id, revision}
          {:error, _reason} -> {:ok, head_id, head_id}
        end

      {:ok, %{status: status}} when status in [404, 409] ->
        {:error, :not_mapped}

      {:error, reason} ->
        {:error, {:sandman_unreachable, reason}}
    end
  end

  defp marker_revision(base, head_id) do
    path = "/api/v1/commits/#{URI.encode(head_id)}/files/.git/HEAD"

    case Req.get(base <> path, receive_timeout: @http_timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, String.trim_trailing(body, "\n")}
      _ -> {:error, :no_marker}
    end
  end

  defp list_files(base, head_id) do
    path = "/api/v1/commits/#{URI.encode(head_id)}/files"

    case Req.get(base <> path, receive_timeout: @http_timeout_ms) do
      {:ok, %{status: 200, body: body}} ->
        paths = file_paths(body)

        if is_list(paths) do
          {:ok, Enum.reject(paths, &git_internal?/1)}
        else
          {:error, :files_list_shape}
        end

      {:ok, %{status: status}} ->
        {:error, {:files_list_rejected, status}}

      {:error, reason} ->
        {:error, {:sandman_unreachable, reason}}
    end
  end

  defp file_paths(%{"files" => files}) when is_list(files), do: Enum.map(files, & &1["path"])
  defp file_paths(files) when is_list(files), do: Enum.map(files, & &1["path"])
  defp file_paths(_), do: nil

  defp fetch_tree(base, head_id, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      case fetch_file(base, head_id, path) do
        {:ok, content} -> {:cont, {:ok, Map.put(acc, path, content)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_file(base, head_id, path) do
    escaped_path =
      path
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode/1)

    url = base <> "/api/v1/commits/#{URI.encode(head_id)}/files/" <> escaped_path

    case Req.get(url, receive_timeout: @http_timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:file_rejected, path, status}}

      {:error, reason} ->
        {:error, {:sandman_unreachable, path, reason}}
    end
  end

  # -- workspace materialization ------------------------------------------

  # sandman mirrors store a ".git/HEAD" marker file inside their trees; it
  # must never be written into the real checkout we build here.
  defp git_internal?("/.git/" <> _), do: true
  defp git_internal?(".git/" <> _), do: true
  defp git_internal?("/.git"), do: true
  defp git_internal?(".git"), do: true
  defp git_internal?(_), do: false

  @doc """
  Writes a fetched mirror tree into the workspace (directory paths created
  as needed). Git-internal and marker paths are filtered out upstream.
  """
  @spec write_tree(Path.t(), %{optional(String.t()) => String.t()}) :: :ok | {:error, term()}
  def write_tree(workspace, tree) do
    Enum.reduce_while(tree, :ok, fn {path, content}, :ok ->
      full = Path.join(workspace, path)

      case File.mkdir_p(Path.dirname(full)) do
        :ok ->
          case File.write(full, content) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:write_failed, path, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:mkdir_failed, path, reason}}}
      end
    end)
  end

  # Creates the base commit from the materialized tree and makes the
  # marker file invisible to future deltas (appended to .gitignore).
  defp init_git_checkout(workspace, repo, revision) do
    with :ok <- ignore_marker(workspace),
         {:ok, _} <- git_ok(workspace, ["init", "-q"]),
         {:ok, _} <- git_ok(workspace, ["config", "user.name", "Sandman Mirror"]),
         {:ok, _} <- git_ok(workspace, ["config", "user.email", "sandman@mirror.local"]),
         {:ok, _} <- git_ok(workspace, ["add", "-A"]),
         {:ok, _} <- git_ok(workspace, ["commit", "-q", "-m", "materialized #{repo} @ #{revision}"]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ignore_marker(workspace) do
    gitignore = Path.join(workspace, ".gitignore")
    existing = if File.exists?(gitignore), do: File.read!(gitignore), else: ""

    if String.contains?(existing, @marker) do
      :ok
    else
      File.write(gitignore, existing <> "\n" <> @marker <> "\n")
    end
  end

  defp write_marker(workspace, repo, revision) do
    marker = Path.join(workspace, @marker)

    File.write!(
      marker,
      Jason.encode!(%{"url" => repo, "branch" => tracked_branch(), "revision" => revision})
    )
  end

  @spec read_marker(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_marker(workspace) do
    marker = Path.join(workspace, @marker)

    case File.read(marker) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"url" => url, "branch" => branch, "revision" => revision} = decoded}
          when is_binary(url) and is_binary(branch) and is_binary(revision) ->
            {:ok, decoded}

          {:ok, _} ->
            {:error, :marker_malformed}

          {:error, reason} ->
            {:error, {:marker_decode, reason}}
        end

      {:error, :enoent} ->
        {:error, :not_bootstrapped}

      {:error, reason} ->
        {:error, {:marker_read, reason}}
    end
  end

  # -- git plumbing --------------------------------------------------------

  defp git_ok(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git, args, status, output}}
    end
  end

  @doc """
  Computes the workspace's edits vs its HEAD: changed/added paths (full
  content) and deleted paths. Parses `git diff --name-status -z` plus
  untracked files, mirroring the sandman `patch` verb.
  """
  @spec worktree_delta(Path.t()) :: {%{optional(String.t()) => String.t()}, [String.t()]}
  def worktree_delta(workspace) do
    {statuses, 0} =
      System.cmd(
        "git",
        ["-C", workspace, "diff", "--name-status", "-z", "--no-renames", "HEAD"],
        stderr_to_stdout: true
      )

    {files, removed} = parse_statuses(statuses, workspace)

    {untracked, 0} =
      System.cmd(
        "git",
        ["-C", workspace, "ls-files", "--others", "--exclude-standard", "-z"],
        stderr_to_stdout: true
      )

    files =
      untracked
      |> String.split("\0", trim: true)
      |> Enum.reject(&Map.has_key?(removed, &1))
      |> Enum.reduce(files, fn path, acc ->
        case read_worktree(workspace, path) do
          {:ok, content} -> Map.put(acc, path, content)
          _ -> acc
        end
      end)

    {files, Map.keys(removed) |> Enum.sort()}
  end

  @doc """
  Parses `git diff --name-status -z` output into changed-file contents and
  removed paths. Exposed for tests: pure given the output and a
  workspace-backed reader.
  """
  @spec parse_statuses(String.t(), Path.t()) ::
          {%{optional(String.t()) => String.t()}, %{optional(String.t()) => boolean()}}
  def parse_statuses(statuses, workspace) do
    statuses
    |> String.split("\0")
    |> Enum.chunk_every(2)
    |> Enum.reduce({%{}, %{}}, fn
      [code, path], {files, removed} ->
        if code == "" do
          {files, removed}
        else
          cond do
            String.starts_with?(code, "D") ->
              {files, Map.put(removed, path, true)}

            true ->
              case read_worktree(workspace, path) do
                {:ok, content} -> {Map.put(files, path, content), removed}
                _ -> {files, Map.put(removed, path, true)}
              end
          end
        end

      _unpaired, acc ->
        acc
    end)
  end

  defp read_worktree(workspace, path) do
    full = Path.join(workspace, path)

    case File.lstat(full) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(full) do
          {:ok, target} -> {:ok, target}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        File.read(full)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_log(%Issue{id: id, identifier: identifier}),
    do: "issue_id=#{id} issue_identifier=#{identifier}"

  defp issue_log(_), do: "issue_unknown"
end
