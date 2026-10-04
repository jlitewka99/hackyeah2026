defmodule AiControl.Policies.SemanticConfigurationTest do
  use ExUnit.Case, async: true

  alias AiControl.Policies.{Configuration, ConfigurationV2, Draft, YAML}
  alias AiControl.Policy.Snapshot

  test "all legacy resolved settings and checksums are preserved" do
    for version <- [1, 2], profile <- Configuration.profiles() do
      source = ConfigurationV2.default(version) |> Map.put("profile", profile)
      assert Configuration.validate(source) == ConfigurationV2.validate(source)
    end
  end

  test "v2 snapshot matches the independent pre-step-10 checksum vector" do
    {:ok, %{settings: settings}} = Configuration.validate(ConfigurationV2.default(2))

    rules =
      Map.new(settings["rules"], fn {category, rule} ->
        {category,
         %{
           id: rule["id"],
           action: %{"allow" => :allow, "redact" => :redact, "block" => :block}[rule["action"]],
           threshold: rule["threshold"]
         }}
      end)

    {:ok, snapshot} =
      Snapshot.new(%{version: "legacy-v2-vector", settings: settings, rules: rules})

    # Calculated using Configuration at bd4d6f1, before introducing v3.
    assert snapshot.checksum == "ccbdeb6bbeefda49c6deda3fe0080ce4110726a8102672b280ba03c11b87fedb"
  end

  test "v3 defaults and form/YAML roundtrips preserve label controls" do
    for profile <- Configuration.profiles() do
      source = Configuration.default(3) |> Map.put("profile", profile)
      assert {:ok, %{settings: settings}} = Configuration.validate(source)
      assert settings["guards"]["moderation"]["enabled"] == false
      assert settings["guards"]["moderation"]["stages"] == ["output"]

      assert settings["guards"]["semantic"]["severities"] ==
               if(profile == "strict", do: ~w(Unsafe Controversial), else: ["Unsafe"])

      assert {:ok, ^source} = source |> YAML.encode() |> YAML.decode()
      assert source == source |> Draft.from_source() |> Draft.source()

      rules =
        Map.new(settings["rules"], fn {key, rule} ->
          {key,
           %{
             id: rule["id"],
             action: %{"allow" => :allow, "redact" => :redact, "block" => :block}[rule["action"]],
             threshold: rule["threshold"]
           }}
        end)

      assert {:ok, snapshot} =
               Snapshot.new(%{version: "v3-vector", settings: settings, rules: rules})

      assert Snapshot.valid?(snapshot)
    end
  end

  test "unsupported labels, redact, numeric confidence and input moderation are rejected" do
    for overrides <- [
          %{"guards" => %{"semantic" => %{"severities" => ["DO-NOT-LOG"]}}},
          %{"guards" => %{"moderation" => %{"stages" => ["input"]}}},
          %{"rules" => %{"content_safety" => %{"action" => "redact"}}},
          %{"rules" => %{"prompt_injection" => %{"threshold" => 0.8}}},
          %{"guards" => %{"moderation" => %{"required" => true}}}
        ] do
      assert {:error, errors} =
               Configuration.validate(Map.merge(Configuration.default(3), overrides))

      refute inspect(errors) =~ "DO-NOT-LOG"
    end
  end

  test "upgrading preserves restrictions and explicitly replaces numeric injection thresholds" do
    source =
      Configuration.default(2)
      |> Map.put("allowed_models", [])
      |> Map.put("rules", %{"prompt_injection" => %{"action" => "allow", "threshold" => 0.9}})

    upgraded = Configuration.upgrade(source)
    assert upgraded["schema_version"] == 3
    assert upgraded["allowed_models"] == []
    assert upgraded["rules"]["prompt_injection"] == %{"action" => "allow"}
    assert {:ok, _} = Configuration.validate(upgraded)
  end

  test "dataset is frozen, balanced and family-disjoint" do
    raw = File.read!("priv/benchmarks/semantic-pl.v1.jsonl")

    assert Base.encode16(:crypto.hash(:sha256, raw), case: :lower) ==
             String.trim(File.read!("priv/benchmarks/semantic-pl.v1.sha256"))

    cases = raw |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert length(cases) == 240
    assert length(Enum.uniq_by(cases, & &1["id"])) == 240

    assert Enum.all?(Enum.group_by(cases, & &1["family"]), fn {_, members} ->
             length(Enum.uniq_by(members, & &1["split"])) == 1
           end)

    for group <- ~w(safe direct indirect pii), split <- ~w(calibration test) do
      assert Enum.count(cases, &(&1["group"] == group && &1["split"] == split)) == 25
    end
  end
end
