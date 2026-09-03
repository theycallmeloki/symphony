defmodule SymphonyElixir.AgentRuntime.ChildEnvTest do
  # not async: the spawn test mutates the OS environment for the process
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRuntime.{ChildEnv, PiAcp}

  @moduletag :tmp_dir

  describe "scoped_env/1 (pure)" do
    test "keeps the operational allowlist and HOME" do
      inherited = %{
        "PATH" => "/usr/bin:/bin",
        "HOME" => "/home/symphony",
        "LANG" => "C.UTF-8",
        "TMPDIR" => "/tmp"
      }

      env = ChildEnv.scoped_env(inherited_env: inherited)
      assert env["PATH"] == "/usr/bin:/bin"
      assert env["HOME"] == "/home/symphony"
      assert env["LANG"] == "C.UTF-8"
      assert env["TMPDIR"] == "/tmp"
    end

    test "strips credential-class variables (github tokens, ssh, keys)" do
      inherited = %{
        "PATH" => "/usr/bin",
        "GITHUB_TOKEN" => "ghp_secret",
        "GH_TOKEN" => "gho_secret",
        "SSH_AUTH_SOCK" => "/run/ssh.sock",
        "AWS_SECRET_ACCESS_KEY" => "aws_secret",
        "OPENAI_API_KEY" => "sk-secret",
        "MY_APP_PASSWORD" => "pw",
        # non-secret-named: passes
        "DATABASE_URL" => "postgres://user:pass@db"
      }

      env = ChildEnv.scoped_env(inherited_env: inherited)
      refute Map.has_key?(env, "GITHUB_TOKEN")
      refute Map.has_key?(env, "GH_TOKEN")
      refute Map.has_key?(env, "SSH_AUTH_SOCK")
      refute Map.has_key?(env, "AWS_SECRET_ACCESS_KEY")
      refute Map.has_key?(env, "OPENAI_API_KEY")
      refute Map.has_key?(env, "MY_APP_PASSWORD")
      assert env["DATABASE_URL"] == "postgres://user:pass@db"
    end

    test "extra_allow passes an operator-declared variable through the strip" do
      inherited = %{"PATH" => "/usr/bin", "OPENAI_API_KEY" => "sk-secret"}

      env = ChildEnv.scoped_env(inherited_env: inherited, extra_allow: ["OPENAI_API_KEY"])
      assert env["OPENAI_API_KEY"] == "sk-secret"

      stripped = ChildEnv.scoped_env(inherited_env: inherited)
      refute Map.has_key?(stripped, "OPENAI_API_KEY")
    end

    test "forces the ambient-git fence regardless of the inherited env" do
      inherited = %{"PATH" => "/usr/bin", "GIT_CONFIG_GLOBAL" => "/home/user/.gitconfig"}

      env = ChildEnv.scoped_env(inherited_env: inherited)
      assert env["GIT_CONFIG_GLOBAL"] == "/dev/null"
      assert env["GIT_CONFIG_NOSYSTEM"] == "1"
      assert env["GIT_TERMINAL_PROMPT"] == "0"
      assert env["GH_CONFIG_DIR"] == "/dev/null"
    end

    test "empty inherited env still yields the fence" do
      env = ChildEnv.scoped_env(inherited_env: %{})
      assert env["GIT_TERMINAL_PROMPT"] == "0"
      refute Map.has_key?(env, "GITHUB_TOKEN")
    end
  end

  describe "pi-acp spawn env (integration)" do
    # A stub that dumps its environment to a file before speaking the ACP
    # session/new surface, so we can assert what the child actually saw.
    defp write_env_dump_stub(tmp_dir) do
      dump = Path.join(tmp_dir, "child.env")
      script = Path.join(tmp_dir, "stub-pi-acp")

      File.write!(script, """
      #!/bin/sh
      env | sort > "#{dump}"
      echo '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"env-stub-session"}}'
      sleep 60
      """)

      File.chmod!(script, 0o755)
      {script, dump}
    end

    test "the spawned pi-acp child does not see credential env from the parent",
         %{tmp_dir: tmp_dir} do
      # Sentinels the orchestrator process carries; the child must not.
      System.put_env("GITHUB_TOKEN", "ghp_sentinel")
      System.put_env("SYMPHONY_TEST_SSH_KEY", "ssh_sentinel")

      try do
        {stub, dump} = write_env_dump_stub(tmp_dir)
        workspace = Path.join(tmp_dir, "ws")
        File.mkdir_p!(workspace)

        {:ok, session} = PiAcp.start_session(workspace, command: stub, timeout_ms: 5_000)
        assert session.session_id == "env-stub-session"
        :ok = PiAcp.stop_session(session)

        child_env = File.read!(dump)
        refute child_env =~ "GITHUB_TOKEN"
        refute child_env =~ "SYMPHONY_TEST_SSH_KEY"
        assert child_env =~ "HOME="
        assert child_env =~ "PATH="
        assert child_env =~ "GIT_TERMINAL_PROMPT=0"
      after
        System.delete_env("GITHUB_TOKEN")
        System.delete_env("SYMPHONY_TEST_SSH_KEY")
      end
    end
  end
end
