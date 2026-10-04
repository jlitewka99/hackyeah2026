defmodule AiControl.Guards.PromptGuardTest do
  use ExUnit.Case, async: true

  alias AiControl.Audit.Serializer
  alias AiControl.Gateway.Config
  alias AiControl.Guards.Semantic
  alias AiControl.Guards.Semantic.PromptGuard
  alias AiControl.Policies.Configuration
  alias AiControl.Security.{GuardResult, SemanticEvidence}

  defp snapshot do
    source =
      Configuration.default(4)
      |> Map.put("guards", %{"semantic" => %{"provider" => "prompt_guard"}})
      |> Map.put("rules", %{"prompt_injection" => %{"threshold" => 0.8}})

    {:ok, config} = Configuration.validate(source)
    %{settings: config.settings}
  end

  defp response(score),
    do: %{
      "model_set" => PromptGuard.model_set(),
      "revision" => PromptGuard.revision(),
      "task" => "injection",
      "duration_us" => 1,
      "windows" => [%{"field_index" => 0, "start_byte" => 0, "end_byte" => 5, "score" => score}]
    }

  setup do
    %{config: Config.get() |> Keyword.put(:prompt_guard_http_plug, {Req.Test, __MODULE__})}
  end

  test "snapshot provider applies the exact threshold and exports content-free scores", %{
    config: config
  } do
    for {score, detected?} <- [{0.79, false}, {0.8, true}, {0.99, true}] do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, response(score)))
      assert {:ok, result} = Semantic.assess(["ąabc"], nil, snapshot(), config)
      assert result.detections != [] == detected?
      assert result.signals["injection_score"] == score
      assert GuardResult.valid?(result)

      projected =
        Serializer.data(%{
          "guards" => [%{"guard" => "semantic", "evidence" => result.evidence}]
        })

      assert get_in(projected, ["guards", Access.at(0), "evidence", "signal_kind"]) ==
               "classifier_score"

      refute Jason.encode!(projected) =~ "ąabc"
      refute SemanticEvidence.valid?(Map.put(result.evidence, "text", "PRIVATE"))
    end
  end

  test "wrong identity, coverage, scores and arbitrary content fail closed", %{config: config} do
    valid = response(0.9)
    [window] = valid["windows"]

    for invalid <- [
          Map.put(valid, "revision", String.duplicate("a", 40)),
          Map.put(valid, "windows", []),
          Map.put(valid, "windows", [window, window]),
          put_in(valid, ["windows"], [%{window | "start_byte" => 1}]),
          put_in(valid, ["windows"], [%{window | "end_byte" => 4}]),
          put_in(valid, ["windows"], [%{window | "score" => 1.1}]),
          Map.put(valid, "text", "PRIVATE")
        ] do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, invalid))
      assert {:error, :guard_unavailable} = Semantic.assess(["ąabc"], nil, snapshot(), config)
    end

    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :guard_unavailable} = Semantic.assess(["ąabc"], nil, snapshot(), config)
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, valid))

    assert {:error, :guard_unavailable} =
             Semantic.assess(["ąabc"], nil, snapshot(), Keyword.put(config, :response_bytes, 1))
  end

  test "readiness uses the selected identity; Prompt Guard cannot moderate", %{config: config} do
    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{
        status: "ready",
        model_set: PromptGuard.model_set(),
        revision: PromptGuard.revision()
      })
    )

    assert Semantic.ready?(Keyword.put(config, :injection_provider, "prompt_guard"))
    assert {:error, :guard_unavailable} = PromptGuard.analyze(["text"], "moderation", config)

    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{status: "ready", model_set: "qwen", revision: PromptGuard.revision()})
    )

    refute PromptGuard.ready?(config)
  end
end
