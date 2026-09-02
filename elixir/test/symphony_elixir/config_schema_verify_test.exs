defmodule SymphonyElixir.ConfigSchemaVerifyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Intents.Intent

  test "observability.auto_verify_enabled defaults to true and parses an override" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.observability.auto_verify_enabled == true

    assert {:ok, settings} = Schema.parse(%{"observability" => %{"auto_verify_enabled" => false}})
    assert settings.observability.auto_verify_enabled == false

    # untouched sibling keys keep their schema defaults
    assert {:ok, settings} = Schema.parse(%{"observability" => %{"auto_verify_enabled" => false}})
    assert settings.observability.build_events_enabled == true
  end

  test "a partial config keeps schema defaults for every omitted key" do
    assert {:ok, settings} = Schema.parse(%{"agent" => %{"max_turns" => 3}})
    assert settings.agent.max_turns == 3
    assert settings.agent.max_concurrent_agents == 10
    assert settings.pi.turn_timeout_ms == 1_800_000
  end

  test "no-verify label marks a thread as auto-verify disabled" do
    assert {:ok, intent} = Intent.new(%{"title" => "t", "labels" => ["no-verify"]})
    assert Intent.verify_disabled?(intent)
    refute Intent.verify_disabled?(%{intent | labels: []})
    # the verify label still marks an internal verification pass
    assert Intent.verify?(%{intent | labels: ["verify"]})
  end
end
