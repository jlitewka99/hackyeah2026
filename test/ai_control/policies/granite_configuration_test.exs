defmodule AiControl.Policies.GraniteConfigurationTest do
  use ExUnit.Case, async: true

  alias AiControl.Policies.{Configuration, Draft, YAML}
  alias AiControl.Policy.Snapshot

  test "v6 is opt-in and legacy snapshots keep their settings and checksums" do
    for version <- 1..5 do
      {:ok, old} = Configuration.validate(Configuration.default(version))
      {:ok, again} = Configuration.validate(old.settings)
      assert again.settings == old.settings
      refute Map.has_key?(old.settings, "granite")
      {:ok, upgraded} = old.source |> Configuration.upgrade(6) |> Configuration.validate()
      refute upgraded.settings["granite"]["enabled"]
      assert Configuration.workflow?(upgraded.settings)
      assert upgraded.settings["budgets"]["workflow"]["max_tokens"] == 10_000
      assert {:ok, ^upgraded} = Configuration.validate(upgraded.source)
    end
  end

  test "draft, import and export preserve BYOC polarity and exact selectors" do
    source =
      Configuration.default(6)
      |> put_in(["granite", "enabled"], true)
      |> put_in(["granite", "privileged_resources", "paths"], ["reports/a,b.txt"])
      |> put_in(["granite", "criteria", "own.v1"], %{
        "task" => "tool_action",
        "text" => "The action serves the goal.",
        "block_on" => "no",
        "enabled" => true
      })

    assert Draft.source(Draft.from_source(source)) == source
    assert {:ok, imported} = source |> YAML.encode() |> YAML.decode()
    assert {:ok, config} = Configuration.validate(imported)
    assert config.source == source
    assert {:ok, validated} = Configuration.validate(config.settings)
    assert validated.settings == config.settings

    assert {:ok, snapshot} =
             Snapshot.from_version(%{
               id: Ecto.UUID.generate(),
               checksum: nil,
               settings: config.settings
             })

    assert Snapshot.valid?(snapshot)
  end

  test "mandatory behavior, criterion coverage and selector bounds cannot be overridden" do
    source = Configuration.default(6) |> put_in(["granite", "enabled"], true)

    for invalid <- [
          put_in(source, ["granite", "suspicious_threshold"], 1.1),
          put_in(source, ["granite", "privileged_resources", "paths"], ["*"]),
          put_in(source, ["granite", "criteria", "tool_alignment.v1", "block_on"], "allow"),
          put_in(source, ["granite", "criteria", "groundedness.v1", "enabled"], false),
          put_in(source, ["guards", "granite"], %{"enabled" => true, "required" => false}),
          put_in(source, ["rules", "granite_violation"], %{"action" => "allow"}),
          put_in(source, ["budgets", "workflow", "max_calls"], nil)
        ] do
      assert {:error, _} = Configuration.validate(invalid)
    end
  end

  test "applying workflow defaults keeps v6 Granite and Knowledge choices" do
    source =
      Configuration.default(6)
      |> put_in(["granite", "enabled"], true)
      |> put_in(["granite", "suspicious_threshold"], 0.4)
      |> put_in(["knowledge", "enabled"], true)
      |> put_in(["budgets", "workflow", "max_calls"], nil)

    upgraded = Configuration.upgrade(source, 5)
    assert upgraded["schema_version"] == 6
    assert upgraded["granite"] == source["granite"]
    assert upgraded["knowledge"] == source["knowledge"]
    assert upgraded["budgets"]["workflow"]["max_calls"] == 50
    assert {:ok, _} = Configuration.validate(upgraded)
  end
end
