defmodule SymphonyElixirWeb.IntentsApiController do
  @moduledoc """
  JSON API for dashboard-registered job intents.

  Intents are stored in the redka-backed `SymphonyElixir.Intents.IntentStore`
  and dispatched by the orchestrator through the `redka` tracker adapter.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Intents.Intent
  alias SymphonyElixir.Intents.IntentStore

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    case IntentStore.list_intents() do
      {:ok, intents} ->
        json(conn, %{intents: Enum.map(intents, &Intent.to_api_map/1)})

      {:error, reason} ->
        error_response(conn, 503, :store_unavailable, "Intent store unavailable: #{inspect(reason)}")
    end
  end

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, %{"intent" => intent_params}) when is_map(intent_params) do
    case IntentStore.create_intent(stringify_keys(intent_params)) do
      {:ok, intent} ->
        conn
        |> put_status(:created)
        |> json(%{intent: Intent.to_api_map(intent)})

      {:error, {:missing_field, field}} ->
        error_response(conn, 422, :missing_field, "Missing required field: #{field}")

      {:error, {:invalid_state, state}} ->
        error_response(conn, 422, :invalid_state, "Invalid intent state: #{inspect(state)}")

      {:error, reason} ->
        error_response(conn, 503, :store_unavailable, "Intent store unavailable: #{inspect(reason)}")
    end
  end

  def create(conn, _params) do
    error_response(conn, 422, :missing_field, "Missing required field: title (expected body: {\"intent\": {...}})")
  end

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"intent_id" => intent_id}) do
    case IntentStore.get_intent(intent_id) do
      {:ok, intent} ->
        json(conn, %{intent: Intent.to_api_map(intent)})

      {:error, :not_found} ->
        error_response(conn, 404, :not_found, "Intent not found")

      {:error, reason} ->
        error_response(conn, 503, :store_unavailable, "Intent store unavailable: #{inspect(reason)}")
    end
  end

  @spec cancel(Conn.t(), map()) :: Conn.t()
  def cancel(conn, %{"intent_id" => intent_id}) do
    case IntentStore.cancel_intent(intent_id) do
      {:ok, intent} ->
        json(conn, %{intent: Intent.to_api_map(intent)})

      {:error, :not_found} ->
        error_response(conn, 404, :not_found, "Intent not found")

      {:error, :invalid_state} ->
        error_response(conn, 409, :invalid_state, "Intent is already in a terminal state")

      {:error, reason} ->
        error_response(conn, 503, :store_unavailable, "Intent store unavailable: #{inspect(reason)}")
    end
  end

  @spec activate(Conn.t(), map()) :: Conn.t()
  def activate(conn, %{"intent_id" => intent_id}) do
    case IntentStore.activate_intent(intent_id) do
      {:ok, intent} ->
        json(conn, %{intent: Intent.to_api_map(intent)})

      {:error, :not_found} ->
        error_response(conn, 404, :not_found, "Intent not found")

      {:error, :invalid_state} ->
        error_response(conn, 409, :invalid_state, "Only queued intents can be activated")

      {:error, reason} ->
        error_response(conn, 503, :store_unavailable, "Intent store unavailable: #{inspect(reason)}")
    end
  end

  @spec assign(Conn.t(), map()) :: Conn.t()
  def assign(conn, %{"intent_id" => intent_id} = params) do
    intent_params = params["intent"] || %{}
    changes = job_spec_changes(intent_params)

    cond do
      params["activate"] == true or params["activate"] == "true" ->
        handle_assign(conn, intent_id, :assign_and_activate_intent, changes)

      true ->
        handle_assign(conn, intent_id, :assign_intent, changes)
    end
  end

  defp handle_assign(conn, intent_id, fun, changes) do
    case apply(IntentStore, fun, [intent_id, changes]) do
      {:ok, intent} ->
        json(conn, %{intent: Intent.to_api_map(intent)})

      {:error, :not_found} ->
        error_response(conn, 404, :not_found, "Intent not found")

      {:error, :invalid_state} ->
        error_response(conn, 409, :invalid_state, "Only queued intents can be assigned")

      {:error, reason} ->
        error_response(conn, 503, :store_unavailable, "Intent store unavailable: #{inspect(reason)}")
    end
  end

  defp job_spec_changes(params) do
    Map.new(params, fn {key, value} -> {to_atom(key), value} end)
    |> then(fn changes ->
      changes
      |> Map.take([:description, :title, :repo])
      |> Enum.filter(fn {_key, value} -> is_binary(value) and String.trim(value) != "" end)
      |> Map.new()
    end)
  end

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)

  @doc """
  Dry-run workspace-diff listing: the parked workspace's un-committed
  edit paths vs its git HEAD (names only — nothing is emitted or read
  beyond the path list). `200` with `{"paths": [...]}` (empty array when
  clean), `409` when the thread has no parked workspace.
  """
  @spec dirty(Conn.t(), map()) :: Conn.t()
  def dirty(conn, %{"intent_id" => intent_id}) do
    case SymphonyElixir.Deployer.dirty_files(intent_id) do
      {:ok, paths} ->
        json(conn, %{intent_id: intent_id, paths: paths, dirty: length(paths)})

      {:error, :not_found} ->
        error_response(conn, 404, :not_found, "Intent not found")

      {:error, :no_parked_workspace} ->
        error_response(conn, 409, :no_parked_workspace, "No parked agent workspace for this thread")

      {:error, :workspace_missing} ->
        error_response(conn, 409, :workspace_missing, "Parked workspace no longer exists")

      {:error, reason} ->
        error_response(conn, 422, :dirty_unavailable, "Dirty listing unavailable: #{inspect(reason)}")
    end
  end

  @spec verify(Conn.t(), map()) :: Conn.t()
  def verify(conn, %{"intent_id" => intent_id}) do
    case IntentStore.get_intent(intent_id) do
      {:ok, %Intent{verify_for: verify_for}} when is_binary(verify_for) ->
        error_response(conn, 409, :is_verify, "Verification passes cannot be re-verified")

      {:ok, %Intent{} = intent} ->
        case verifyable_intent(intent) do
          {:ok, entry} ->
            case SymphonyElixir.BuildFusion.verify_thread(intent_id, entry) do
              {:ok, verify_id} ->
                json(conn, %{
                  verify: %{
                    intent_id: intent_id,
                    verify_intent: verify_id,
                    head: entry.head,
                    submitted: true
                  }
                })

              {:error, :verify_pending} ->
                error_response(
                  conn,
                  409,
                  :verify_pending,
                  "A verification pass for this thread is already queued or running"
                )

              {:error, reason} ->
                error_response(conn, 502, :verify_failed, "Could not queue verification: #{inspect(reason)}")
            end

          {:error, code, message} ->
            error_response(conn, 409, code, message)
        end

      {:error, :not_found} ->
        error_response(conn, 404, :not_found, "Intent not found")

      {:error, reason} ->
        error_response(conn, 503, :store_unavailable, "Intent store unavailable: #{inspect(reason)}")
    end
  end

  # Manual Verify-again needs a settled thread (the pass reads a stable
  # workspace), a repo binding, the request text to verify, and at least
  # one successful build whose head the pass references.
  defp verifyable_intent(%Intent{} = intent) do
    cond do
      intent.state not in ~w(awaiting done) ->
        {:error, :invalid_state,
         "Thread is #{intent.state}; wait until it settles (awaiting or done) before verifying"}

      not is_binary(intent.repo) ->
        {:error, :missing_repo, "Thread has no repository binding"}

      not is_binary(intent.description) or String.trim(intent.description) == "" ->
        {:error, :missing_description, "Thread has no request text to verify"}

      true ->
        case last_built_head(intent.id) do
          {:ok, head} when is_binary(head) and head != "" ->
            {:ok, %{repo: intent.repo, head: head, description: intent.description}}

          _ ->
            {:error, :no_built_head, "No successful build recorded for this thread yet"}
        end
    end
  end

  defp last_built_head(intent_id) do
    events = SymphonyElixir.RunJournal.issue_events(SymphonyElixir.RunJournal.root(), intent_id)

    case Enum.reverse(events)
         |> Enum.find(fn event -> Map.get(event, "event") == "build_succeeded" end) do
      %{"head" => head} when is_binary(head) and head != "" -> {:ok, head}
      _ -> {:error, :no_built_head}
    end
  end

  @spec close(Conn.t(), map()) :: Conn.t()
  def close(conn, %{"intent_id" => intent_id}) do
    case IntentStore.close_intent(intent_id) do
      {:ok, intent} ->
        json(conn, %{intent: Intent.to_api_map(intent)})

      {:error, :not_found} ->
        error_response(conn, 404, :not_found, "Intent not found")

      {:error, :invalid_state} ->
        error_response(conn, 409, :invalid_state, "Only awaiting threads can be closed")

      {:error, reason} ->
        error_response(conn, 503, :store_unavailable, "Intent store unavailable: #{inspect(reason)}")
    end
  end

  @spec deploy(Conn.t(), map()) :: Conn.t()
  def deploy(conn, %{"intent_id" => intent_id}) do
    case SymphonyElixir.Deployer.deploy(intent_id) do
      {:ok, %{head: head, state: :deployed}} ->
        json(conn, %{deployed: %{intent_id: intent_id, head: head, submitted: true}})

      {:ok, :no_changes} ->
        error_response(conn, 409, :no_changes, "Workspace has no edits to deploy")

      {:error, {:invalid_state, state}} ->
        error_response(conn, 409, :invalid_state, "Thread is #{state}; only awaiting threads can be deployed")

      {:error, :no_parked_workspace} ->
        error_response(conn, 409, :no_parked_workspace, "No parked agent workspace for this thread")

      {:error, :workspace_missing} ->
        error_response(conn, 409, :workspace_missing, "Parked workspace no longer exists")

      {:error, reason} ->
        error_response(conn, 502, :deploy_failed, "Deploy failed: #{inspect(reason)}")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, :method_not_allowed, "Method not allowed")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{
      error: %{
        code: code,
        message: message
      }
    })
  end

  defp stringify_keys(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end
end
