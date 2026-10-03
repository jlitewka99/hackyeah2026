defmodule AiControl.Tools.Catalog do
  @moduledoc "Closed operation catalog. Client-provided schemas never authorize execution."

  @text %{"type" => "string", "minLength" => 1, "maxLength" => 4_096}
  @content %{"type" => "string", "minLength" => 0, "maxLength" => 32_768}
  @properties %{
    "file.read" => %{"path" => @text},
    "file.write" => %{"path" => @text, "content" => @content},
    "file.delete" => %{"path" => @text},
    "http.get" => %{"url" => @text},
    "database.select" => %{
      "table" => @text,
      "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
    },
    "email.send" => %{"recipient" => @text, "subject" => @text, "body" => @content},
    "command.run" => %{
      "command" => @text,
      "arguments" => %{"type" => "array", "items" => @text, "maxItems" => 1}
    }
  }

  def all do
    @properties
    |> Enum.sort()
    |> Enum.map(fn {name, properties} ->
      %{
        "name" => name,
        "parameters" => %{
          "type" => "object",
          "properties" => properties,
          "required" => properties |> Map.keys() |> Enum.sort(),
          "additionalProperties" => false
        }
      }
    end)
  end

  def validate(tool, arguments) do
    case Map.fetch(@properties, tool) do
      {:ok, properties} ->
        if object?(arguments, properties),
          do: :ok,
          else: {:error, :invalid_tool_arguments}

      :error ->
        {:error, :tool_not_allowed}
    end
  end

  defp object?(arguments, properties) when is_map(arguments) and not is_struct(arguments) do
    MapSet.new(Map.keys(arguments)) == MapSet.new(Map.keys(properties)) &&
      Enum.all?(properties, fn {key, schema} -> value?(arguments[key], schema) end)
  end

  defp object?(_, _), do: false

  defp value?(value, %{"type" => "string"} = schema) do
    is_binary(value) && String.valid?(value) &&
      byte_size(value) <= schema["maxLength"] * 4 && string_length?(value, schema)
  end

  defp value?(value, %{"type" => "integer"} = schema),
    do: is_integer(value) && value >= schema["minimum"] && value <= schema["maximum"]

  defp value?(value, %{"type" => "array"} = schema),
    do:
      is_list(value) && length(value) <= schema["maxItems"] &&
        Enum.all?(value, &value?(&1, schema["items"]))

  defp string_length?(value, schema) do
    count = value |> String.codepoints() |> length()
    count >= schema["minLength"] && count <= schema["maxLength"]
  end
end
