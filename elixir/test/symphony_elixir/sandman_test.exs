defmodule SymphonyElixir.SandmanTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Sandman

  # A stub `sandman` CLI that echoes canned JSON per verb, so the module's
  # argv construction and JSON parsing are exercised without a real daemon.
  setup do
    prev_addr = System.get_env("SANDMAN_ADDR")
    prev_cli = System.get_env("SANDMAN_CLI")

    stub =
      Path.join(System.tmp_dir!(), "sandman-stub-#{System.unique_integer([:positive])}.sh")

    File.write!(stub, ~S'''
    #!/bin/sh
    args="$*"
    case "$args" in
      *" job list "*)
        if echo "$args" | grep -q "input-commit feedface"; then
          echo '[{"id":"job-1","pipeline":"widget-watch","state":"success","inputCommits":["feedface0000111122223333"]}]'
        else
          echo '[]'
        fi
        ;;
      *" repo list "*) echo '[{"name":"widget"},{"name":"symphony"}]' ;;
      *" pipeline list "*) echo '[{"name":"widget-watch","state":"running"},{"name":"symphony-watch","state":"success"}]' ;;
      *" delta "*) echo '{"applied":true,"reason":"","head":"feedface0000111122223333"}' ;;
      *) echo '{}' ;;
    esac
    ''')
    File.chmod!(stub, 0o755)

    System.put_env("SANDMAN_ADDR", "127.0.0.1:4242")
    System.put_env("SANDMAN_CLI", stub)

    on_exit(fn ->
      File.rm(stub)

      restore(prev_addr, "SANDMAN_ADDR")
      restore(prev_cli, "SANDMAN_CLI")
    end)

    :ok
  end

  defp restore(prev, name) do
    if prev == nil do
      System.delete_env(name)
    else
      System.put_env(name, prev)
    end
  end

  test "jobs/2 builds a server-side filter and decodes the job list" do
    assert {:ok, [job]} =
             Sandman.jobs("widget-watch", input_commits: ["feedface0000111122223333"])

    assert job["pipeline"] == "widget-watch"
    assert job["state"] == "success"
  end

  test "jobs/2 with a non-matching input commit yields an empty list" do
    assert {:ok, []} = Sandman.jobs("widget-watch", input_commits: ["othercommit"])
  end

  test "delta/1 returns the receiver report" do
    payload = %{
      "url" => "https://github.com/theycallmeloki/widget.git",
      "branch" => "master",
      "revision" => "feedface0000111122223333",
      "base" => "deadbeef",
      "files" => %{"a.txt" => "hi"},
      "deleted" => [],
      "private" => false
    }

    assert {:ok, %{"applied" => true, "head" => "feedface0000111122223333"}} = Sandman.delta(payload)
  end

  test "repos/0 and pipelines/0 decode listings" do
    assert {:ok, repos} = Sandman.repos()
    assert Enum.map(repos, & &1["name"]) == ["widget", "symphony"]

    assert {:ok, pipes} = Sandman.pipelines()
    assert Enum.map(pipes, & &1["name"]) == ["widget-watch", "symphony-watch"]
  end

  test "inert when SANDMAN_ADDR is unset" do
    System.delete_env("SANDMAN_ADDR")

    assert {:error, :sandman_not_configured} = Sandman.repos()
    assert {:error, :sandman_not_configured} = Sandman.delta(%{"url" => "x"})
  end
end
