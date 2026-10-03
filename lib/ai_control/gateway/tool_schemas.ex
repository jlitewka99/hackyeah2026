defmodule AiControl.Gateway.ToolSchemas do
  @moduledoc "Request-local JSON Schema validation, with no network resolver or data casting."
  alias AiControl.Gateway.{Config, Slots}

  @default_dialect "https://json-schema.org/draft/2020-12/schema"
  @dialects [@default_dialect, "http://json-schema.org/draft-07/schema#"]
  @options [resolver: [], formats: true, atoms: false, warnings: :silence]
  @schema_maps ~w($defs definitions properties patternProperties dependentSchemas dependencies)
  @metas Map.new(@dialects, fn dialect ->
           {dialect, JSV.build!(%{"$ref" => dialect}, @options)}
         end)

  def prepare(request) do
    tools = Map.get(request, "tools", [])
    choice = Map.get(request, "tool_choice", "auto")

    if tools == [] do
      {:ok, %{schemas: %{}, choice: choice}}
    else
      bounded(fn -> compile_tools(tools, choice) end)
    end
  end

  def validate_calls(calls, contract) do
    if calls == [] && contract.choice not in ["required"] && is_binary(contract.choice) do
      :ok
    else
      bounded(fn -> check_calls(calls, contract) end)
    end
  end

  defp compile_tools(tools, choice) do
    Enum.reduce_while(tools, {:ok, %{}}, fn %{"function" => function}, {:ok, schemas} ->
      name = function["name"]
      schema = Map.get(function, "parameters", %{"type" => "object"})
      dialect = Map.get(schema, "$schema", @default_dialect)

      with false <- Map.has_key?(schemas, name),
           true <- inert_schema?(schema),
           {:ok, meta} <- Map.fetch(@metas, dialect),
           {:ok, _} <- JSV.validate(schema, meta, cast: false, cast_formats: false),
           {:ok, root} <- JSV.build(schema, @options) do
        {:cont, {:ok, Map.put(schemas, name, root)}}
      else
        _ -> {:halt, {:error, :invalid_request}}
      end
    end)
    |> case do
      {:ok, schemas} -> {:ok, %{schemas: schemas, choice: choice}}
      error -> error
    end
  end

  # JSV appends a module resolver even with resolver: []. Its casting extensions
  # can also invoke module callbacks while building. Neither is a JSON Schema
  # capability we expose to untrusted API clients.
  defp inert_schema?(schema) when is_map(schema) do
    !Map.has_key?(schema, "x-jsv-cast") && !Map.has_key?(schema, "jsv-cast") &&
      Enum.all?(~w($schema $id $ref $dynamicRef), fn key ->
        case Map.get(schema, key) do
          value when is_binary(value) -> !Regex.match?(~r/\Ajsv:/i, value)
          _ -> true
        end
      end) &&
      Enum.all?(schema, fn
        {key, value} when key in @schema_maps and is_map(value) ->
          Enum.all?(Map.values(value), &inert_schema?/1)

        {_, value} ->
          inert_schema?(value)
      end)
  end

  defp inert_schema?(schemas) when is_list(schemas), do: Enum.all?(schemas, &inert_schema?/1)
  defp inert_schema?(_), do: true

  defp check_calls(calls, contract) do
    if choice?(calls, contract.choice) && Enum.all?(calls, &valid_call?(&1, contract.schemas)),
      do: :ok,
      else: {:error, :upstream_invalid_response}
  end

  defp choice?(calls, "none"), do: calls == []
  defp choice?(calls, "required"), do: calls != []
  defp choice?(_, "auto"), do: true

  defp choice?(calls, %{"function" => %{"name" => name}}),
    do: calls != [] && Enum.all?(calls, &(&1["function"]["name"] == name))

  defp valid_call?(%{"function" => %{"name" => name, "arguments" => arguments}}, schemas) do
    with {:ok, root} <- Map.fetch(schemas, name),
         {:ok, ordered} <- Jason.decode(arguments, objects: :ordered_objects),
         true <- unique_keys?(ordered),
         {:ok, object} when is_map(object) <- Jason.decode(arguments),
         {:ok, _} <- JSV.validate(object, root, cast: false, cast_formats: false),
         do: true,
         else: (_ -> false)
  end

  # A map decoder discards earlier duplicate keys, leaving raw values unchecked.
  # Reject that ambiguity before any response can be scanned or returned.
  defp unique_keys?(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))
    length(Enum.uniq(keys)) == length(keys) && Enum.all?(pairs, &unique_keys?(elem(&1, 1)))
  end

  defp unique_keys?(values) when is_list(values), do: Enum.all?(values, &unique_keys?/1)
  defp unique_keys?(_), do: true

  defp bounded(callback) do
    case Slots.run(:guard, Config.get(:guard_timeout), callback) do
      {:error, code} when code in [:upstream_timeout, :upstream_unavailable] ->
        {:error, :guard_unavailable}

      result ->
        result
    end
  end
end
