defmodule SymphonyElixir.AgentRuntime.ChildEnv do
  @moduledoc """
  Fail-closed environment scoping for agent child processes (pi-acp).

  Erlang `Port`'s `:env` option REPLACES the child's environment wholesale
  rather than layering on top of it, so the map this module produces is the
  child's *entire* environment. Anything that is not on the operational
  allowlist and is not explicitly allowed never reaches the agent process.
  That converts the "the model must never push or exfiltrate credentials"
  rule from a prompt instruction into a process invariant: a GITHUB_TOKEN
  or SSH key present in the orchestrator's own environment cannot be read
  by the agent it spawns, no matter what the model is told or attempts.

  Deliberate contrast with generic child sandboxes: pi's model
  configuration and auth live in FILES under `$HOME/.pi` (mounted into the
  worker container), so HOME passes through untouched instead of being
  replaced by a synthetic home. Provider/API credentials are expected to
  travel the same file route; an operator who instead supplies them via
  environment variables must name them explicitly in `pi.child_env_allow`.

  Based on the fail-closed child-launch policy in the sandsower/rondo
  symphony fork (Apache-2.0), trimmed to this runtime's needs (no manifest
  contracts, no launch-decision state machine).
  """

  @operational_env_names ~w(PATH LANG LC_ALL LC_CTYPE TERM SHELL TMPDIR HOME USER LOGNAME)
  @forbidden_env_patterns [
    ~r/^GH_/i,
    ~r/GITHUB/i,
    ~r/SSH/i,
    ~r/MCP/i,
    ~r/AWS/i,
    ~r/AZURE/i,
    ~r/(?:TOKEN|SECRET|PASSWORD|CREDENTIAL|API[_A-Z]*KEY)/i
  ]

  # Ambient-git fences: a child workspace is a remote-less mirror checkout
  # by design, so no git credential helper or terminal prompt should ever
  # engage. Forced regardless of the inherited environment.
  @git_fence_env %{
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_TERMINAL_PROMPT" => "0",
    "GH_CONFIG_DIR" => "/dev/null"
  }

  @type option ::
          {:inherited_env, %{optional(String.t()) => String.t()}}
          | {:extra_allow, [String.t()]}

  @doc """
  Returns the scoped environment map for an agent child process.

  `:inherited_env` defaults to `System.get_env/0`; `:extra_allow` names
  variables that pass through even when they match a forbidden pattern
  (operator-declared provider keys). HOME and the operational allowlist
  always pass; everything else passes only when no forbidden pattern
  matches. Git fences are forced on top.
  """
  @spec scoped_env([option()]) :: %{optional(String.t()) => String.t()}
  def scoped_env(opts \\ []) do
    inherited = Keyword.get(opts, :inherited_env, System.get_env())
    extra_allow = Keyword.get(opts, :extra_allow, [])

    inherited
    |> Map.take(@operational_env_names)
    |> allowlisted(inherited, extra_allow)
    |> Map.merge(@git_fence_env)
  end

  defp allowlisted(acc, inherited, extra_allow) do
    Enum.reduce(inherited, acc, fn {name, value}, acc ->
      if name in extra_allow or not forbidden?(name), do: Map.put(acc, name, value), else: acc
    end)
  end

  defp forbidden?(name) do
    Enum.any?(@forbidden_env_patterns, &Regex.match?(&1, name))
  end
end
