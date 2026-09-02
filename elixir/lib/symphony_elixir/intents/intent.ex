defmodule SymphonyElixir.Intents.Intent do
  @moduledoc """
  A dashboard-registered job intent for the Symphony orchestrator.

  Intents live in the redka-backed IntentStore and surface to the
  orchestrator through the `redka` tracker adapter. A single intent maps to
  one dispatchable issue (and therefore one workspace) identified by its id.
  """

  alias SymphonyElixir.Intents.Intent

  @states %{
    "open" => :active,
    "running" => :active,
    "done" => :terminal,
    "failed" => :terminal,
    "cancelled" => :terminal
  }

  defstruct [
    :id,
    :title,
    :description,
    :state,
    :repo,
    :labels,
    :result,
    :created_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          description: String.t() | nil,
          state: String.t(),
          repo: String.t() | nil,
          labels: [String.t()],
          result: map() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs =
      Map.new(attrs, fn {key, value} -> {to_atom(key), value} end)

    with {:ok, title} <- required_string(attrs, :title),
         {:ok, state} <- default_state(attrs[:state]) do
      now = iso_now()

      intent = %Intent{
        id: attrs[:id] || generate_id(),
        title: title,
        description: blank_to_nil(attrs[:description]),
        state: state,
        repo: blank_to_nil(attrs[:repo]),
        labels: normalize_labels(attrs[:labels]),
        result: nil,
        created_at: now,
        updated_at: now
      }

      {:ok, intent}
    end
  end

  @spec from_store(map()) :: t()
  def from_store(fields) when is_map(fields) do
    %Intent{
      id: fields["id"],
      title: fields["title"] || "",
      description: fields["description"],
      state: fields["state"] || "open",
      repo: fields["repo"],
      labels: decode_json_list(fields["labels"]),
      result: decode_json_map(fields["result"]),
      created_at: fields["created_at"],
      updated_at: fields["updated_at"]
    }
  end

  @spec to_store(t()) :: map()
  def to_store(%Intent{} = intent) do
    %{
      "id" => store_value(intent.id),
      "title" => store_value(intent.title),
      "description" => store_value(intent.description),
      "state" => store_value(intent.state),
      "repo" => store_value(intent.repo),
      "labels" => Jason.encode!(intent.labels || []),
      "result" => encode_json_map(intent.result),
      "created_at" => store_value(intent.created_at),
      "updated_at" => store_value(intent.updated_at)
    }
  end

  defp store_value(nil), do: ""
  defp store_value(value) when is_binary(value), do: value
  defp store_value(value), do: to_string(value)

  @spec valid_state?(String.t()) :: boolean()
  def valid_state?(state) when is_binary(state) do
    Map.has_key?(@states, state)
  end

  @spec terminal_state?(String.t()) :: boolean()
  def terminal_state?(state) do
    Map.get(@states, state) == :terminal
  end

  @spec to_api_map(t()) :: map()
  def to_api_map(%Intent{} = intent) do
    %{
      id: intent.id,
      title: intent.title,
      description: intent.description,
      state: intent.state,
      repo: intent.repo,
      labels: intent.labels || [],
      result: intent.result,
      created_at: intent.created_at,
      updated_at: intent.updated_at
    }
  end


  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)

  defp required_string(attrs, key) do
    case blank_to_nil(attrs[key]) do
      nil -> {:error, {:missing_field, key}}
      value when is_binary(value) -> {:ok, String.trim(value)}
    end
  end

  defp default_state(state) when is_binary(state) do
    normalized = state |> String.trim() |> String.downcase()

    if valid_state?(normalized) do
      {:ok, normalized}
    else
      {:error, {:invalid_state, state}}
    end
  end

  defp default_state(nil), do: {:ok, "open"}

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_labels(labels) when is_binary(labels) do
    labels
    |> String.split(",", trim: true)
    |> normalize_labels()
  end

  defp normalize_labels(_labels), do: []

  defp generate_id do
    "int-" <>
      Integer.to_string(System.system_time(:microsecond)) <>
      "-" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp iso_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp decode_json_list(nil), do: []
  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_json_map(nil), do: nil
  defp decode_json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp encode_json_map(nil), do: ""
  defp encode_json_map(map), do: Jason.encode!(map)
end
