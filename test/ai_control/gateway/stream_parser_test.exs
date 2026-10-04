defmodule AiControl.Gateway.StreamParserTest do
  use ExUnit.Case, async: true

  import AiControl.GatewayFixtures

  alias AiControl.Gateway.{Response, StreamEncoder, StreamParser}

  test "every byte split including Unicode, delimiters and CRLF reconstructs one response" do
    body = stream_body(["Łódź", " i żółć"]) |> String.replace("\n", "\r\n")

    for offset <- 0..byte_size(body) do
      <<first::binary-size(^offset), second::binary>> = body
      assert {:ok, state} = StreamParser.feed(StreamParser.new(8192), first)
      assert {:ok, state} = StreamParser.feed(state, second)
      assert {:ok, response} = StreamParser.finish(state)
      assert hd(response["choices"])["message"]["content"] == "Łódź i żółć"
    end
  end

  test "split tool argument JSON and identifiers are assembled before validation" do
    first = %{
      "index" => 0,
      "id" => "call_1",
      "type" => "function",
      "function" => %{"name" => "lookup", "arguments" => ~s({"city":)}
    }

    second = %{"index" => 0, "function" => %{"arguments" => ~s("Łódź"})}}

    data = [
      stream_chunk(%{"role" => "assistant"}),
      stream_chunk(%{"tool_calls" => [first]}),
      stream_chunk(%{"tool_calls" => [second]}),
      stream_chunk(%{}, "tool_calls")
    ]

    body =
      Enum.map_join(data, &("data: " <> &1 <> "\n\n")) <>
        usage_frame() <> "data: [DONE]\n\n"

    assert {:ok, state} = StreamParser.feed(StreamParser.new(8192), body)
    assert {:ok, response} = StreamParser.finish(state)
    assert {:ok, normalized} = Response.normalize(response, "qwen3.5:4b", Ecto.UUID.generate())
    call = hd(hd(normalized["choices"])["message"]["tool_calls"])
    assert Jason.decode!(call["function"]["arguments"]) == %{"city" => "Łódź"}
    assert call["id"] == "call_1"
  end

  test "missing termination, usage, malformed choices and excess bytes fail closed" do
    assert {:ok, state} =
             StreamParser.feed(
               StreamParser.new(8192),
               stream_body() |> String.replace("data: [DONE]\n\n", "")
             )

    assert {:error, :upstream_invalid_response} = StreamParser.finish(state)

    for raw <- [
          "data: [DONE]\n\n",
          ~s(data: {"private":"secret"}\n\n),
          "data: " <> stream_chunk(%{}, "stop") <> "\n\ndata: [DONE]\n\n",
          stream_body() <> "data: {}\n\n"
        ] do
      assert {:error, :upstream_invalid_response} = StreamParser.feed(StreamParser.new(8192), raw)
    end

    assert {:error, :response_too_large} = StreamParser.feed(StreamParser.new(20), stream_body())
  end

  test "known usage is checkpointed even when later framing fails" do
    owner = self()

    assert {:error, :upstream_invalid_response} =
             StreamParser.feed(
               StreamParser.new(8192),
               stream_body() <> "data: {}\n\n",
               fn usage ->
                 send(owner, {:usage, usage})
                 :ok
               end
             )

    assert_received {:usage, %{"total_tokens" => 16}}
  end

  test "invalid tool indexes and inconsistent or duplicate usage are rejected" do
    for index <- [-1, 100, "0"] do
      frame = stream_chunk(%{"tool_calls" => [%{"index" => index}]})

      assert {:error, :upstream_invalid_response} =
               StreamParser.feed(StreamParser.new(8192), "data: " <> frame <> "\n\n")
    end

    for body <- [
          String.replace(stream_body(), "\"total_tokens\":16", "\"total_tokens\":17"),
          String.replace(
            stream_body(),
            "data: [DONE]",
            "data: " <> stream_usage() <> "\n\ndata: [DONE]"
          )
        ] do
      assert {:error, :upstream_invalid_response} =
               StreamParser.feed(StreamParser.new(8192), body)
    end

    frame =
      stream_chunk(
        %{
          "tool_calls" => [
            %{
              "index" => 1,
              "id" => "call_1",
              "type" => "function",
              "function" => %{"name" => "lookup", "arguments" => "{}"}
            }
          ]
        },
        "tool_calls"
      )

    assert {:ok, state} =
             StreamParser.feed(
               StreamParser.new(8192),
               "data: " <> frame <> "\n\ndata: " <> stream_usage() <> "\n\ndata: [DONE]\n\n"
             )

    assert {:error, :upstream_invalid_response} = StreamParser.finish(state)
  end

  test "public encoder uses approved IDs and splits only at UTF-8 boundaries" do
    assert {:ok, value} =
             Response.normalize(
               response(String.duplicate("ą", 700)),
               "approved",
               Ecto.UUID.generate()
             )

    frames = StreamEncoder.frames(value, true) |> Enum.to_list()
    assert Enum.all?(frames, &String.valid?/1)

    parsed =
      Enum.map(frames, fn frame ->
        frame |> String.trim_leading("data: ") |> String.trim() |> Jason.decode!()
      end)

    assert Enum.all?(parsed, &(&1["id"] == value["id"] && &1["model"] == "approved"))
    assert List.last(parsed)["usage"]["total_tokens"] == 16
    assert Enum.any?(parsed, &(&1["choices"] == []))
    refute StreamEncoder.frames(value, false) |> Enum.any?(&String.contains?(&1, "\"usage\""))
  end

  defp usage_frame do
    "data: " <>
      Jason.encode!(%{
        "id" => "backend-id",
        "created" => 1,
        "model" => "qwen3.5:4b",
        "object" => "chat.completion.chunk",
        "choices" => [],
        "usage" => response()["usage"]
      }) <> "\n\n"
  end
end
