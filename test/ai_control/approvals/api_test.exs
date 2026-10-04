defmodule AiControl.Approvals.APITest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.ApprovalsFixtures
  import AiControl.GatewayFixtures, only: [request: 0, stream_body: 0]
  import AiControl.KnowledgeFixtures
  import AiControl.MCPFixtures, only: [initialize: 1, tool_message: 3, agent_conn: 2]
  import Ecto.Query

  alias AiControl.Approvals.{Approval, Cipher}
  alias AiControl.Budgets.Reservation
  alias AiControl.{Gateway, Repo, Workflows}
  alias AiControl.Gateway.{Config, Stream}
  alias AiControl.Tools.Sandbox
  alias AiControl.Workflows.{Operation, Participant, Run}

  setup do
    stub_model()
    approval_fixture()
  end

  test "REST review and owner polling expose metadata and resume once", c do
    body = post(api(c), "/v1/tool_calls", Jason.encode!(write_payload())) |> json_response(409)
    id = body["error"]["approval_id"]
    assert body["error"]["code"] == "approval_required"
    assert body["error"]["approval_status"] == "pending"
    polled = get(api(c), "/v1/approvals/#{id}") |> json_response(200)
    refute Jason.encode!(polled) =~ "Synthetic private"
    assert get(api(c), "/v1/approvals/#{Ecto.UUID.generate()}") |> json_response(403)
    approve(c, Repo.get!(Approval, id))
    conn = api(c) |> put_req_header("x-approval-id", id)
    assert post(conn, "/v1/tool_calls", Jason.encode!(write_payload())) |> json_response(200)
    assert post(conn, "/v1/tool_calls", Jason.encode!(write_payload())) |> json_response(409)
    assert Repo.get!(Run, c.run.id).calls == 1
  end

  test "MCP uses the same session and JSON-RPC ID for resume", c do
    session = initialize(c)

    conn =
      agent_conn(c, session)
      |> put_req_header("x-run-id", c.run.id)
      |> put_req_header("x-run-participant-id", c.participant.id)

    message = tool_message("file.write", write_payload()["arguments"], 42)
    initial = post(conn, "/mcp", Jason.encode!(message)) |> json_response(200)
    assert initial["result"]["isError"]
    assert initial["result"]["_meta"]["code"] == "approval_required"
    id = initial["result"]["_meta"]["approval_id"]
    approve(c, Repo.get!(Approval, id))
    resumed = conn |> put_req_header("x-approval-id", id)
    wrong_id = tool_message("file.write", write_payload()["arguments"], 43)

    assert post(resumed, "/mcp", Jason.encode!(wrong_id))
           |> json_response(200)
           |> get_in(["result", "_meta", "code"]) == "approval_conflict"

    # A conflicting resume burns the approval; use a separate logical operation.
    next = tool_message("file.write", write_payload()["arguments"], 44)
    wait = post(conn, "/mcp", Jason.encode!(next)) |> json_response(200)
    next_id = wait["result"]["_meta"]["approval_id"]
    approve(c, Repo.get!(Approval, next_id))

    result =
      conn
      |> put_req_header("x-approval-id", next_id)
      |> post("/mcp", Jason.encode!(next))
      |> json_response(200)

    assert result["result"]["isError"] == false
    assert Workflows.evidence(Repo.get!(Run, c.run.id)).tool_calls == 1
  end

  test "chat requires idempotency only for review and releases reservations while waiting", c do
    assert api(c)
           |> delete_req_header("idempotency-key")
           |> post("/v1/chat/completions", Jason.encode!(request()))
           |> json_response(400)

    wait = post(api(c), "/v1/chat/completions", Jason.encode!(request())) |> json_response(409)
    id = wait["error"]["approval_id"]
    refute_received {:generated, _}
    record = Repo.get!(Approval, id)
    assert {:ok, preview} = Cipher.decrypt(record)
    assert preview["thinking"] == %{"type" => "disabled"}
    assert preview["model"] == "deepseek-flash"
    assert Repo.get!(Run, c.run.id).reserved_tokens == 0
    assert Enum.all?(Repo.all(Reservation), &(&1.status == "released"))
    again = post(api(c), "/v1/chat/completions", Jason.encode!(request())) |> json_response(409)
    assert again["error"]["approval_id"] == id
    approve(c, record)
    resumed = api(c) |> put_req_header("x-approval-id", id)
    assert post(resumed, "/v1/chat/completions", Jason.encode!(request())) |> json_response(200)
    assert_received {:generated, ^preview}
    assert post(resumed, "/v1/chat/completions", Jason.encode!(request())) |> json_response(409)
    refute_received {:generated, _}
    assert %{calls: 1, tokens: 16, reserved_tokens: 0} = Repo.get!(Run, c.run.id)
    assert Repo.get_by!(Operation, run_id: c.run.id).status == "finished"
  end

  test "operator generation parameter changes invalidate the prepared payload", c do
    assert {:error, {:approval_required, %{approval_id: id}}} = chat(c)
    record = Repo.get!(Approval, id)
    assert {:ok, preview} = Cipher.decrypt(record)
    assert preview["thinking"] == %{"type" => "disabled"}
    assert preview["max_tokens"] == Config.get(:default_max_tokens)
    approve(c, record)

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :default_max_tokens, 512)
    )

    assert {:error, :approval_conflict} = chat(c, approval_id: id)
    assert %{status: "invalidated", ciphertext: nil} = Repo.get!(Approval, id)
    refute_received {:generated, _}
  end

  test "SSE responds with JSON review before starting a stream, then completes", c do
    backend =
      start_supervised!(
        {Bandit,
         plug: {AiControl.TestStreamHTTPPlug, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: :approval_backend
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(backend)

    config =
      Config.get()
      |> Keyword.delete(:http_plug)
      |> Keyword.put(:base_url, "http://127.0.0.1:#{port}")

    Application.put_env(:ai_control, Config, config)
    params = Map.put(request(), "stream", true) |> Map.put("max_tokens", 4)

    conn =
      api(c)
      |> put_req_header("accept", "text/event-stream")
      |> post("/v1/chat/completions", Jason.encode!(params))

    id = json_response(conn, 409)["error"]["approval_id"]
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    refute_received {:upstream_started, _}
    assert Repo.get!(Run, c.run.id).reserved_tokens == 0
    approve(c, Repo.get!(Approval, id))

    assert {:ok, session} =
             Gateway.start_stream(c.principal, params,
               run_context: c.reference,
               idempotency_key: c.key,
               approval_id: id
             )

    ref = Process.monitor(session)
    Stream.begin(session)
    assert_receive {:upstream_started, upstream}, 2000
    send(upstream, {:release, stream_body()})
    assert_receive {^session, {:ready, _}}, 2000

    assert :ok =
             Stream.complete(session, %{"sent_chunks" => 1, "sent_bytes" => 16})

    Stream.delivered(session)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2000
    assert %{status: "consumed", ciphertext: nil} = Repo.get!(Approval, id)
    assert Repo.get!(Run, c.run.id).calls == 1
  end

  test "delegation waits before participant creation and consumes one operation", c do
    target = AiControl.AgentsFixtures.agent_fixture(c.scope)
    params = %{"target_agent_id" => target.id}
    path = "/v1/runs/#{c.run.id}/delegations"
    first = post(api(c), path, Jason.encode!(params)) |> json_response(409)
    id = first["error"]["approval_id"]
    assert Repo.aggregate(Participant, :count) == 1
    approve(c, Repo.get!(Approval, id))

    assert api(c)
           |> put_req_header("x-approval-id", id)
           |> post(path, Jason.encode!(params))
           |> json_response(200)

    assert Repo.aggregate(Participant, :count) == 2
    assert Repo.get!(Run, c.run.id).calls == 1
    assert Repo.get!(Approval, id).status == "consumed"
  end

  test "RAG revision changes and completed workflow deny an approved operation", c do
    review_policy(c.scope, %{"knowledge" => %{"enabled" => true, "memory_write_enabled" => true}})
    document = document_fixture(c.scope, c.agent)
    params = Map.put(request(), "context", %{"query" => "support"})
    assert {:error, {:approval_required, %{approval_id: id}}} = chat(c, [], params)
    approve(c, Repo.get!(Approval, id))

    Repo.update_all(from(r in AiControl.Knowledge.Resource, where: r.id == ^document["id"]),
      inc: [revision: 1]
    )

    assert {:error, :approval_conflict} = chat(c, [approval_id: id], params)
    refute_received {:generated, _}
    next = %{c | key: Ecto.UUID.generate()}
    record = pending(next)
    approve(next, record)
    assert {:ok, _} = Workflows.transition(c.principal, c.run.id, "complete")
    assert Repo.get!(Approval, record.id).status == "invalidated"

    assert {:error, :workflow_terminal} =
             review_call(next, write_payload(), approval_id: record.id)

    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  defp api(c) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> c.token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", c.key)
    |> put_req_header("x-run-id", c.run.id)
    |> put_req_header("x-run-participant-id", c.participant.id)
  end
end
