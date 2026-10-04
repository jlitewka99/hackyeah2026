defmodule AiControl.Approvals.ConfigurationTest do
  use ExUnit.Case, async: true

  alias AiControl.Policies.{Configuration, Draft}

  test "v6 opt-in preserves all v5 settings and roundtrips the editor" do
    source = Configuration.default(5)
    {:ok, old} = Configuration.validate(source)
    upgraded = Configuration.upgrade(source, 6)

    assert upgraded["review"] == %{
             "enabled" => false,
             "tools" => [],
             "llm_models" => [],
             "delegation_agents" => []
           }

    {:ok, new} = Configuration.validate(upgraded)

    base_settings =
      new.settings
      |> Map.drop(["schema_version", "review", "granite"])
      |> update_in(["guards"], &Map.delete(&1, "granite"))
      |> update_in(["rules"], &Map.delete(&1, "granite_violation"))

    assert base_settings ==
             Map.delete(old.settings, "schema_version")

    assert Map.drop(new.source, ["schema_version", "review", "granite"]) ==
             Map.delete(old.source, "schema_version")

    rebuilt = upgraded |> Draft.from_source() |> Draft.source()
    assert Configuration.validate(rebuilt) == {:ok, new}
    assert Configuration.upgrade(upgraded, 6) == upgraded
    refute new.settings["granite"]["enabled"]
  end

  test "unknown selectors cannot introduce review rules or guard overrides" do
    for review <- [
          %{"enabled" => "true"},
          %{"risk" => 0.7},
          %{"tools" => ["shell.exec"]},
          %{"llm_models" => ["*", "qwen3.5:4b"]},
          %{"delegation_agents" => ["not-an-agent"]}
        ] do
      assert {:error, _} =
               Configuration.validate(Map.put(Configuration.default(6), "review", review))
    end

    for version <- 1..5 do
      assert {:error, _} =
               Configuration.validate(
                 Map.put(Configuration.default(version), "review", %{"enabled" => true})
               )
    end
  end
end
