defmodule AiControl.Tools.Content do
  @moduledoc "Tool-specific projection; resource selectors and JSON keys cannot be redacted."
  alias AiControl.Gateway.Content
  alias AiControl.Tools
  alias AiControl.Tools.{Resources, ToolRequest}

  @selectors ~w(path url table recipient command)
  @max_bytes 65_536

  def fields(value, stage) do
    value
    |> Content.structured_fields()
    |> Enum.map(fn field ->
      if stage == :input && readonly?(field.path), do: %{field | path: nil}, else: field
    end)
  end

  defp readonly?(["tool"]), do: true
  defp readonly?(["arguments", selector]), do: selector in @selectors
  defp readonly?(_), do: false

  def locations_valid?(value, locations, stage),
    do: Content.locations_valid_fields?(locations, fields(value, stage))

  def redact(value, locations, stage),
    do: Content.redact_fields(value, locations, fields(value, stage))

  def validate(original, safe, :input, opts) do
    request = Keyword.fetch!(opts, :tool_request)
    grant = Keyword.fetch!(opts, :resource_grant)
    files = Keyword.fetch!(opts, :resource_files)
    updated = %{request | arguments: safe["arguments"]}

    with true <- original["tool"] == safe["tool"],
         :ok <- ToolRequest.validate_arguments(request.tool, safe["arguments"]),
         :ok <- AiControl.Tools.authorize(updated),
         {:ok, _} <- Resources.authorize(updated, grant, files) do
      :ok
    else
      _ -> {:error, :redaction_unavailable}
    end
  end

  def validate(_, safe, :output, opts) do
    request = Keyword.fetch!(opts, :tool_request)

    with :ok <- Tools.authorize(request),
         {:ok, _} <- Resources.authorize(request, opts[:resource_grant], opts[:resource_files]) do
      validate_result(request.tool, safe)
    end
  end

  def validate_result(tool, value) do
    with true <- json?(value, 0),
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= @max_bytes,
         true <- result?(tool, value) do
      :ok
    else
      _ -> {:error, :tool_invalid_result}
    end
  end

  defp result?("file.read", %{"content" => value} = result),
    do: map_size(result) == 1 && is_binary(value)

  defp result?("file.write", result), do: result == %{"written" => true}
  defp result?("file.delete", result), do: result == %{"deleted" => true}
  defp result?("email.send", result), do: result == %{"queued_locally" => true}

  defp result?("command.run", %{"output" => value} = result),
    do: map_size(result) == 1 && is_binary(value)

  defp result?("http.get", %{"status" => status, "body" => body} = result),
    do: map_size(result) == 2 && is_integer(status) && status in 200..299 && is_binary(body)

  defp result?("database.select", %{"rows" => rows} = result),
    do:
      map_size(result) == 1 && is_list(rows) && length(rows) <= 100 && Enum.all?(rows, &is_map/1)

  defp result?(_, _), do: false

  defp json?(_, depth) when depth > 32, do: false
  defp json?(value, _) when is_binary(value), do: String.valid?(value)
  defp json?(value, _) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json?(value, depth) when is_list(value), do: Enum.all?(value, &json?(&1, depth + 1))

  defp json?(value, depth) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) && String.valid?(key) && json?(item, depth + 1)
      end)

  defp json?(_, _), do: false
end
