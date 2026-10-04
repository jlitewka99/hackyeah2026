defmodule AiControl.Gateway.StreamHTTPTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.Budgets.Reservation
  alias AiControl.{Gateway, Repo}
  alias AiControl.Gateway.{Config, Slots, Stream}

  setup do
    backend =
      start_supervised!(
        {Bandit,
         plug: {AiControl.TestStreamHTTPPlug, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: :stream_backend
      )

    {:ok, {_, backend_port}} = ThousandIsland.listener_info(backend)

    frontend =
      start_supervised!(
        {Bandit,
         plug: AiControlWeb.Endpoint,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [transport_options: [sndbuf: 1024]]},
        id: :stream_frontend
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(frontend)
    old = Application.fetch_env!(:ai_control, Config)

    config =
      old
      |> Keyword.delete(:http_plug)
      |> Keyword.put(:base_url, "http://127.0.0.1:#{backend_port}")
      |> Keyword.put(:stream_heartbeat_ms, 20)
      |> Keyword.put(:tokenizer, AiControl.TestBudgetTokenizer)

    Application.put_env(:ai_control, Config, config)
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    {_, token} = key_fixture(scope, agent)
    principal = principal_fixture(scope, agent)

    activate_gateway_policy(scope, %{
      "budgets" => %{"organization" => %{"tokens_per_hour" => 5000}}
    })

    %{
      url: "http://127.0.0.1:#{port}/v1/chat/completions",
      token: token,
      principal: principal,
      scope: scope
    }
  end

  test "real sockets send heartbeats without content until the complete guarded response",
       context do
    response = client(context)
    assert_receive {:upstream_started, upstream}
    ref = response.body.ref
    assert_receive {^ref, _} = message
    assert {:ok, [data: heartbeat]} = Req.parse_message(response, message)
    assert heartbeat =~ ": keepalive"
    refute heartbeat =~ "data:"
    send(upstream, {:release, stream_body(["Łódź", " is safe."])})
    body = Enum.to_list(response.body) |> IO.iodata_to_binary()
    assert body =~ "Łódź is safe."
    assert body =~ "[DONE]"
  end

  test "real client disconnect cancels upstream and retains dispatched reservation", context do
    response = client(context)
    assert_receive {:upstream_started, upstream}
    upstream_ref = Process.monitor(upstream)
    [session] = sessions()
    session_ref = Process.monitor(session)
    assert :ok = Req.cancel_async_response(response)
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 2000
    assert_receive {:DOWN, ^upstream_ref, :process, ^upstream, _}, 2000
    receipt = Repo.get_by!(Reservation, organization_id: context.scope.organization.id)
    assert receipt.status == "uncertain"
    assert receipt.reserved_tokens == 112
    assert :sys.get_state(Slots).leases == %{}

    assert Repo.exists?(
             from(e in AiControl.Audit.Event,
               where: e.request_id == ^receipt.request_id and e.event_type == "gateway.cancelled"
             )
           )
  end

  test "prepared cancellation releases tokens before any model dispatch", context do
    assert {:ok, session} = Gateway.start_stream(context.principal, stream_request())
    ref = Process.monitor(session)
    assert :ok = Stream.cancel(session)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    receipt = Repo.get_by!(Reservation, organization_id: context.scope.organization.id)
    assert receipt.status == "released"

    assert Repo.get_by!(AiControl.Budgets.Bucket,
             organization_id: context.scope.organization.id,
             level: "organization"
           ).reserved == 0

    refute_received {:upstream_started, _}
  end

  test "socket disconnect during approved delivery records partial writes and settles usage once",
       context do
    uri = URI.parse(context.url)

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false, recbuf: 1024], 2000)

    on_exit(fn -> :gen_tcp.close(socket) end)
    body = Jason.encode!(stream_request())

    :ok =
      :gen_tcp.send(socket, [
        "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n",
        "Authorization: Bearer ",
        context.token,
        "\r\nContent-Type: application/json\r\nAccept: text/event-stream\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])

    assert_receive {:upstream_started, upstream}, 2000
    [session] = sessions()
    ref = Process.monitor(session)
    assert read_until(socket, ": keepalive") =~ "200"
    send(upstream, {:release, stream_body([String.duplicate("safe", 600_000)])})
    assert read_until(socket, ~s("role":"assistant")) =~ "data:"
    :ok = :gen_tcp.close(socket)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5000
    receipt = Repo.get_by!(Reservation, organization_id: context.scope.organization.id)
    assert receipt.status == "settled"
    assert receipt.usage["total_tokens"] == 16

    event =
      Repo.one!(
        from(e in AiControl.Audit.Event,
          where: e.request_id == ^receipt.request_id and e.event_type == "gateway.cancelled"
        )
      )

    assert event.data["stream"]["delivery"] == "cancelled"
    assert event.data["stream"]["sent_chunks"] > 0
    assert event.data["stream"]["sent_bytes"] < 2_400_000
    assert :sys.get_state(Slots).leases == %{}
  end

  test "owner death cleans a generating session and a later call can acquire its slot", context do
    owner = self()

    child =
      start_supervised!(
        {Task,
         fn ->
           {:ok, session} = Gateway.start_stream(context.principal, stream_request())
           Stream.begin(session)
           send(owner, {:session, session})

           receive do
             :finish_owner -> :ok
           end
         end}
      )

    assert_receive {:session, session}
    assert_receive {:upstream_started, upstream}
    session_ref = Process.monitor(session)
    upstream_ref = Process.monitor(upstream)
    send(child, :finish_owner)
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 2000
    assert_receive {:DOWN, ^upstream_ref, :process, ^upstream, _}, 2000
    assert :sys.get_state(Slots).leases == %{}
  end

  test "one policy snapshot is retained during activation while the upstream is held", context do
    {:ok, session} = Gateway.start_stream(context.principal, stream_request())
    Stream.begin(session)
    assert_receive {:upstream_started, upstream}
    original = :sys.get_state(session).policy.version
    activate_gateway_policy(context.scope, %{"allowed_models" => []})
    send(upstream, {:release, stream_body()})
    assert_receive {^session, {:ready, _}}, 2000
    assert :ok = Stream.complete(session, %{"sent_bytes" => 0, "sent_chunks" => 0})
    assert :ok = Stream.delivered(session)
    receipt = Repo.get_by!(Reservation, organization_id: context.scope.organization.id)

    events =
      Repo.all(from(e in AiControl.Audit.Event, where: e.request_id == ^receipt.request_id))

    assert Enum.all?(events, &(&1.policy_version == original))
  end

  test "generation timeout cancels the real upstream without releasing dispatched tokens",
       context do
    Application.put_env(:ai_control, Config, Keyword.put(Config.get(), :llm_timeout, 100))
    response = client(context)
    assert_receive {:upstream_started, upstream}
    ref = Process.monitor(upstream)
    body = Enum.to_list(response.body) |> IO.iodata_to_binary()
    assert body =~ "upstream_timeout"
    refute body =~ "[DONE]"
    assert_receive {:DOWN, ^ref, :process, ^upstream, _}, 2000

    assert Repo.get_by!(Reservation, organization_id: context.scope.organization.id).status ==
             "uncertain"

    assert :sys.get_state(Slots).leases == %{}
  end

  test "delivery watchdog interrupts a stalled caller after usage has been settled", context do
    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :stream_delivery_timeout_ms, 50)
    )

    owner = self()

    child =
      start_supervised!(
        {Task,
         fn ->
           {:ok, session} = Gateway.start_stream(context.principal, stream_request())
           Stream.begin(session)
           send(owner, {:session, session})

           receive do
             {^session, {:ready, _}} -> send(owner, :delivery_ready)
           end

           receive do
             :finish_owner -> :ok
           end
         end}
      )

    assert_receive {:session, session}
    assert_receive {:upstream_started, upstream}
    session_ref = Process.monitor(session)
    child_ref = Process.monitor(child)
    send(upstream, {:release, stream_body()})
    assert_receive :delivery_ready, 2000
    assert_receive {:DOWN, ^child_ref, :process, ^child, :killed}, 2000
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 2000
    receipt = Repo.get_by!(Reservation, organization_id: context.scope.organization.id)
    assert receipt.status == "settled"
    assert receipt.usage["total_tokens"] == 16

    assert Repo.exists?(
             from(e in AiControl.Audit.Event,
               where:
                 e.request_id == ^receipt.request_id and
                   "stream_delivery_timeout" in e.reason_codes
             )
           )
  end

  defp client(context),
    do:
      Req.post!(context.url,
        json: stream_request(),
        retry: false,
        headers: [{"authorization", "Bearer " <> context.token}, {"accept", "text/event-stream"}],
        into: :self
      )

  defp stream_request, do: request() |> Map.put("stream", true) |> Map.put("max_tokens", 100)

  defp sessions,
    do: DynamicSupervisor.which_children(AiControl.Gateway.Streams) |> Enum.map(&elem(&1, 1))

  defp read_until(socket, marker, accumulated \\ "") do
    if String.contains?(accumulated, marker) do
      accumulated
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      read_until(socket, marker, accumulated <> data)
    end
  end
end
