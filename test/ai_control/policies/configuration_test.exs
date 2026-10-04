defmodule AiControl.Policies.ConfigurationTest do
  use ExUnit.Case, async: true

  alias AiControl.Policies.{Configuration, Draft, YAML}

  test "profiles resolve without inventing budget limits" do
    for {profile, threshold, pii, required} <- [
          {"relaxed", 0.9, "redact", false},
          {"balanced", 0.8, "redact", true},
          {"strict", 0.65, "block", true}
        ] do
      assert {:ok, %{settings: settings}} =
               Configuration.validate(Map.put(Configuration.default(), "profile", profile))

      assert settings["rules"]["pii"]["action"] == pii
      assert settings["rules"]["prompt_injection"]["threshold"] == threshold
      assert settings["guards"]["semantic"]["required"] == required
      assert settings["guards"]["semantic"]["stages"] == ["input"]
      assert settings["budgets"]["organization"]["tokens_per_hour"] == nil
    end
  end

  test "explicit field overrides win over profiles" do
    source =
      Configuration.default()
      |> Map.put("profile", "strict")
      |> Map.put("rules", %{
        "pii" => %{"action" => "redact"},
        "prompt_injection" => %{"threshold" => 0.95}
      })

    assert {:ok, %{settings: settings}} = Configuration.validate(source)
    assert settings["rules"]["pii"]["action"] == "redact"
    assert settings["rules"]["prompt_injection"]["threshold"] == 0.95
  end

  test "YAML exports round trip scalars, empty lists and empty mappings" do
    source =
      Configuration.default()
      |> Map.put("allowed_agents", [])
      |> Map.put("budgets", %{"agent" => %{"requests_per_hour" => 0, "tokens_per_hour" => nil}})
      |> Map.put("guards", %{"semantic" => %{"required" => false}})

    assert {:ok, ^source} = source |> YAML.encode() |> YAML.decode()
  end

  test "minimal YAML receives the same optional defaults as the form" do
    assert {:ok, source} =
             YAML.decode(
               ~s(schema_version: 1\nprofile: balanced\nallowed_models: ["deepseek-flash"]\nallowed_agents: ["*"])
             )

    assert source == Configuration.default()
    assert Draft.from_source(source).valid?
  end

  test "invalid YAML cannot silently choose a document or duplicate key" do
    cases = [
      "schema_version: 1\nprofile: balanced\nprofile: strict\nallowed_models: []\nallowed_agents: []",
      YAML.encode(Configuration.default()) <> "---\n" <> YAML.encode(Configuration.default()),
      "a: &x [1]\nb: *x",
      "profile: !custom balanced",
      "rules: {pii: {action: redact, action: block}}",
      "[broken",
      "",
      String.duplicate("a", 65_537),
      <<255>>
    ]

    for text <- cases, do: assert(match?({:error, _}, YAML.decode(text)))
  end

  test "unknown fields and invalid nested values are rejected with safe paths" do
    base = Configuration.default()

    cases = [
      Map.put(base, "unsafe secret", "DO-NOT-LOG"),
      Map.put(base, "rules", %{"pii" => %{"threshold" => 1.01}}),
      Map.put(base, "guards", %{"pii" => %{"enabled" => false}}),
      Map.put(base, "allowed_models", ["*", "deepseek-flash"]),
      Map.put(base, "agent_models", %{"not-a-uuid" => []}),
      Map.put(base, "budgets", %{"organization" => %{"tokens_per_hour" => -1}})
    ]

    for source <- cases do
      assert {:error, errors} = Configuration.validate(source)
      refute inspect(errors) =~ "DO-NOT-LOG"
      refute inspect(errors) =~ "unsafe secret"
    end
  end

  test "form normalization feeds the same validator and preserves explicit zeroes" do
    attrs = %{
      "profile" => "balanced",
      "allowed_models" => "deepseek-flash",
      "allowed_agents" => ["*"],
      "rules" => %{"pii" => %{"action" => "block", "threshold" => "0"}},
      "budgets" => %{"organization" => %{"requests_per_hour" => "0", "tokens_per_hour" => ""}}
    }

    assert {:ok, _, %{source: source}} = Draft.validate(attrs)
    assert source["rules"]["pii"]["threshold"] == 0
    assert source["budgets"]["organization"]["requests_per_hour"] == 0
    assert {:ok, %{source: ^source}} = Configuration.validate(source)
    assert {:ok, ^source} = YAML.decode(YAML.encode(source))
  end

  test "browser untouched-input markers never become policy fields" do
    attrs = %{
      "profile" => "strict",
      "allowed_models" => "deepseek-flash",
      "allowed_agents" => ["*"],
      "rules" => %{"pii" => %{"action" => "", "threshold" => "", "_unused_threshold" => ""}},
      "budgets" => %{
        "organization" => %{"requests_per_hour" => "", "_unused_requests_per_hour" => ""}
      }
    }

    assert {:ok, _, %{settings: settings}} = Draft.validate(attrs)
    assert settings["rules"]["pii"]["action"] == "block"
    assert settings["budgets"]["organization"]["requests_per_hour"] == nil
  end

  test "malformed nested form values report errors without raising" do
    attrs = %{
      "profile" => "balanced",
      "allowed_models" => "deepseek-flash",
      "allowed_agents" => ["*"]
    }

    for {key, value} <- [
          {"rules", nil},
          {"rules", %{"pii" => []}},
          {"guards", %{"pii" => nil}},
          {"budgets", %{"agent" => "invalid"}},
          {"agent_models", nil}
        ] do
      assert {:error, _, _} = Draft.validate(Map.put(attrs, key, value))
    end
  end
end
