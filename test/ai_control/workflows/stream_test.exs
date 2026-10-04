defmodule AiControl.Workflows.StreamTest do
  use AiControl.DataCase, async: false

  import AiControl.GatewayFixtures
  import AiControl.WorkflowsFixtures

  alias AiControl.Budgets.Reservation
  alias AiControl.{Gateway, Repo, Workflows}
  alias AiControl.Gateway.{Config, Stream}
  alias AiControl.Workflows.{Manager, Run, Runtime}

  setup do
    backend =
      start_supervised!(
        {Bandit,
         plug: {AiControl.TestStreamHTTPPlug, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: :workflow_stream_backend
      )

    {:ok, {_, backend_port}} = ThousandIsland.listener_info(backend)

    frontend =
      start_supervised!(
        {Bandit, plug: AiControlWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: :workflow_stream_frontend
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(frontend)
    old = Application.fetch_env!(:ai_control, Config)

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.delete(:http_plug)
      |> Keyword.put(:base_url, "http://127.0.0.1:#{backend_port}")
      |> Keyword.put(:tokenizer, AiControl.TestBudgetTokenizer)
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    context = workflow_fixture()

    Map.merge(context, %{
      url: "http://127.0.0.1:#{port}/v1/chat/completions",
      opts: [run_context: %{run_id: context.run.id, participant_id: context.participant.id}]
    })
  end

  test "streaming cannot bypass v5 context through either domain or HTTP", c do
    assert {:error, :workflow_context_required} =
             Gateway.start_stream(c.principal, stream_request())

    response =
      Req.post!(c.url,
        json: stream_request(),
        retry: false,
        headers: [{"authorization", "Bearer " <> c.token}, {"accept", "text/event-stream"}]
      )

    assert response.status == 400
    assert response.body["error"]["code"] == "workflow_context_required"
    assert Repo.get!(Run, c.run.id).calls == 0
    refute_received {:upstream_started, _}
  end

  test "HTTP stream shares root accounting and stays active until delivery finishes", c do
    response =
      Req.post!(c.url,
        json: stream_request(),
        retry: false,
        headers: [
          {"authorization", "Bearer " <> c.token},
          {"accept", "text/event-stream"},
          {"x-run-id", c.run.id},
          {"x-run-participant-id", c.participant.id}
        ],
        into: :self
      )

    assert_receive {:upstream_started, upstream}, 2000
    [session] = sessions()
    ref = Process.monitor(session)
    assert {:error, :workflow_conflict} = Workflows.transition(c.principal, c.run.id, "complete")
    send(upstream, {:release, stream_body(["Synthetic safe response"])})
    body = Enum.to_list(response.body) |> IO.iodata_to_binary()
    assert body =~ "Synthetic safe response"
    assert body =~ "[DONE]"
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2000
    run = Repo.get!(Run, c.run.id)
    assert run.calls == 1
    assert run.tokens == 16
    assert run.reserved_tokens == 0
    assert {:ok, %{status: "completed"}} = Workflows.transition(c.principal, c.run.id, "complete")
  end

  test "stop during streaming preparation cancels unsent work and releases its reservation", c do
    owner = self()

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_tokenizer, fn _, _ ->
        send(owner, {:tokenizer_held, self()})

        receive do
          :release -> {:ok, 12}
        end
      end)
    )

    start_supervised!(
      {Task,
       fn ->
         result = Gateway.start_stream(c.principal, stream_request(), c.opts)
         send(owner, {:prepared_result, result})
       end}
    )

    assert_receive {:tokenizer_held, worker}, 2000
    worker_ref = Process.monitor(worker)
    [session] = sessions()
    session_ref = Process.monitor(session)
    assert {:ok, _} = Workflows.transition(c.principal, c.run.id, "stop")
    assert_receive {:prepared_result, {:error, :workflow_terminal}}, 2000
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 2000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 2000
    assert receipt(c).status == "released"
    assert Repo.get!(Run, c.run.id).reserved_tokens == 0
    refute_received {:upstream_started, _}
  end

  test "stop after stream dispatch retains uncertain usage without another effect", c do
    assert {:ok, session} = Gateway.start_stream(c.principal, stream_request(), c.opts)
    ref = Process.monitor(session)
    Stream.begin(session)
    assert_receive {:upstream_started, upstream}, 2000
    upstream_ref = Process.monitor(upstream)
    assert {:ok, _} = Workflows.transition(c.principal, c.run.id, "stop")
    assert_receive {^session, {:error, :workflow_terminal}}, 2000
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2000
    assert_receive {:DOWN, ^upstream_ref, :process, ^upstream, _}, 2000
    assert receipt(c).status == "uncertain"
    run = Repo.get!(Run, c.run.id)
    assert run.reserved_tokens == 16
    assert run.calls == 1

    assert {:error, :workflow_terminal} =
             Gateway.start_stream(c.principal, stream_request(), c.opts)

    refute_received {:upstream_started, _}
  end

  test "controlled workflow deadline interrupts a dispatched stream", c do
    instant = Workflows.now()
    clock = start_supervised!({Agent, fn -> instant end})
    old = Application.get_env(:ai_control, Workflows, [])
    Application.put_env(:ai_control, Workflows, clock: fn -> Agent.get(clock, & &1) end)
    on_exit(fn -> Application.put_env(:ai_control, Workflows, old) end)
    assert {:ok, session} = Gateway.start_stream(c.principal, stream_request(), c.opts)
    ref = Process.monitor(session)
    Stream.begin(session)
    assert_receive {:upstream_started, _}, 2000
    Agent.update(clock, fn _ -> c.run.deadline end)
    send(session, :workflow_deadline)
    assert_receive {^session, {:error, :workflow_limit_exceeded}}, 2000
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2000
    assert Repo.get!(Run, c.run.id).reason == "max_duration_seconds"
    assert receipt(c).status == "uncertain"
    assert Repo.get!(Run, c.run.id).reserved_tokens == 16
  end

  test "runtime loss blocks stream release but still settles reported actual tokens", c do
    assert {:ok, session} = Gateway.start_stream(c.principal, stream_request(), c.opts)
    ref = Process.monitor(session)
    Stream.begin(session)
    assert_receive {:upstream_started, upstream}, 2000

    [{runtime, _}] =
      Registry.lookup(AiControl.Workflows.Registry, {c.run.organization_id, c.run.id})

    runtime_ref = Process.monitor(runtime)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, :killed}
    _ = :sys.get_state(Manager)
    assert Repo.get!(Run, c.run.id).status == "interrupted"
    send(upstream, {:release, stream_body()})
    assert_receive {^session, {:error, :workflow_terminal}}, 2000
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2000
    assert receipt(c).status == "settled"
    assert Repo.get!(Run, c.run.id).tokens == 16
    refute Runtime.present?(c.run.organization_id, c.run.id)
  end

  defp stream_request, do: request() |> Map.put("stream", true) |> Map.put("max_tokens", 4)
  defp receipt(c), do: Repo.get_by!(Reservation, run_id: c.run.id)

  defp sessions,
    do: DynamicSupervisor.which_children(AiControl.Gateway.Streams) |> Enum.map(&elem(&1, 1))
end
