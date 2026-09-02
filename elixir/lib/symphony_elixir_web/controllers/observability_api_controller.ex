defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec runs(Conn.t(), map()) :: Conn.t()
  def runs(conn, _params) do
    json(conn, Presenter.runs_payload())
  end

  @spec issue_runs(Conn.t(), map()) :: Conn.t()
  def issue_runs(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_runs_payload(issue_identifier) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :not_found} ->
        error_response(conn, 404, "not_found", "No journaled runs for this issue")
    end
  end

  @spec transcript(Conn.t(), map()) :: Conn.t()
  def transcript(conn, %{"issue_identifier" => issue_identifier, "run_index" => run_index}) do
    case Integer.parse(run_index) do
      {index, ""} when index > 0 ->
        root = SymphonyElixir.RunJournal.root()
        tail = parse_tail(conn.query_params)

        case SymphonyElixir.RunJournal.transcript_events(root, issue_identifier, index, tail) do
          [] ->
            error_response(conn, 404, "not_found", "No transcript for this run")

          events ->
            json(conn, %{
              issue_identifier: issue_identifier,
              run_index: index,
              event_count: length(events),
              events: events
            })
        end

      _ ->
        error_response(conn, 400, "bad_request", "run_index must be a positive integer")
    end
  end

  defp parse_tail(query_params) do
    case Map.get(query_params, "tail") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
