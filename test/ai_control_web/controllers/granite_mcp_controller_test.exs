defmodule AiControlWeb.GraniteMCPControllerTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.MCPFixtures
  import AiControl.ToolsFixtures
  import AiControl.WorkflowsFixtures

  alias AiControl.Gateway.Config
  alias AiControl.Guards.Granite
  alias AiControl.Policies.ConfigurationV6
  alias AiControl.Tools.Sandbox

  test "v6 MCP tools use the mandatory Granite check before the shared effect", _ do
    original = Application.fetch_env!(:ai_control, Config)
    parent = self()

    Application.put_env(
      :ai_control,
      Config,
      original
      |> Keyword.merge(
        guards: %{"granite" => Granite},
        granite_provider: AiControl.TestGraniteProvider,
        test_granite: fn _, _ ->
          send(parent, :judged)
          {:ok, "no", %{"prompt_tokens" => 20, "completion_tokens" => 8, "total_tokens" => 28}}
        end
      )
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)
    c = tool_fixture()

    activate_workflows(c.scope, %{}, %{
      "schema_version" => 6,
      "granite" => Map.put(ConfigurationV6.defaults(), "enabled", true)
    })

    reference = run_reference_fixture(c.principal)
    session = initialize(c)

    result =
      agent_conn(c, session)
      |> put_req_header("x-run-id", reference.run_id)
      |> put_req_header("x-run-participant-id", reference.participant_id)
      |> post(
        "/mcp",
        Jason.encode!(
          tool_message("file.write", %{"path" => "copy.txt", "content" => "synthetic MCP"})
        )
      )
      |> json_response(200)

    assert result["result"]["isError"]
    assert_received :judged
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end
end
