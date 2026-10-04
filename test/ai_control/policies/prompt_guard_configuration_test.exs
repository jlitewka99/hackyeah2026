defmodule AiControl.Policies.PromptGuardConfigurationTest do
  use ExUnit.Case, async: true

  alias AiControl.Policies.{Configuration, Draft, YAML}

  test "v4 Qwen upgrade preserves enforcement defaults and supports draft roundtrip" do
    source = Configuration.default(3)
    {:ok, original} = Configuration.validate(source)
    upgraded = Configuration.upgrade(source, 4)
    {:ok, result} = Configuration.validate(upgraded)
    assert result.settings["guards"]["semantic"]["provider"] == "qwen"

    assert Map.delete(result.settings, "schema_version")
           |> put_in(
             ["guards", "semantic"],
             Map.delete(result.settings["guards"]["semantic"], "provider")
           ) == Map.delete(original.settings, "schema_version")

    assert {:ok, parsed} = YAML.decode(YAML.encode(upgraded))

    assert Draft.from_source(parsed) |> Draft.source() |> Configuration.validate() ==
             {:ok, result}
  end

  test "Prompt Guard thresholds and provider are versioned; invalid values are rejected" do
    source =
      Configuration.default(4)
      |> Map.put("guards", %{"semantic" => %{"provider" => "prompt_guard"}})

    for threshold <- [0, 0.8, 1] do
      policy = Map.put(source, "rules", %{"prompt_injection" => %{"threshold" => threshold}})
      assert {:ok, config} = Configuration.validate(policy)
      assert config.settings["rules"]["prompt_injection"]["threshold"] == threshold

      assert {:ok, _} =
               policy |> Draft.from_source() |> Draft.source() |> Configuration.validate()
    end

    for provider <- ["unknown", nil, 42],
        do:
          assert(
            match?(
              {:error, _},
              Configuration.validate(put_in(source, ["guards", "semantic", "provider"], provider))
            )
          )

    for threshold <- [-0.1, 1.1, "0.8"],
        do:
          assert(
            match?(
              {:error, _},
              Configuration.validate(
                Map.put(source, "rules", %{"prompt_injection" => %{"threshold" => threshold}})
              )
            )
          )

    assert {:error, _} =
             Configuration.validate(
               put_in(source, ["guards", "moderation"], %{"provider" => "prompt_guard"})
             )

    assert {:error, _} =
             Configuration.validate(
               Map.put(source, "rules", %{"prompt_injection" => %{"action" => "redact"}})
             )
  end
end
