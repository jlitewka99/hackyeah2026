defmodule AiControl.Policies.KnowledgeConfigurationTest do
  use ExUnit.Case, async: true

  alias AiControl.Policies.{Configuration, Draft}

  test "v5 defaults are opt-in and strict settings validate" do
    assert {:ok, config} = Configuration.validate(Configuration.default(5))
    refute config.settings["knowledge"]["enabled"]
    refute config.settings["knowledge"]["memory_write_enabled"]
    assert config.settings["ner_model_set"] == "pl-nkjp.v2"

    for knowledge <- [
          %{"enabled" => "true"},
          %{"sources" => ["web"]},
          %{"trust_levels" => []},
          %{"unknown" => true}
        ] do
      assert {:error, _} =
               Configuration.default(5)
               |> Map.put("knowledge", knowledge)
               |> Configuration.validate()
    end
  end

  test "upgrade preserves existing Prompt Guard provider and threshold" do
    source =
      Configuration.default(4)
      |> Map.put("guards", %{"semantic" => %{"provider" => "prompt_guard"}})
      |> Map.put("rules", %{"prompt_injection" => %{"threshold" => 0.87}})

    assert {:ok, config} = source |> Configuration.upgrade(5) |> Configuration.validate()
    assert config.settings["rules"]["prompt_injection"]["threshold"] == 0.87
    assert config.settings["guards"]["semantic"]["provider"] == "prompt_guard"
  end

  test "form round-trip retains Knowledge controls and pinned NER rules" do
    source =
      Configuration.default(5)
      |> Map.put("knowledge", %{
        "enabled" => true,
        "memory_write_enabled" => false,
        "sources" => ["document"],
        "trust_levels" => ["internal"]
      })

    assert {:ok, config} =
             source |> Draft.from_source() |> Draft.source() |> Configuration.validate()

    assert config.settings["knowledge"] == source["knowledge"]
    assert config.settings["ner_model_set"] == "pl-nkjp.v2"
  end
end
