defmodule AiControl.Gateway.RequestTest do
  use ExUnit.Case, async: true

  import AiControl.GatewayFixtures

  alias AiControl.Gateway.{Content, Request, Response}

  test "text, functions, calls and tool results round trip" do
    call = %{
      "id" => "call_1",
      "type" => "function",
      "function" => %{"name" => "lookup", "arguments" => ~s({"query":"Łódź"})}
    }

    params =
      request()
      |> Map.put("tools", [
        %{
          "type" => "function",
          "function" => %{
            "name" => "lookup",
            "description" => "Find a city",
            "parameters" => %{
              "type" => "object",
              "properties" => %{"query" => %{"type" => "string"}}
            }
          }
        }
      ])
      |> Map.put("messages", [
        %{"role" => "user", "content" => "Łódź"},
        %{"role" => "assistant", "content" => nil, "tool_calls" => [call]},
        %{"role" => "tool", "content" => "Found", "tool_call_id" => "call_1"}
      ])

    assert {:ok, safe} = Request.validate(params)
    assert safe["stream"] == false

    assert {:ok, _} =
             Request.validate(
               Map.put(params, "tool_choice", %{
                 "type" => "function",
                 "function" => %{"name" => "lookup"}
               })
             )
  end

  test "unsupported formats and identity parameters fail explicitly" do
    for changes <- [
          %{"stream" => true},
          %{"n" => 2},
          %{"user_id" => Ecto.UUID.generate()},
          %{"organization_id" => Ecto.UUID.generate()},
          %{"agent_id" => Ecto.UUID.generate()},
          %{"messages" => [%{"role" => "user", "content" => [%{"type" => "image_url"}]}]},
          %{"max_tokens" => 0},
          %{"tools" => [%{"type" => "shell"}]},
          %{"tool_choice" => "required"},
          %{"response_format" => %{}},
          %{"messages" => []}
        ] do
      assert {:error, :invalid_request} = Request.validate(Map.merge(request(), changes))
    end
  end

  test "response allowlist discards reasoning and opaque provider fields" do
    data =
      response()
      |> Map.put("private", "secret")
      |> put_in(["choices", Access.at(0), "message", "reasoning"], "secret chain of thought")

    assert {:ok, safe} = Response.normalize(data, "qwen3.5:4b", Ecto.UUID.generate())
    refute Jason.encode!(safe) =~ "secret"

    assert {:error, :upstream_invalid_response} =
             Response.normalize(%{"choices" => []}, "qwen3.5:4b", Ecto.UUID.generate())
  end

  test "merged Unicode ranges redact once and invalid text boundaries fail" do
    assert {:ok, "[REDACTED] Kraków"} =
             Content.redact("Łódź Kraków", [
               %{field_index: 0, start_byte: 0, end_byte: 4},
               %{field_index: 0, start_byte: 2, end_byte: 7}
             ])

    assert {:error, :redaction_unavailable} =
             Content.redact("Łódź", [%{field_index: 0, start_byte: 1, end_byte: 2}])

    for invalid <- [
          %{field_index: -1, start_byte: 0, end_byte: 7},
          %{field_index: 0, start_byte: "0", end_byte: 7},
          %{field_index: 1, start_byte: 0, end_byte: 7}
        ] do
      assert {:error, :redaction_unavailable} = Content.redact("Łódź", [invalid])
    end
  end
end
