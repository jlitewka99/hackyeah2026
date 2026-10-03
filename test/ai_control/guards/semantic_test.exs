defmodule AiControl.Guards.SemanticTest do
  use ExUnit.Case, async: true

  alias AiControl.Gateway.Config
  alias AiControl.Guards.{Moderation, Semantic}
  alias AiControl.Guards.Semantic.Local
  alias AiControl.Policies.Configuration
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.GuardResult

  defp snapshot(overrides \\ %{}) do
    source = Configuration.default(3) |> Map.merge(overrides)
    {:ok, %{settings: settings}} = Configuration.validate(source)

    rules =
      Map.new(settings["rules"], fn {name, rule} ->
        {name,
         %{
           id: rule["id"],
           action: %{"block" => :block, "redact" => :redact, "allow" => :allow}[rule["action"]],
           threshold: rule["threshold"]
         }}
      end)

    {:ok, snapshot} =
      Snapshot.new(%{version: "semantic-unit-v1", settings: settings, rules: rules})

    snapshot
  end

  defp response(fields, severity \\ "Unsafe", categories \\ ["Jailbreak"], task \\ "injection") do
    %{
      "model_set" => Local.model_set(),
      "revision" => Local.revision(),
      "task" => task,
      "duration_us" => 10,
      "windows" =>
        fields
        |> Enum.with_index()
        |> Enum.map(fn {text, index} ->
          %{
            "field_index" => index,
            "start_byte" => 0,
            "end_byte" => byte_size(text),
            "severity" => severity,
            "categories" => categories,
            "refusal" => if(task == "moderation", do: "No")
          }
        end)
    }
  end

  setup do
    config = Config.get() |> Keyword.put(:semantic_http_plug, {Req.Test, __MODULE__})
    %{config: config}
  end

  test "the provider can be replaced without changing Guard.assess/4", %{config: config} do
    config = Keyword.put(config, :semantic_provider, AiControl.SemanticProviderMock)
    assert Semantic.ready?(config)

    assert {:ok, %{detections: [%{category: "prompt_injection"}]}} =
             Semantic.assess(["synthetic fixture"], nil, snapshot(), config)
  end

  test "Jailbreak mapping is binary and changing severity changes findings", %{config: config} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, response(["ą atak"], "Controversial"))
    end)

    assert {:ok, result} = Semantic.assess(["ą atak"], nil, snapshot(), config)
    assert result.detections == []

    assert {:ok, result} =
             Semantic.assess(
               ["ą atak"],
               nil,
               snapshot(%{
                 "guards" => %{"semantic" => %{"severities" => ["Unsafe", "Controversial"]}}
               }),
               config
             )

    assert [%{category: "prompt_injection", confidence: 1, location: nil}] = result.detections
    assert result.evidence["signal_kind"] == "label_mapping_binary"
    assert GuardResult.valid?(result)
  end

  test "PII labels are not injection and output safety is a separate category", %{config: config} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, response(["text"], "Unsafe", ["PII"]))
    end)

    assert {:ok, %{detections: []}} = Semantic.assess(["text"], nil, snapshot(), config)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["prompt"] == "[REDACTED] input"
      Req.Test.json(conn, response(["text"], "Unsafe", ["Violent"], "moderation"))
    end)

    config = Keyword.put(config, :semantic_prompt, "[REDACTED] input")

    assert {:ok, %{detections: [%{category: "content_safety", guard: "moderation"}]}} =
             Moderation.assess(["text"], nil, snapshot(), config)
  end

  test "incomplete, duplicate, invalid UTF-8 and unknown model evidence fail closed", %{
    config: config
  } do
    valid = response(["😀abc"])
    [window] = valid["windows"]

    for invalid <- [
          Map.put(valid, "windows", []),
          Map.put(valid, "revision", String.duplicate("a", 40)),
          Map.put(valid, "windows", [window, window]),
          put_in(valid, ["windows"], [%{window | "start_byte" => 1}]),
          put_in(valid, ["windows"], [%{window | "severity" => "Unknown"}]),
          Map.put(valid, "text", "DO-NOT-LOG")
        ] do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, invalid))
      assert {:error, :guard_unavailable} = Semantic.assess(["😀abc"], nil, snapshot(), config)
    end
  end

  test "transport errors and oversized responses never return success", %{config: config} do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :guard_unavailable} = Semantic.assess(["text"], nil, snapshot(), config)
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, response(["text"])))

    assert {:error, :guard_unavailable} =
             Semantic.assess(["text"], nil, snapshot(), Keyword.put(config, :response_bytes, 2))
  end

  test "overlapping windows must cover every field including the final byte" do
    first = hd(response(["abcdef"])["windows"])
    response = response(["abcdef"])
    complete = [%{first | "end_byte" => 4}, %{first | "start_byte" => 2}]
    assert Local.valid_response?(%{response | "windows" => complete}, ["abcdef"], "injection")

    refute Local.valid_response?(
             %{response | "windows" => [%{first | "end_byte" => 5}]},
             ["abcdef"],
             "injection"
           )

    empty = response([""], "Safe", [])
    assert Local.valid_response?(empty, [""], "injection")
    refute Local.valid_response?(%{empty | "windows" => []}, [""], "injection")
  end

  test "readiness requires the pinned revision", %{config: config} do
    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{
        status: "ready",
        model_set: Local.model_set(),
        revision: Local.revision()
      })
    )

    assert Local.ready?(config)

    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{status: "ready", model_set: Local.model_set(), revision: "wrong"})
    )

    refute Local.ready?(config)
  end
end
