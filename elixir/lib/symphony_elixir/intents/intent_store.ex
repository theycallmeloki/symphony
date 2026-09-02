defmodule SymphonyElixir.Intents.IntentStore do
  @moduledoc """
  Intent storage facade for dashboard-registered job intents.

  Backends:
    * `:redka` — Redis-compatible server on SQLite (cluster default). A
      Redix connection is owned by `SymphonyElixir.Intents.RedkaConn`, started
      as an application child.
    * `:ets` — named in-memory table; used by tests and local development
      without a redka server.

  The store broadcasts observability updates on every mutation so the
  LiveView dashboard refreshes promptly.
  """

  require Logger

  alias SymphonyElixir.Intents.Intent
  alias SymphonyElixirWeb.ObservabilityPubSub

  @ets_table :symphony_intents

  @type store_error :: {:error, term()}

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc false
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_opts \\ []) do
    case backend() do
      :ets ->
        ensure_ets_table()
        :ignore

      :redka ->
        SymphonyElixir.Intents.RedkaConn.start_link()
    end
  end

  @spec create_intent(map()) :: {:ok, Intent.t()} | store_error()
  def create_intent(attrs) when is_map(attrs) do
    with {:ok, intent} <- Intent.new(attrs) do
      case write_intent(intent) do
        :ok ->
          broadcast()
          {:ok, intent}

        {:error, reason} = error ->
          Logger.error("IntentStore create failed reason=#{inspect(reason)}")
          error
      end
    end
  end

  @spec get_intent(String.t()) :: {:ok, Intent.t()} | {:error, :not_found | term()}
  def get_intent(id) when is_binary(id) do
    case read_intent(id) do
      nil -> {:error, :not_found}
      %Intent{} = intent -> {:ok, intent}
    end
  end

  @spec list_intents() :: {:ok, [Intent.t()]} | store_error()
  def list_intents do
    case list_intent_ids() do
      {:ok, ids} ->
        intents =
          ids
          |> Enum.flat_map(fn id ->
            case read_intent(id) do
              %Intent{} = intent -> [intent]
              _ -> []
            end
          end)
          |> Enum.sort_by(&intent_sort_key/1, {:desc, DateTime})

        {:ok, intents}

      {:error, _reason} = error ->
        error
    end
  end

  @spec list_intents_by_state([String.t()]) :: {:ok, [Intent.t()]} | store_error()
  def list_intents_by_state(state_names) when is_list(state_names) do
    wanted =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    with {:ok, intents} <- list_intents() do
      {:ok,
       Enum.filter(intents, fn %Intent{state: state} ->
         MapSet.member?(wanted, normalize_state(state))
       end)}
    end
  end

  @spec cancel_intent(String.t()) :: {:ok, Intent.t()} | {:error, :not_found | term()}
  def cancel_intent(id) when is_binary(id) do
    set_terminal_state(id, "cancelled", %{"reason" => "cancelled from dashboard"})
  end

  @doc """
  Moves an intent to a terminal state, recording an optional result map.
  Only open/running intents may transition; terminal states are final.
  """
  @spec set_terminal_state(String.t(), String.t(), map() | nil) ::
          {:ok, Intent.t()} | {:error, :not_found | :invalid_state | term()}
  def set_terminal_state(id, state, result \\ nil) when is_binary(id) and is_binary(state) do
    cond do
      not Intent.valid_state?(state) ->
        {:error, :invalid_state}

      true ->
        case get_intent(id) do
          {:error, :not_found} = error ->
            error

          {:ok, %Intent{state: current_state} = current} ->
            if Intent.terminal_state?(current_state) do
              {:error, :invalid_state}
            else
              updated = %{
                current
                | state: state,
                  result: result,
                  updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
              }

              case write_intent(updated) do
                :ok ->
                  broadcast()
                  {:ok, updated}

                {:error, reason} = error ->
                  Logger.error("IntentStore terminal transition failed id=#{id} state=#{state} reason=#{inspect(reason)}")
                  error
              end
            end

          {:error, reason} = error ->
            Logger.error("IntentStore read failed id=#{id} reason=#{inspect(reason)}")
            error
        end
    end
  end

  @doc false
  @spec redka_available?() :: boolean()
  def redka_available? do
    case Process.whereis(SymphonyElixir.Intents.RedkaConn) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  end

  # -- persistence ---------------------------------------------------------

  defp write_intent(%Intent{} = intent) do
    fields = Intent.to_store(intent)

    case backend() do
      :ets ->
        :ets.insert(@ets_table, {intent.id, fields})
        :ok

      :redka ->
        command([
          "HSET",
          intent_key(intent.id),
          Enum.flat_map(fields, fn {key, value} -> [to_string(key), value] end)
        ])
        |> case do
          {:ok, _} ->
            command(["SADD", ids_key(), intent.id])

          error ->
            error
        end
    end
  end

  defp read_intent(id) do
    case backend() do
      :ets ->
        case :ets.lookup(@ets_table, id) do
          [{^id, fields}] -> Intent.from_store(fields)
          _ -> nil
        end

      :redka ->
        case command(["HGETALL", intent_key(id)]) do
          {:ok, []} ->
            nil

          {:ok, fields} when is_list(fields) ->
            fields
            |> Enum.chunk_every(2)
            |> Map.new(fn [key, value] -> {key, value} end)
            |> Intent.from_store()

          {:error, _reason} ->
            nil
        end
    end
  end

  defp list_intent_ids do
    case backend() do
      :ets ->
        {:ok, @ets_table |> :ets.tab2list() |> Enum.map(fn {id, _fields} -> id end)}

      :redka ->
        command(["SMEMBERS", ids_key()])
    end
  end

  defp command(args) do
    case Process.whereis(SymphonyElixir.Intents.RedkaConn) do
      pid when is_pid(pid) ->
        Redix.command(pid, args, timeout: 5_000)

      _ ->
        {:error, :redka_unavailable}
    end
  end

  defp backend do
    Application.get_env(:symphony_elixir, :intent_store_backend, :redka)
  end

  defp ensure_ets_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        try do
          :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp broadcast do
    ObservabilityPubSub.broadcast_update()
  end

  defp intent_key(id), do: "intent:" <> id
  defp ids_key, do: "intents"

  defp normalize_state(state) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp intent_sort_key(%Intent{created_at: created_at}) when is_binary(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.from_unix!(0)
    end
  end

  defp intent_sort_key(%Intent{}), do: DateTime.from_unix!(0)
end
