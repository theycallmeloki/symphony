defmodule SymphonyElixir.Intents.ReworkPlan do
  @moduledoc """
  Structured rework-plan artifact bridging a failed verification pass and
  the thread's next dispatch.

  When a read-only verification pass concludes NOT_SOLVED it writes
  `rework.json` (beside `verify.txt`) in its workspace: a JSON object
  whose items turn the failure into an actionable plan. The verdict
  recorder stores that plan on the thread's intent; the next dispatch of
  that thread prepends the rendered plan to the agent prompt (idea
  ported from the ReviewReworkPlan contract in the issuepilot fork —
  verification stops being a pass/fail journal entry and starts
  structurally driving the re-run).

  Lifecycle: NOT_SOLVED writes/replaces the plan (undispatched); the
  first dispatch that carries it marks it dispatched; a later SOLVED
  verdict clears it.
  """

  @schema "rework-plan-v1"
  @file_name "rework.json"

  @categories ~w(contract correctness test_gap evidence_gap platform_contract env_interface security other)

  @doc "Workspace-root file name the verification pass writes."
  def file_name, do: @file_name

  @doc """
  Reads and normalizes the plan file at `path`.

  Returns a normalized plan map (`%{"summary" => String.t(),
  "items" => [map]}`) or `nil` when the file is absent or not valid JSON.
  A JSON document that is not the expected shape degrades to a single
  fallback item so the pass's text is never lost.
  """
  @spec parse_file(Path.t()) :: map() | nil
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} -> normalize(content)
      {:error, _reason} -> nil
    end
  end

  @doc """
  Renders a plan map as the markdown block prepended to a re-dispatch
  prompt, or `nil` when the plan carries nothing actionable (no items and
  no summary).
  """
  @spec block(map() | nil) :: String.t() | nil
  def block(%{"items" => items} = plan) when is_list(items) and items != [] do
    item_lines =
      items
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {item, index} -> "- [ ] #{index}. #{render_item(item)}" end)

    summary = summary_line(plan)

    """
    ## Rework plan (from the verification pass)

    The verification pass that reviewed this work concluded the request is
    NOT satisfied. Address every item below in this pass. Where you believe
    an item is already handled, say so explicitly with evidence — do not
    stop early while actionable items remain.
    #{summary}
    #{item_lines}
    """
  end

  def block(%{"summary" => summary}) when is_binary(summary) and summary != "" do
    """
    ## Rework plan (from the verification pass)

    The verification pass that reviewed this work concluded the request is
    NOT satisfied. Summary of what is missing:

    #{String.trim(summary)}
    """
  end

  def block(_plan), do: nil

  defp normalize(content) do
    case Jason.decode(content) do
      {:ok, %{"items" => items} = plan} when is_list(items) ->
        %{
          "schema" => @schema,
          "summary" => to_string(plan["summary"] || ""),
          "items" => Enum.map(items, &normalize_item/1)
        }

      {:ok, _other} ->
        %{
          "schema" => @schema,
          "summary" => "",
          "items" => [
            %{
              "category" => "other",
              "severity" => "blocking",
              "problem" => String.trim(content),
              "change" => ""
            }
          ]
        }

      {:error, _reason} ->
        nil
    end
  end

  defp normalize_item(%{} = item) do
    %{
      "category" => normalize_category(item["category"]),
      "severity" => to_string(item["severity"] || "blocking"),
      "problem" => to_string(item["problem"] || ""),
      "change" => to_string(item["change"] || "")
    }
  end

  defp normalize_item(_other) do
    %{"category" => "other", "severity" => "blocking", "problem" => "", "change" => ""}
  end

  defp normalize_category(category) do
    category = to_string(category || "other")

    if category in @categories, do: category, else: "other"
  end

  defp render_item(%{"problem" => problem} = item) when is_binary(problem) and problem != "" do
    category = item["category"] || "other"
    severity = item["severity"] || "blocking"
    change = item["change"]

    change_part =
      if is_binary(change) and change != "" do
        " — change: #{String.trim(change)}"
      else
        ""
      end

    "#{category} (#{severity}): #{String.trim(problem)}#{change_part}"
  end

  defp render_item(%{"change" => change}) when is_binary(change) and change != "" do
    "other (blocking): change: #{String.trim(change)}"
  end

  defp render_item(_item), do: "other (blocking): unspecified gap"

  defp summary_line(%{"summary" => summary}) when is_binary(summary) and summary != "" do
    "\nSummary: #{String.trim(summary)}\n"
  end

  defp summary_line(_plan), do: "\n"
end
