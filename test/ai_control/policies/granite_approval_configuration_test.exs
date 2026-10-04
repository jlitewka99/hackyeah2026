defmodule AiControl.Policies.GraniteApprovalConfigurationTest do
  use ExUnit.Case, async: true

  alias AiControl.Policies.{Configuration, ConfigurationV6, Draft, YAML}
  alias AiControl.Policy.Snapshot

  test "review-only v6 retains its stored settings, checksum and disabled Granite" do
    {:ok, base} = Configuration.validate(Configuration.default(5))
    review = ConfigurationV6.review_defaults() |> Map.put("enabled", true)
    source = Map.merge(base.source, %{"schema_version" => 6, "review" => review})
    expected = Map.merge(base.settings, %{"schema_version" => 6, "review" => review})
    assert {:ok, %{source: ^source, settings: ^expected}} = Configuration.validate(source)
    assert {:ok, %{settings: ^expected}} = Configuration.validate(expected)

    assert {:ok, config} =
             source |> Draft.from_source() |> Draft.source() |> Configuration.validate()

    assert config.settings == expected

    {:ok, snapshot} =
      Snapshot.from_version(%{id: Ecto.UUID.generate(), checksum: nil, settings: expected})

    assert Snapshot.valid?(snapshot)
    refute Snapshot.enabled?(snapshot, "granite", :input)
    assert {:ok, ^snapshot} = Snapshot.new(Map.from_struct(snapshot))
  end

  test "Granite-only v6 preserves its previous shape without adding human review" do
    source = Configuration.default(6) |> Map.delete("review")
    {:ok, config} = Configuration.validate(source)
    refute Map.has_key?(config.settings, "review")
    expected = config.settings
    assert {:ok, %{settings: ^expected}} = Configuration.validate(expected)

    assert {:ok, ^config} =
             source |> Draft.from_source() |> Draft.source() |> Configuration.validate()

    {:ok, snapshot} =
      Snapshot.from_version(%{id: Ecto.UUID.generate(), checksum: nil, settings: config.settings})

    assert Snapshot.valid?(snapshot)
    assert {:ok, ^snapshot} = Snapshot.new(Map.from_struct(snapshot))
  end

  test "both controls roundtrip independently and workflow defaults preserve their selectors" do
    source =
      Configuration.default(6)
      |> put_in(["granite", "enabled"], true)
      |> put_in(["review", "enabled"], true)
      |> put_in(["review", "tools"], ["file.write"])

    {:ok, config} = Configuration.validate(source)

    assert {:ok, ^config} =
             source |> Draft.from_source() |> Draft.source() |> Configuration.validate()

    assert {:ok, ^source} = source |> YAML.encode() |> YAML.decode()

    updated =
      source |> put_in(["budgets", "workflow", "max_calls"], nil) |> Configuration.upgrade(6)

    assert updated["granite"] == source["granite"]
    assert updated["review"] == source["review"]
    assert updated["budgets"]["workflow"]["max_calls"] == 50
    assert {:ok, ^config} = Configuration.validate(updated)
  end
end
