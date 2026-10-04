defmodule AiControl.Workflows.MCPTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.MCPFixtures
  import AiControl.WorkflowsFixtures

  alias AiControl.{Repo, Workflows}
  alias AiControl.Tools.Discovery
  alias AiControl.Workflows.Run

  test "existing MCP tool and resource calls consume the verified root and preserve retries" do
    c = workflow_fixture()
    session = initialize(c)
    call = tool_message("file.read", %{"path" => "report.txt"}, 42)
    denied = request(c, session, call) |> json_response(200)
    assert denied["result"]["_meta"]["code"] == "workflow_context_required"
    assert Repo.get!(Run, c.run.id).calls == 0

    conn =
      agent_conn(c, session)
      |> put_req_header("x-run-id", c.run.id)
      |> put_req_header("x-run-participant-id", c.participant.id)

    accepted = post(conn, "/mcp", Jason.encode!(call)) |> json_response(200)
    assert accepted["result"]["isError"] == false
    repeated = post(conn, "/mcp", Jason.encode!(call)) |> json_response(200)
    assert repeated["result"]["_meta"]["code"] == "tool_execution_exists"
    assert Repo.get!(Run, c.run.id).calls == 1

    resource = message("resources/read", %{"uri" => Discovery.uri("report.txt")}, 43)

    assert post(conn, "/mcp", Jason.encode!(resource))
           |> json_response(200)
           |> Map.has_key?("result")

    run = Repo.get!(Run, c.run.id)
    assert run.calls == 2
    assert Workflows.evidence(run).tool_calls == 2
    assert {:ok, _} = Workflows.transition(c.principal, c.run.id, "stop")

    blocked =
      post(conn, "/mcp", Jason.encode!(tool_message("file.read", %{"path" => "report.txt"}, 44)))
      |> json_response(200)

    assert blocked["result"]["_meta"]["code"] == "workflow_terminal"
    assert Repo.get!(Run, c.run.id).calls == 2
  end

  test "MCP rejects malformed and substituted participant headers" do
    c = workflow_fixture()
    session = initialize(c)
    call = Jason.encode!(tool_message("file.read", %{"path" => "report.txt"}))
    incomplete = agent_conn(c, session) |> put_req_header("x-run-id", c.run.id)

    assert post(incomplete, "/mcp", call) |> json_response(400) |> get_in(["error", "code"]) ==
             "invalid_request"

    substituted = incomplete |> put_req_header("x-run-participant-id", Ecto.UUID.generate())
    denied = post(substituted, "/mcp", call) |> json_response(200)
    assert denied["result"]["_meta"]["code"] == "forbidden"
    assert Repo.get!(Run, c.run.id).calls == 0
  end
end
