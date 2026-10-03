defmodule AiControl.Tools.HTTPTest do
  use ExUnit.Case, async: true

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

  defp endpoint(port, path),
    do: %{uri: URI.parse("http://demo.invalid:#{port}#{path}"), ip: {127, 0, 0, 1}}
end
