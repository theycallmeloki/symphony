defmodule SymphonyElixir.Intents.RedkaConn do
  @moduledoc """
  Owns the Redix connection used by `SymphonyElixir.Intents.IntentStore`.

  Connects lazily and keeps retrying so symphony can start before redka is
  ready; store calls return `{:error, :redka_unavailable}` until the
  connection is up.
  """

  use GenServer
  require Logger

  @retry_backoff_ms 2_000
  @default_url "localhost:6379"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    send(self(), :connect)
    {:ok, %{conn: nil, url: configured_url()}}
  end

  @impl true
  def handle_info(:connect, %{conn: nil} = state) do
    case Redix.start_link(state.url, sync_connect: false, exit_on_close: false) do
      {:ok, pid} ->
        Logger.info("IntentStore redka connection established url=#{state.url}")
        {:noreply, %{state | conn: pid}}

      {:error, reason} ->
        Logger.warning("IntentStore redka connect failed reason=#{inspect(reason)}; retrying in #{@retry_backoff_ms}ms")
        Process.send_after(self(), :connect, @retry_backoff_ms)
        {:noreply, state}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.warning("IntentStore redka connection lost reason=#{inspect(reason)}; reconnecting in #{@retry_backoff_ms}ms")
    Process.send_after(self(), :connect, @retry_backoff_ms)
    {:noreply, %{state | conn: nil}}
  end

  defp configured_url do
    url =
      System.get_env("REDKA_URL") ||
        Application.get_env(:symphony_elixir, :intent_store_url) || @default_url

    normalize_url(url)
  end

  defp normalize_url("redis://" <> _ = url), do: url
  defp normalize_url("rediss://" <> _ = url), do: url

  defp normalize_url(url) when is_binary(url), do: "redis://" <> url
  defp normalize_url(_url), do: "redis://" <> @default_url
end
