defmodule AiControl.Guards.NerTest do
  use ExUnit.Case, async: true

  alias AiControl.Gateway.Config
  alias AiControl.Guards.Ner
  alias AiControl.Policies.Configuration

  defp config, do: Config.get() |> Keyword.put(:ner_http_plug, {Req.Test, __MODULE__})

  defp snapshot do
    {:ok, %{settings: settings}} = Configuration.validate(Configuration.default(2))
    %{settings: settings}
  end

  defp finding(type, first, last) do
    %{
      "field_index" => 0,
      "type" => type,
      "score" => 0.85,
      "detector_id" => "ner.#{type}.v1",
      "start_byte" => first,
      "end_byte" => last
    }
  end

  test "selected entities only, byte offsets and content-free findings" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        model_set: "pl-nkjp.v1",
        detections: [finding("person", 5, 8), finding("organization", 5, 8)]
      })
    end)

    assert {:ok, result} = Ner.assess(["😀 Jan"], nil, snapshot(), config())
    assert [%{rule_id: "ner.person.v1"}] = result.detections
    refute inspect(result) =~ "Jan"
  end

  test "invalid Unicode ranges, indexes, labels, scores and model versions fail closed" do
    for entry <- [
          finding("person", 1, 3),
          finding("person", 5, 9),
          finding("unknown", 5, 8),
          Map.put(finding("person", 5, 8), "field_index", 8),
          Map.put(finding("person", 5, 8), "score", 1.1)
        ] do
      Req.Test.stub(
        __MODULE__,
        &Req.Test.json(&1, %{model_set: "pl-nkjp.v1", detections: [entry]})
      )

      assert {:error, :guard_unavailable} = Ner.assess(["😀 Jan"], nil, snapshot(), config())
    end

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{model_set: "other", detections: []}))
    assert {:error, :guard_unavailable} = Ner.assess(["😀 Jan"], nil, snapshot(), config())
  end

  test "transport errors and oversized bodies are controlled without retries" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :guard_unavailable} = Ner.assess(["safe"], nil, snapshot(), config())
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 302, "sensitive-error"))
    assert {:error, :guard_unavailable} = Ner.assess(["safe"], nil, snapshot(), config())
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{model_set: "pl-nkjp.v1", detections: []}))

    assert {:error, :guard_unavailable} =
             Ner.assess(["safe"], nil, snapshot(), Keyword.put(config(), :response_bytes, 1))
  end

  test "readiness requires the pinned, loaded model" do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{status: "ready", model_set: "pl-nkjp.v1"}))
    assert Ner.ready?(config())
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{status: "ready", model_set: "wrong"}))
    refute Ner.ready?(config())
  end
end
