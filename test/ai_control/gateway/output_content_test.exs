defmodule AiControl.Gateway.OutputContentTest do
  use ExUnit.Case, async: true

  import AiControl.GatewayFixtures

  alias AiControl.Gateway.Content

  test "output projection decodes JSON escapes, retains context and scans numbers and keys" do
    value =
      output(~s({"password":"P\\u0041SSWORD", "items":[{"person":"Łódź"}], "pesel":44051401458}))

    fields = Content.fields(value, :output)
    assert fields == Content.fields(value, :output)
    texts = Enum.map(fields, & &1.text)
    assert "password: PASSWORD" in texts
    assert "person: Łódź" in texts
    assert "pesel: 44051401458" in texts
    assert "password" in texts
    assert "call-1" in texts
    assert "lookup" in texts
    refute "qwen3.5:4b" in texts
  end

  test "redaction reconstructs valid JSON and merges ranges in decoded UTF-8 text" do
    value = output(~s({"items":[{"person":"😀 Jan Kowalski"}],"count":12}))
    text = "person: 😀 Jan Kowalski"
    first = byte_size("person: 😀 ")

    spans = [
      location(value, text, first, first + 5),
      location(value, text, first + 4, byte_size(text))
    ]

    assert {:ok, safe} = Content.redact(value, spans, :output)
    call = hd(hd(safe["choices"])["message"]["tool_calls"])

    assert Jason.decode!(call["function"]["arguments"]) == %{
             "items" => [%{"person" => "😀 [REDACTED]"}],
             "count" => 12
           }

    assert call["id"] == "call-1"
    assert call["function"]["name"] == "lookup"
    assert safe["usage"] == value["usage"]
  end

  test "keys, identifiers, numbers and context prefixes cannot be redacted" do
    value = output(~s({"person":"Łódź","pesel":44051401458}))

    for text <- ["call-1", "lookup", "person", "pesel: 44051401458", "person: Łódź"] do
      span = location(value, text, 0, byte_size(text))
      assert Content.locations_valid?(value, [span], :output)
      assert {:error, :redaction_unavailable} = Content.redact(value, [span], :output)
    end
  end

  test "locations cannot cut a UTF-8 codepoint and indexes refresh after redaction" do
    value = output(~s({"person":"Łódź"}))
    span = location(value, "person: Łódź", byte_size("person: "), byte_size("person: ") + 1)
    refute Content.locations_valid?(value, [span], :output)
    assert {:error, :redaction_unavailable} = Content.redact(value, [span], :output)

    good = location(value, "person: Łódź", byte_size("person: "), byte_size("person: Łódź"))
    assert {:ok, safe} = Content.redact(value, [good], :output)
    assert Enum.any?(Content.fields(safe, :output), &(&1.text == "person: [REDACTED]"))
  end

  defp output(arguments) do
    put_in(response("Safe."), ["choices", Access.at(0), "message", "tool_calls"], [
      %{
        "id" => "call-1",
        "type" => "function",
        "function" => %{"name" => "lookup", "arguments" => arguments}
      }
    ])
  end

  defp location(value, text, first, last) do
    index = Enum.find_index(Content.fields(value, :output), &(&1.text == text))
    %{field_index: index, start_byte: first, end_byte: last}
  end
end
