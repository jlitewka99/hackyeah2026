defmodule AiControlWeb.RequestLogTest do
  use AiControlWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias AiControl.Security.HTTPError

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "nested parameters, headers, keys and forged request IDs stay out of DEBUG logs", %{
    conn: conn
  } do
    secret = "private-nested-content"

    logs =
      capture_log(fn ->
        response =
          conn
          |> put_req_header("authorization", "Bearer private-bearer-token")
          |> put_req_header("x-request-id", "private-client-request-id")
          |> post(~p"/users/log-in", %{
            "user" => %{
              "email" => "private-email@example.com",
              "password" => "private-login-password"
            },
            secret => %{secret => [secret]}
          })

        assert response.status == 302
        [id] = get_resp_header(response, "x-request-id")
        assert {:ok, _} = Ecto.UUID.cast(id)
        refute id == "private-client-request-id"
      end)

    assert logs =~ "status=302"
    refute logs =~ secret
    refute logs =~ "private-bearer-token"
    refute logs =~ "private-login-password"
    refute logs =~ "private-email@example.com"
    refute logs =~ "private-client-request-id"
  end

  test "unknown raw paths never appear in request or error logs", %{conn: conn} do
    logs =
      capture_log(fn ->
        response = get(conn, "/private-path-secret?prompt=private-query-secret")
        assert response.status == 404
      end)

    refute logs =~ "private-path-secret"
    refute logs =~ "private-query-secret"
    assert logs =~ "code=not_found"
  end

  test "malformed JSON has a generic HTTP response and content-free log over real Bandit" do
    server =
      start_supervised!(
        {Bandit,
         plug: AiControlWeb.Endpoint,
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false,
         http_options: Application.fetch_env!(:ai_control, :http_log_options)}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    logs =
      capture_log(fn ->
        response =
          Req.post!("http://127.0.0.1:#{port}/users/log-in",
            retry: false,
            headers: [{"content-type", "application/json"}, {"accept", "application/json"}],
            body: "{private-json-body-secret"
          )

        assert response.status == 400
        refute inspect(response.body) =~ "private-json-body-secret"
      end)

    refute logs =~ "private-json-body-secret"
    assert logs =~ "code=invalid_request"
  end

  test "raw exception messages are suppressed by the real HTTP adapter" do
    server =
      start_supervised!(
        {Bandit,
         plug: AiControl.HTTPExceptionPlug,
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false,
         http_options: Application.fetch_env!(:ai_control, :http_log_options)}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    logs =
      capture_log(fn ->
        response = Req.get!("http://127.0.0.1:#{port}/private-raw-path", retry: false)
        assert response.status == 500
        refute inspect(response.body) =~ "private-http-exception-body"
      end)

    refute logs =~ "private-http-exception-body"
    refute logs =~ "private-raw-path"
  end

  test "safe error telemetry ignores exception payload and request data", %{conn: conn} do
    conn = AiControlWeb.ServerRequestId.call(conn, [])

    logs =
      capture_log(fn ->
        :telemetry.execute([:phoenix, :error_rendered], %{duration: 10}, %{
          conn: conn,
          status: 500,
          kind: :error,
          reason: %RuntimeError{message: "private-telemetry-exception"},
          stacktrace: [],
          log: :error
        })
      end)

    assert logs =~ "code=internal_error"
    refute logs =~ "private-telemetry-exception"
  end

  test "Req retries and redirects cannot log raw exception bodies or URLs" do
    Req.Test.stub(__MODULE__, fn conn ->
      put_in(conn.private[:req_test_exception], %RuntimeError{message: "private-req-error-body"})
    end)

    logs =
      capture_log(fn ->
        assert {:error, error} =
                 Req.get("http://model.invalid?token=private-req-query",
                   plug: {Req.Test, __MODULE__},
                   retry: fn _, exception -> is_exception(exception) end,
                   retry_delay: 0,
                   max_retries: 1
                 )

        assert HTTPError.classify(error) == :upstream_invalid_response
      end)

    refute logs =~ "private-req-error-body"
    refute logs =~ "private-req-query"

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_header("location", "http://model.invalid/final?token=private-redirect-secret")
      |> send_resp(302, "")
    end)

    Req.Test.expect(__MODULE__, fn conn -> send_resp(conn, 200, "ok") end)

    logs =
      capture_log(fn ->
        assert {:ok, %{status: 200}} =
                 Req.get("http://model.invalid", plug: {Req.Test, __MODULE__})
      end)

    refute logs =~ "private-redirect-secret"
    assert HTTPError.classify(%Req.TransportError{reason: :timeout}) == :upstream_timeout
    assert HTTPError.classify(%Req.TransportError{reason: :closed}) == :upstream_unavailable

    assert HTTPError.classify(%Req.Response{status: 500, body: "private-response"}) ==
             :upstream_rejected
  end
end
