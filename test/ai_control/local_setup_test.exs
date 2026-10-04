defmodule AiControl.LocalSetupTest do
  use ExUnit.Case, async: true

  import Req.Test, only: [verify_on_exit!: 1]

  alias AiControl.Guards.Granite.Model
  alias AiControl.LocalSetup

  setup :verify_on_exit!

  setup do
    %{name: Model.name(), digest: Model.digest()}
  end

  test "cached pinned model is verified without a download", %{name: name, digest: digest} do
    version()
    models(name, digest)

    assert :ok = prepare()
  end

  test "missing model is downloaded once and its full digest is checked", context do
    version()
    models(nil, nil)
    pull(context.name)
    models(context.name, context.digest)

    assert :ok = prepare()
  end

  test "cached mismatching digest fails without replacing the model", context do
    version()
    # Match the abbreviated prefix shown by the CLI, but differ in the full digest.
    different = String.slice(context.digest, 0, 12) <> String.duplicate("0", 52)
    models(context.name, different)

    assert_raise RuntimeError, ~r/different digest/, &prepare/0
  end

  test "downloaded mismatching digest also stops startup", context do
    version()
    models(nil, nil)
    pull(context.name)
    models(context.name, String.duplicate("b", 64))

    assert_raise RuntimeError, ~r/different digest/, &prepare/0
  end

  test "unsupported Ollama version stops before checking or downloading models" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/version"
      Req.Test.json(conn, %{version: "different"})
    end)

    assert_raise RuntimeError, ~r/requires Ollama 0.35.1/, &prepare/0
  end

  test "unavailable Ollama reports a fixed error without retries" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert_raise RuntimeError, ~r/Ollama is unavailable/, &prepare/0
  end

  test "failed download reports a fixed error without including the upstream body" do
    version()
    models(nil, nil)

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "private-upstream-detail"})
    end)

    error = assert_raise RuntimeError, ~r/model download failed/, &prepare/0
    refute error.message =~ "private-upstream-detail"
  end

  test "malformed model catalog stops startup" do
    version()

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{models: [%{name: "missing-digest"}]})
    end)

    assert_raise RuntimeError, ~r/invalid model catalog/, &prepare/0
  end

  defp prepare, do: LocalSetup.prepare_model!(plug: {Req.Test, __MODULE__})

  defp version do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/version"
      Req.Test.json(conn, %{version: "0.35.1"})
    end)
  end

  defp models(name, digest) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/tags"
      models = if name, do: [%{name: name, digest: digest}], else: []
      Req.Test.json(conn, %{models: models})
    end)
  end

  defp pull(name) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/pull"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"name" => name, "stream" => false}
      Req.Test.json(conn, %{status: "success"})
    end)
  end
end
