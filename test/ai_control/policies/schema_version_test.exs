defmodule AiControl.Policies.SchemaVersionTest do
  use ExUnit.Case, async: true

  alias AiControl.Policies.{Configuration, Draft, YAML}
  alias AiControl.Policy.Snapshot

  test "v1 checksum and resolved settings are frozen and never enable NER" do
    source = Configuration.default()
    {:ok, %{settings: settings}} = Configuration.validate(source)

    rules =
      Map.new(settings["rules"], fn {category, rule} ->
        {category,
         %{
           id: rule["id"],
           action: %{"allow" => :allow, "redact" => :redact, "block" => :block}[rule["action"]],
           threshold: rule["threshold"]
         }}
      end)

    {:ok, snapshot} = Snapshot.new(%{version: "legacy-1", settings: settings, rules: rules})
    # This vector is also checked against the pre-step-7 implementation.
    assert snapshot.checksum == "e28210ed886898b41587009b00b89a2760f3bbaf4acb504a9816f20c6716cf86"
    refute Snapshot.enabled?(snapshot, "ner", :input)
    refute "ner" in Snapshot.required_guards(snapshot, :input)
    assert {:error, _} = Configuration.validate(Map.put(source, "guards", %{"ner" => %{}}))
  end

  test "v2 profiles, detector sets and YAML have explicit compatible defaults" do
    for profile <- Configuration.profiles() do
      source = Configuration.default(2) |> Map.put("profile", profile)
      assert {:ok, %{settings: settings}} = Configuration.validate(source)
      assert settings["guards"]["ner"]["entities"] == ["person", "address"]
      assert settings["guards"]["ner"]["required"] == (profile != "relaxed")
      assert settings["tools"]["allowed_tools"] == []
      assert {:ok, ^source} = source |> YAML.encode() |> YAML.decode()
      assert source == source |> Draft.from_source() |> Draft.source()
    end
  end

  test "upgrading preserves restrictions and all explicit overrides" do
    source =
      Configuration.default()
      |> Map.put("allowed_models", [])
      |> Map.put("rules", %{"pii" => %{"action" => "block"}})

    upgraded = Configuration.upgrade(source)
    assert {:ok, %{settings: settings}} = Configuration.validate(upgraded)
    assert settings["rules"]["pii"]["action"] == "block"
    assert settings["allowed_models"] == []
    assert source["schema_version"] == 1
  end

  test "invalid entity sets, versions and tool identifiers have safe validation errors" do
    base = Configuration.default(2)

    for source <- [
          Map.put(base, "guards", %{"ner" => %{"entities" => ["DO-NOT-LOG"]}}),
          Map.put(base, "guards", %{"ner" => %{"entities" => []}}),
          Map.put(base, "detector_sets", %{"secret" => "unknown"}),
          Map.put(base, "tools", %{"allowed_tools" => ["*"]}),
          Map.put(base, "tools", %{"allowed_tools" => ["read_file", "read_file"]})
        ] do
      assert {:error, errors} = Configuration.validate(source)
      refute inspect(errors) =~ "DO-NOT-LOG"
    end
  end
end
