defmodule SymphonyElixir.Sandman do
  @moduledoc """
  The single seam to the sandman control plane — via the `sandman` CLI
  binary (the stable, versioned public interface), not sandman's internal
  HTTP API. The CLI is baked into the runtime image pinned to the fleet's
  release (Dockerfile `SANDMAN_VERSION`) and talks to the daemon named by
  `$SANDMAN_ADDR`, so sandman can evolve its internals without breaking
  this app: when a sandman release changes the interface, the CLI ships
  the new verbs/JSON and this module just stays on them.

  Every prior hand-rolled `Req.get(base <> "/api/v1/...")` caller
  (RepoDelta, BuildFusion, TrackedRepos) routes through here. Ops:

    * `jobs/2`   — `sandman job list <pipeline> --input-commit ... --state ... --json`
    * `delta/1`  — `sandman delta <payload.json>` (the exact wire payload)
    * `repos/0`, `pipelines/0` — JSON listings

  The executable is overridable via `SANDMAN_CLI` (tests inject a stub;
  production defaults to `sandman`). The module is inert (returns
  `{:error, :sandman_not_configured}`) when `$SANDMAN_ADDR` is unset.
  """

  require Logger

  @default_bin "sandman"

  @spec sandman_base() :: String.t() | nil
  def sandman_base do
    case System.get_env("SANDMAN_ADDR") do
      nil -> nil
      "" -> nil
      addr -> String.trim_trailing(addr, "/")
    end
  end

  # the CLI's --addr wants host:port without a scheme (the binary's default
  # is $SANDMAN_ADDR but a scheme in that env would leak into dialing)
  defp addr_arg do
    case sandman_base() do
      nil ->
        nil

      base ->
        base
        |> String.replace(~r{^[a-z]+://}i, "")
        |> String.trim_trailing("/")
    end
  end

  defp bin do
    case System.get_env("SANDMAN_CLI") do
      b when is_binary(b) and b != "" -> b
      _ -> @default_bin
    end
  end

  # run the CLI, returning {:ok, stdout} on exit 0 or {:error, reason}.
  defp run(args) when is_list(args) do
    case addr_arg() do
      nil ->
        {:error, :sandman_not_configured}

      addr ->
        case System.cmd(bin(), ["--addr", addr | args], stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          {out, code} -> {:error, {:sandman_cli, code, String.trim(out)}}
        end
    end
  end

  @doc """
  Submits a git delta (the wire contract map) and returns the receiver's
  report. `{:ok, %{"applied" => true, "head" => head}}` when the edit
  landed; `{:ok, %{"applied" => false, "reason" => r}}` when it did not
  (unbound URL / failed base check) — applied is data, not a transport
  error. Transport/parse failures are `{:error, reason}`.
  """
  @spec delta(map()) :: {:ok, map()} | {:error, term()}
  def delta(payload) when is_map(payload) do
    # System.cmd cannot write stdin, and the sandman delta verb accepts the
    # payload as a file argument — write it to a temp file and pass the path.
    file = Path.join(System.tmp_dir!(), "sandman-delta-#{System.unique_integer([:positive])}.json")

    try do
      case File.write(file, Jason.encode!(payload)) do
        :ok ->
          case run(["delta", file]) do
            {:ok, out} -> decode_json(out)
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, {:delta_write_failed, reason}}
      end
    after
      File.rm(file)
    end
  end

  @doc """
  Lists jobs for a pipeline, filtered server-side by input commits and
  states. Returns `{:ok, [job_map]}` — the daemon returns the typed
  client.Job JSON (id/pipeline/state/...), filtered so a caller no longer
  fetches a wide window and matches envelope members itself.
  """
  @spec jobs(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def jobs(pipeline, opts \\ []) when is_binary(pipeline) do
    input_commits = Keyword.get(opts, :input_commits, [])
    states = Keyword.get(opts, :states, [])

    args =
      ["job", "list", pipeline, "--json"] ++
        Enum.flat_map(input_commits, &["--input-commit", &1]) ++
        Enum.flat_map(states, &["--state", &1])

    case run(args) do
      {:ok, out} -> decode_json(out)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lists repos on the control plane (JSON)."
  def repos do
    case run(["repo", "list", "--json"]) do
      {:ok, out} -> decode_json(out)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lists pipelines on the control plane (JSON)."
  def pipelines do
    case run(["pipeline", "list", "--json"]) do
      {:ok, out} -> decode_json(out)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_json(out) do
    case Jason.decode(out) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, {:sandman_json, error, String.slice(out, 0, 200)}}
    end
  end
end
