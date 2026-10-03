defmodule AiControl.Gateway.ToolSchemasTest do
  use ExUnit.Case, async: false

  import AiControl.GatewayFixtures

  alias AiControl.Gateway.{Config, Response, Slots, ToolSchemas}

  test "full schema validation enforces nested arrays, required fields and additional properties" do
    schema = %{
      "type" => "object",
      "required" => ["items"],
      "additionalProperties" => false,
      "properties" => %{
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{
            "type" => "object",
            "required" => ["count"],
            "additionalProperties" => false,
            "properties" => %{"count" => %{"type" => "integer", "minimum" => 1}}
          }
        }
      }
    }

    assert {:ok, contract} = prepare(schema)
    assert :ok = validate(contract, %{"items" => [%{"count" => 2}]})

    for args <- [
          %{},
          %{"items" => []},
          %{"items" => [%{"count" => "2"}]},
          %{"items" => [%{"count" => 0}]},
          %{"items" => [%{"count" => 1, "extra" => true}]}
        ] do
      assert {:error, :upstream_invalid_response} = validate(contract, args)
    end
  end

  test "enum, pattern, format and local references are validated without casts" do
    schema = %{
      "type" => "object",
      "$defs" => %{"email" => %{"type" => "string", "format" => "email"}},
      "properties" => %{
        "email" => %{"$ref" => "#/$defs/email"},
        "mode" => %{"enum" => ["safe", "test"]},
        "code" => %{"type" => "string", "pattern" => "^[A-Z]{2}$"}
      }
    }

    assert {:ok, contract} = prepare(schema)

    assert :ok =
             validate(contract, %{"email" => "test@example.com", "mode" => "safe", "code" => "PL"})

    for args <- [%{"email" => "[REDACTED]"}, %{"mode" => "[REDACTED]"}, %{"code" => "[REDACTED]"}] do
      assert {:error, :upstream_invalid_response} = validate(contract, args)
    end
  end

  test "Draft 7 and Draft 2020-12 combinators are supported" do
    for dialect <- [
          "http://json-schema.org/draft-07/schema#",
          "https://json-schema.org/draft/2020-12/schema"
        ] do
      schema = %{
        "$schema" => dialect,
        "type" => "object",
        "properties" => %{
          "value" => %{
            "oneOf" => [
              %{"type" => "string", "minLength" => 3},
              %{"type" => "number", "minimum" => 10}
            ],
            "not" => %{"const" => "forbidden"}
          }
        }
      }

      assert {:ok, contract} = prepare(schema)
      assert :ok = validate(contract, %{"value" => "safe"})
      assert :ok = validate(contract, %{"value" => 12})
      assert {:error, :upstream_invalid_response} = validate(contract, %{"value" => true})
      assert {:error, :upstream_invalid_response} = validate(contract, %{"value" => "forbidden"})
    end
  end

  test "invalid schemas, unsupported dialects, remote references and duplicate definitions fail safely" do
    for schema <- [
          %{"type" => "object", "required" => "PRIVATE_SCHEMA_VALUE"},
          %{"type" => "object", "$schema" => "https://example.com/schema"},
          %{"type" => "object", "$ref" => "jsv:module:JSV.ErrorFormatter"},
          %{"type" => "object", "properties" => %{"value" => %{"x-jsv-cast" => "JSV.Schema"}}},
          %{
            "type" => "object",
            "$ref" => "#/metadata",
            "metadata" => %{"$ref" => "jsv:module:JSV.ErrorFormatter"}
          },
          %{"type" => "object", "$ref" => "http://127.0.0.1:1/private"}
        ] do
      assert {:error, :invalid_request} = prepare(schema)
    end

    tool = tool(%{"type" => "object"})
    assert {:error, :invalid_request} = ToolSchemas.prepare(%{"tools" => [tool, tool]})
  end

  test "schema compilation and validation obey shared guard capacity and release leases" do
    {:ok, contract} = prepare(%{"type" => "object"})
    owner = self()

    workers =
      for index <- 1..2 do
        pid =
          start_supervised!(
            Supervisor.child_spec(
              {Task,
               fn ->
                 Slots.run(:guard, 5_000, fn ->
                   send(owner, {:running, self()})

                   receive do
                     :finish -> :ok
                   end
                 end)
               end},
              id: index
            )
          )

        assert_receive {:running, worker}
        {pid, worker}
      end

    assert {:error, {:capacity_exceeded, 1}} = prepare(%{"type" => "object"})
    assert {:error, {:capacity_exceeded, 1}} = validate(contract, %{})

    for {pid, worker} <- workers do
      ref = Process.monitor(pid)
      send(worker, :finish)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    _ = :sys.get_state(Slots)
    assert :ok = validate(contract, %{})
  end

  test "large validation work times out without exposing errors or retaining capacity" do
    original = Application.fetch_env!(:ai_control, Config)
    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)

    {:ok, large} =
      prepare(%{
        "type" => "object",
        "properties" => %{"items" => %{"type" => "array", "items" => %{"type" => "integer"}}}
      })

    {:ok, ordinary} = prepare(%{"type" => "object"})
    arguments = %{"items" => List.duplicate(1, 300_000)}
    Application.put_env(:ai_control, Config, Keyword.put(original, :guard_timeout, 1))
    assert {:error, :guard_unavailable} = validate(large, arguments)
    Application.put_env(:ai_control, Config, original)
    assert :ok = validate(ordinary, %{})
  end

  test "missing parameters allow any object but unknown calls and tool_choice violations fail" do
    assert {:ok, contract} =
             ToolSchemas.prepare(%{"tools" => [%{"function" => %{"name" => "lookup"}}]})

    assert :ok = validate(contract, %{"anything" => [1, "safe", nil]})

    assert {:error, :upstream_invalid_response} =
             ToolSchemas.validate_calls([call(%{}, "unknown")], contract)

    assert :ok = ToolSchemas.validate_calls([], contract)

    assert {:error, :upstream_invalid_response} =
             ToolSchemas.validate_calls([call(%{})], %{contract | choice: "none"})

    assert {:error, :upstream_invalid_response} =
             ToolSchemas.validate_calls([], %{contract | choice: "required"})

    forced = %{contract | choice: %{"type" => "function", "function" => %{"name" => "lookup"}}}
    assert :ok = ToolSchemas.validate_calls([call(%{})], forced)
    assert {:error, :upstream_invalid_response} = ToolSchemas.validate_calls([], forced)
  end

  test "safe response retains usage and rejects inconsistent finish reasons and duplicate call IDs" do
    assert {:ok, contract} = prepare(%{"type" => "object"})
    result = response() |> put_in(["choices", Access.at(0), "message", "tool_calls"], [call(%{})])
    assert {:error, :upstream_invalid_response} = Response.validate(result, contract)
    result = put_in(result, ["choices", Access.at(0), "finish_reason"], "tool_calls")
    assert :ok = Response.validate(result, contract)

    result =
      put_in(result, ["choices", Access.at(0), "message", "tool_calls"], [call(%{}), call(%{})])

    assert {:error, :upstream_invalid_response} = Response.validate(result, contract)
  end

  defp prepare(schema), do: ToolSchemas.prepare(%{"tools" => [tool(schema)]})

  defp tool(schema),
    do: %{"type" => "function", "function" => %{"name" => "lookup", "parameters" => schema}}

  defp validate(contract, args), do: ToolSchemas.validate_calls([call(args)], contract)

  defp call(args, name \\ "lookup"),
    do: %{
      "id" => "call-1",
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }
end
