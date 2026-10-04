defmodule AiControl.Policies.WorkflowConfigurationTest do
  use ExUnit.Case, async: true

  alias AiControl.Policies.{Configuration, Draft}

  test "v5 has finite defaults and leaves every historical settings map unchanged" do
    for v <- 1..4 do
      {:ok, old} = Configuration.validate(Configuration.default(v))
      assert {:ok, validated} = Configuration.validate(old.settings)
      assert validated.settings == old.settings
      {:ok, upgraded} = old.source |> Configuration.upgrade(5) |> Configuration.validate()
      assert upgraded.settings["budgets"]["workflow"]["max_tokens"] == 10_000

      assert Map.drop(upgraded.settings, [
               "schema_version",
               "budgets",
               "knowledge",
               "ner_model_set"
             ]) ==
               Map.drop(
                 elem(Configuration.validate(Configuration.upgrade(old.source, 4)), 1).settings,
                 ["schema_version", "budgets"]
               )
    end
  end

  test "an existing Knowledge v5 draft adds workflow caps without changing its source controls" do
    source =
      Configuration.default(5)
      |> Map.put("knowledge", %{
        "enabled" => true,
        "memory_write_enabled" => false,
        "sources" => ["memory"],
        "trust_levels" => ["internal"]
      })
      |> Map.put("ner_model_set", "pl-nkjp.v1")
      |> put_in(["budgets", "workflow"], %{"tool_calls" => 7})

    upgraded = Configuration.upgrade(source, 5)
    assert {:ok, config} = Configuration.validate(upgraded)
    assert config.settings["knowledge"] == source["knowledge"]
    assert config.settings["ner_model_set"] == "pl-nkjp.v1"
    assert config.settings["budgets"]["workflow"]["tool_calls"] == 7
    assert config.settings["budgets"]["workflow"]["max_calls"] == 50
    assert Configuration.upgrade(upgraded, 5) == upgraded
  end

  test "explicit tool limit survives upgrade, null is rejected, and draft carries all fields" do
    source = Configuration.default(4) |> Map.put("budgets", %{"workflow" => %{"tool_calls" => 0}})
    upgraded = Configuration.upgrade(source, 5)
    assert upgraded["budgets"]["workflow"]["tool_calls"] == 0
    assert Draft.source(Draft.from_source(upgraded)) == upgraded

    for value <- [nil, -1, "10", 1.5] do
      invalid = put_in(upgraded, ["budgets", "workflow", "max_tokens"], value)
      assert {:error, _} = Configuration.validate(invalid)
    end

    assert {:error, _} =
             upgraded |> put_in(["budgets", "workflow", "unknown"], 3) |> Configuration.validate()
  end
end
