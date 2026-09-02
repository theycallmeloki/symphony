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
