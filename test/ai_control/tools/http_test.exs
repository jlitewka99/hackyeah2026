defmodule AiControl.Tools.HTTPTest do
  use ExUnit.Case, async: false

  alias AiControl.Tools.HTTP

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: {AiControl.TestToolHTTPPlug, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  test "Req connects to pinned IP without DNS, preserving exact Host", %{port: port} do
    assert {:ok, %{"status" => 200, "body" => "Synthetic HTTP report"}} =
             HTTP.get(endpoint(port, "/ok"))

    assert_received {:tool_http_request, "/ok", [host]}
    assert host == "demo.invalid:#{port}"
    refute_received {:tool_http_request, _, _}
  end

  test "redirect is refused without contacting next target", %{port: port} do
    assert {:error, :tool_redirect_blocked} = HTTP.get(endpoint(port, "/redirect"))
    assert_received {:tool_http_request, "/redirect", _}
    refute_received {:tool_http_request, "/target", _}
  end

  test "oversized, invalid and error bodies do not escape or retry", %{port: port} do
    for path <- ["/large", "/invalid", "/fail"] do
      assert {:error, :tool_upstream_unavailable} = HTTP.get(endpoint(port, path))
      assert_received {:tool_http_request, ^path, _}
      refute_received {:tool_http_request, ^path, _}
    end
  end

  test "ambient Req credentials, headers and query params cannot bypass the resource ACL", %{
    port: port
  } do
    defaults = Req.default_options()
    on_exit(fn -> Req.default_options(defaults) end)

    Req.default_options(
      Keyword.merge(defaults,
        auth: {:bearer, "synthetic-ambient-token"},
        headers: [{"x-ambient", "private-example"}],
        params: [secret: "synthetic-query"]
      )
    )

    assert {:ok, %{"body" => "Synthetic HTTP report"}} = HTTP.get(endpoint(port, "/ok"))
    assert_received {:tool_http_details, "", [], []}
  end

  test "ambient Req plug cannot replace the pinned network transport", %{port: port} do
    defaults = Req.default_options()
    on_exit(fn -> Req.default_options(defaults) end)

    Req.default_options(
      Keyword.put(defaults, :plug, fn conn ->
        Plug.Conn.send_resp(conn, 200, "replaced transport")
      end)
    )

    assert {:ok, %{"body" => "Synthetic HTTP report"}} = HTTP.get(endpoint(port, "/ok"))
    assert_received {:tool_http_request, "/ok", _}
  end

  test "HTTPS verifies the original hostname and CA while connecting to the pinned IP" do
    key = {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}

    tls =
      :public_key.pkix_test_data(%{
        root: [digest: :sha256, key: key],
        peer: [
          digest: :sha256,
          key: key,
          extensions: [
            {:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"demo.invalid"}]}
          ]
        ]
      })

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {AiControl.TestToolHTTPPlug, self()},
           scheme: :https,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [transport_options: Keyword.take(tls, [:cert, :key])]},
          id: :tls_server
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    target = %{uri: URI.parse("https://demo.invalid:#{port}/ok"), ip: {127, 0, 0, 1}}
    original = Enum.map(:public_key.cacerts_get(), fn {:cert, der, _} -> der end)
    directory = Path.join(System.tmp_dir!(), "ai-control-tool-tls-#{Ecto.UUID.generate()}")
    File.mkdir!(directory)
    original_path = Path.join(directory, "original.pem")
    test_path = Path.join(directory, "test.pem")
    write_ca_bundle(original_path, original)
    write_ca_bundle(test_path, tls[:cacerts])

    on_exit(fn ->
      :ok = :public_key.cacerts_load(original_path)
      File.rm_rf!(directory)
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :tool_upstream_unavailable} = HTTP.get(target)
      refute_received {:tool_http_request, _, _}

      :ok = :public_key.cacerts_load(test_path)
      assert {:ok, %{"body" => "Synthetic HTTP report"}} = HTTP.get(target)
      assert_received {:tool_http_request, "/ok", [host]}
      assert host == "demo.invalid:#{port}"

      wrong_host = %{target | uri: URI.parse("https://wrong.invalid:#{port}/ok")}
      assert {:error, :tool_upstream_unavailable} = HTTP.get(wrong_host)
      refute_received {:tool_http_request, _, _}
    end)
  end

  defp write_ca_bundle(path, certificates) do
    entries = Enum.map(certificates, &{:Certificate, &1, :not_encrypted})
    File.write!(path, :public_key.pem_encode(entries))
  end

  defp endpoint(port, path),
    do: %{uri: URI.parse("http://demo.invalid:#{port}#{path}"), ip: {127, 0, 0, 1}}
end
