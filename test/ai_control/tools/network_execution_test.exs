defmodule AiControl.Tools.NetworkExecutionTest do
  use AiControl.DataCase, async: false

  import AiControl.ToolsFixtures

  alias AiControl.{Budgets, Repo}
  alias AiControl.Tools.{Config, Execution, Sandbox}

  setup do
    tool_fixture()
  end

  test "real HTTP goes through dispatch accounting, filtering and audit without retries",
       context do
    server =
      start_supervised!(
        {Bandit,
         plug: {AiControl.TestToolHTTPPlug, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    grant_endpoints(context, "http", port)

    assert {:ok, data} =
             tool_call(context, "http.get", %{"url" => "http://demo.invalid:#{port}/ok"})

    assert data.result == %{"status" => 200, "body" => "Synthetic HTTP report"}
    assert_received {:tool_http_request, "/ok", _}

    assert {:error, :tool_upstream_unavailable} =
             tool_call(context, "http.get", %{"url" => "http://demo.invalid:#{port}/fail"})

    assert_received {:tool_http_request, "/fail", _}
    refute_received {:tool_http_request, _, _}
    assert Enum.sum(Enum.map(Repo.all(Budgets.Workflow), & &1.calls)) == 2
    assert Enum.sort(Enum.map(Repo.all(Execution), & &1.status)) == ["completed", "failed"]
  end

  test "real HTTPS preserves CA and hostname verification through the firewall", context do
    key = {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}

    tls =
      :public_key.pkix_test_data(%{
        root: [digest: :sha256, key: key],
        peer: [
          digest: :sha256,
          key: key,
          extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"demo.invalid"}]}]
        ]
      })

    server =
      start_supervised!(
        {Bandit,
         plug: {AiControl.TestToolHTTPPlug, self()},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [transport_options: Keyword.take(tls, [:cert, :key])]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    grant_endpoints(context, "https", port)
    original = Enum.map(:public_key.cacerts_get(), fn {:cert, der, _} -> der end)
    dir = Path.join(System.tmp_dir!(), "step12b-tls-#{Ecto.UUID.generate()}")
    File.mkdir!(dir)
    original_path = Path.join(dir, "original.pem")
    test_path = Path.join(dir, "test.pem")

    for {path, certs} <- [{original_path, original}, {test_path, tls[:cacerts]}] do
      File.write!(
        path,
        :public_key.pem_encode(Enum.map(certs, &{:Certificate, &1, :not_encrypted}))
      )
    end

    on_exit(fn ->
      :ok = :public_key.cacerts_load(original_path)
      File.rm_rf!(dir)
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :tool_upstream_unavailable} =
               tool_call(context, "http.get", %{"url" => "https://demo.invalid:#{port}/ok"})

      refute_received {:tool_http_request, _, _}
      :ok = :public_key.cacerts_load(test_path)

      assert {:ok, data} =
               tool_call(context, "http.get", %{"url" => "https://demo.invalid:#{port}/ok"})

      assert data.result["status"] == 200
      assert_received {:tool_http_request, "/ok", _}
    end)
  end

  test "timeout after dispatch remains charged and uncertain without replay", context do
    original = Config.get()
    Application.put_env(:ai_control, Config, Keyword.put(original, :execution_timeout, 1_000))
    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)

    server =
      start_supervised!(
        {Bandit,
         plug: {AiControl.TestToolHTTPPlug, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    grant_endpoints(context, "http", port)
    key = Ecto.UUID.generate()
    arguments = %{"url" => "http://demo.invalid:#{port}/wait"}
    tasks = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(tasks, fn ->
        tool_call(context, "http.get", arguments, idempotency_key: key)
      end)

    assert_receive {:tool_http_waiting, handler}, 1_000
    assert {:ok, {:error, :tool_timeout}} = Task.yield(task, 2_000)
    send(handler, :release)
    _ = :sys.get_state(context.sandbox)

    assert %Execution{status: "uncertain", charged: true} = Repo.one!(Execution)
    assert Enum.sum(Enum.map(Repo.all(Budgets.Workflow), & &1.calls)) == 1

    assert {:error, {:tool_execution_exists, %{execution_status: "uncertain"}}} =
             tool_call(context, "http.get", arguments, idempotency_key: key)

    assert_received {:tool_http_request, "/wait", _}
    refute_received {:tool_http_request, _, _}
    assert Sandbox.inspect_state(context.sandbox).mailbox == []
  end

  defp grant_endpoints(context, scheme, port) do
    endpoints =
      Map.new(["/ok", "/fail", "/wait"], fn path ->
        {"#{scheme}://demo.invalid:#{port}#{path}", %{ip: {127, 0, 0, 1}, allow_private?: true}}
      end)

    :sys.replace_state(context.sandbox, fn state ->
      %{
        state
        | grants: %{
            context.agent.id => Map.put(state.grants[context.agent.id], :endpoints, endpoints)
          }
      }
    end)
  end
end
