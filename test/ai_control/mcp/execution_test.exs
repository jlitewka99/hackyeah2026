defmodule AiControl.MCP.ExecutionTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.MCPFixtures
  import AiControl.ToolsFixtures

  alias AiControl.Audit.Event
  alias AiControl.Audit.Serializer
  alias AiControl.Budgets.Workflow
  alias AiControl.Gateway.Config
  alias AiControl.Guards.{Pii, Secret, Signatures}
  alias AiControl.Policies.Configuration
  alias AiControl.Repo
  alias AiControl.Security.GuardResult
  alias AiControl.Tools.{Discovery, Execution, Sandbox}
  alias Ecto.Adapters.SQL

  setup do
    original = Config.get()
    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(original, :guards, %{
        "pii" => Pii,
        "secret" => Secret,
        "signatures" => Signatures
      })
    )

    c = tool_fixture()
    Map.put(c, :session, initialize(c))
  end

  test "concurrent duplicate IDs dispatch once and changed arguments cannot reuse them", c do
    args = %{"recipient" => "demo@example.com", "subject" => "demo", "body" => "safe"}

    responses =
      1..8
      |> Task.async_stream(
        fn _ ->
          request(c, c.session, tool_message("email.send", args, "same-id")) |> json_response(200)
        end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert Enum.count(responses, &(&1["result"]["isError"] == false)) == 1

    assert Enum.count(
             responses,
             &(get_in(&1, ["result", "_meta", "code"]) == "tool_execution_exists")
           ) == 7

    assert length(Sandbox.inspect_state(c.sandbox).mailbox) == 1

    response =
      request(c, c.session, tool_message("email.send", %{args | "body" => "changed"}, "same-id"))
      |> json_response(200)

    assert response["result"]["_meta"]["code"] == "idempotency_conflict"
    assert Enum.sum(Enum.map(Repo.all(Workflow), & &1.calls)) == 1
    refute Map.has_key?(response["result"], "structuredContent")
  end

  test "fresh policy prevents calls after catalog discovery", c do
    assert request(c, c.session, message("tools/list")) |> json_response(200)
    activate_tools(c.scope, %{"tools" => %{"allowed_tools" => []}})
    response = call(c, "file.write", %{"path" => "copy.txt", "content" => "safe"})
    assert response["error"]["data"]["code"] == "tool_not_allowed"
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
    assert Repo.aggregate(Execution, :count) == 0
  end

  test "ACL denials cannot reach the adapter through tools or resource URIs", c do
    initial = Sandbox.inspect_state(c.sandbox)

    for {tool, args} <- [
          {"file.read", %{"path" => "~/.ssh/id_rsa"}},
          {"file.write", %{"path" => "../escape", "content" => "safe"}},
          {"http.get", %{"url" => "http://127.0.0.1/private"}},
          {"database.select", %{"table" => "users;DELETE", "limit" => 1}},
          {"email.send",
           %{"recipient" => "other@example.com", "subject" => "demo", "body" => "safe"}},
          {"command.run", %{"command" => "sh", "arguments" => []}}
        ] do
      assert call(c, tool, args)["result"]["isError"]
    end

    for uri <- [
          "file:///etc/passwd",
          Discovery.uri("../report.txt"),
          Discovery.uri("missing.txt")
        ] do
      response =
        request(c, c.session, message("resources/read", %{"uri" => uri}, Ecto.UUID.generate()))
        |> json_response(200)

      assert response["error"]["data"]["code"] == "resource_not_found"
    end

    assert Sandbox.inspect_state(c.sandbox) == initial
    assert Repo.aggregate(Execution, :count) == 0
  end

  test "budget exhaustion and missing required guard deny before file mutation", c do
    activate_tools(c.scope, %{"budgets" => %{"workflow" => %{"tool_calls" => 0}}})

    assert call(c, "file.write", %{"path" => "copy.txt", "content" => "safe"})["result"]["_meta"][
             "code"
           ] == "tool_budget_exceeded"

    enable(c, %{"semantic" => %{"enabled" => true, "required" => true}})

    assert call(c, "file.write", %{"path" => "copy.txt", "content" => "safe"})["result"]["_meta"][
             "code"
           ] == "guard_unavailable"

    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
    refute Enum.any?(Repo.all(Execution), & &1.charged)
  end

  test "redaction protects text and structured results, including resource reads", c do
    enable(c, %{"pii" => %{}})
    response = call(c, "command.run", %{"command" => "echo", "arguments" => ["😀 44051401458"]})
    assert response["result"]["structuredContent"]["output"] == "😀 [REDACTED]"
    refute Jason.encode!(response) =~ "44051401458"
    :sys.replace_state(c.sandbox, &put_in(&1.files["report.txt"], "PESEL 44051401458"))

    response =
      request(c, c.session, message("resources/read", %{"uri" => Discovery.uri("report.txt")}, 3))
      |> json_response(200)

    assert hd(response["result"]["contents"])["text"] == "PESEL [REDACTED]"

    refute Repo.all(Event) |> Enum.map(&Serializer.event/1) |> Jason.encode!() =~
             "44051401458"
  end

  test "output block withholds every result representation while preserving the charge", c do
    enable(c, %{"secret" => %{}})
    secret = "ghp_" <> String.duplicate("a", 36)
    :sys.replace_state(c.sandbox, &put_in(&1.files["report.txt"], secret))
    response = call(c, "file.read", %{"path" => "report.txt"})
    assert response["result"]["isError"]
    refute Map.has_key?(response["result"], "structuredContent")
    refute Jason.encode!(response) =~ secret
    assert [%{status: "output_blocked", charged: true}] = Repo.all(Execution)
  end

  test "policy changes during guards keep one immutable execution snapshot", c do
    owner = self()

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"semantic" => AiControl.TestSemanticGuard})
      |> Keyword.put(:test_semantic_guard, fn _, context ->
        send(owner, {:stage, context.stage, context.policy_checksum})
        if context.stage == :input, do: activate_tools(c.scope, %{"allowed_agents" => []})
        GuardResult.new(%{guard: "semantic", status: :ok})
      end)
    )

    version = enable(c, %{"semantic" => %{"stages" => ["input", "output"]}})

    assert call(c, "command.run", %{"command" => "status", "arguments" => []})["result"][
             "isError"
           ] == false

    checksum = version.checksum
    assert_received {:stage, :input, ^checksum}
    assert_received {:stage, :output, ^checksum}

    assert call(c, "command.run", %{"command" => "status", "arguments" => []})["result"]["_meta"][
             "code"
           ] == "agent_not_allowed"
  end

  test "input audit failure prevents effects and terminal audit failure withholds output", c do
    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT mcp_input_audit CHECK (kind <> 'decision') NOT VALID"
    )

    assert call(c, "file.write", %{"path" => "copy.txt", "content" => "safe"})["result"]["_meta"][
             "code"
           ] == "audit_unavailable"

    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
    SQL.query!(Repo, "ALTER TABLE audit_events DROP CONSTRAINT mcp_input_audit")

    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT mcp_terminal_audit CHECK (event_type <> 'tool.completed') NOT VALID"
    )

    response = call(c, "file.read", %{"path" => "report.txt"})
    assert response["result"]["_meta"]["code"] == "audit_unavailable"
    refute Jason.encode!(response) =~ "Zażółć"
    assert Enum.any?(Repo.all(Execution), &(&1.status == "dispatching" && &1.charged))
    SQL.query!(Repo, "ALTER TABLE audit_events DROP CONSTRAINT mcp_terminal_audit")
  end

  test "MCP telemetry exposes only closed method and status labels", c do
    owner = self()
    handler = "mcp-telemetry-" <> Ecto.UUID.generate()

    :telemetry.attach(
      handler,
      [:ai_control, :mcp, :request],
      fn _, measurements, metadata, _ ->
        send(owner, {:mcp_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert request(c, c.session, message("malicious-secret-method")) |> json_response(200)

    assert_received {:mcp_telemetry, %{duration_us: duration},
                     %{method: "unknown", status: 200} = metadata}

    assert duration >= 0
    assert map_size(metadata) == 2
  end

  defp call(c, tool, args),
    do:
      request(c, c.session, tool_message(tool, args, Ecto.UUID.generate())) |> json_response(200)

  defp enable(c, enabled) do
    guards =
      Map.new(Configuration.guards(3), fn guard ->
        {guard, Map.get(enabled, guard, %{"enabled" => false, "required" => false})}
      end)

    activate_tools(c.scope, %{"guards" => guards})
  end
end
