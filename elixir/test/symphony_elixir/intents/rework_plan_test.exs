defmodule SymphonyElixir.Intents.ReworkPlanTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Intents.ReworkPlan

  @moduletag :tmp_dir

  describe "parse_file/1" do
    test "normalizes a structured plan", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rework.json")

      File.write!(path, """
      {
        "summary": "env interface missing",
        "items": [
          {"category": "platform_contract", "severity": "blocking", "problem": "no OUT write", "change": "write result.json to $OUT"},
          {"category": "test_gap", "severity": "should", "problem": "no seed test", "change": "assert determinism"}
        ]
      }
      """)

      plan = ReworkPlan.parse_file(path)
      assert plan["schema"] == "rework-plan-v1"
      assert plan["summary"] == "env interface missing"
      assert [first, second] = plan["items"]
      assert first["category"] == "platform_contract"
      assert first["change"] == "write result.json to $OUT"
      assert second["category"] == "test_gap"
    end

    test "degrades a JSON doc without items to one fallback item", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rework.json")
      File.write!(path, ~s({"note": "everything is wrong"}))

      plan = ReworkPlan.parse_file(path)
      assert [%{"category" => "other", "severity" => "blocking"} | _] = plan["items"]
    end

    test "returns nil for invalid JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rework.json")
      File.write!(path, "not json at all {")

      assert ReworkPlan.parse_file(path) == nil
    end

    test "returns nil when the file is absent" do
      assert ReworkPlan.parse_file("/nonexistent/rework.json") == nil
    end

    test "normalizes unknown categories and missing fields", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rework.json")

      File.write!(path, """
      {
        "items": [{"category": "nonsense", "problem": "x"}],
        "extra": "ignored"
      }
      """)

      plan = ReworkPlan.parse_file(path)
      assert [item] = plan["items"]
      assert item["category"] == "other"
      assert item["severity"] == "blocking"
      assert item["problem"] == "x"
      assert item["change"] == ""
    end
  end

  describe "block/1" do
    test "renders itemized plan into a prompt block" do
      plan = %{
        "summary" => "two gaps",
        "items" => [
          %{"category" => "contract", "severity" => "blocking", "problem" => "wrong total", "change" => "sum kept dice"},
          %{"category" => "other", "severity" => "should", "problem" => "no seed", "change" => ""}
        ]
      }

      block = ReworkPlan.block(plan)
      assert block =~ "## Rework plan"
      assert block =~ "NOT satisfied"
      assert block =~ "- [ ] 1. contract (blocking): wrong total"
      assert block =~ "- [ ] 2. other (should): no seed"
      assert block =~ "Summary: two gaps"
      refute block =~ "- [ ] 2. other (should): no seed — change:"
    end

    test "renders a summary-only plan" do
      block = ReworkPlan.block(%{"summary" => "just a summary", "items" => []})
      assert block =~ "just a summary"
    end

    test "returns nil when nothing actionable" do
      assert ReworkPlan.block(%{"summary" => "", "items" => []}) == nil
      assert ReworkPlan.block(nil) == nil
    end
  end
end
