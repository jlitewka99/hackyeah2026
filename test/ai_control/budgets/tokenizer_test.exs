defmodule AiControl.Budgets.TokenizerTest do
  use ExUnit.Case, async: true

  import AiControl.GatewayFixtures

  alias AiControl.Budgets.Tokenizer
  alias AiControl.Gateway.{Config, DeepSeek}
  alias AiControl.Guards.Granite.Model

  @manifest Jason.decode!(File.read!("sidecar/tokenizer/models.v1.json"))
  defp artifacts do
    %{
      "model" => "deepseek-flash",
      "encoding" => "v41",
      "recipe_version" => "0.1.1",
      "tokenizer_sha256" => hd(@manifest["files"])["sha256"]
    }
  end

  test "count sends full prepared request and verifies artifact identity" do
    config = Keyword.put(Config.get(), :tokenizer_http_plug, {Req.Test, __MODULE__})
    {:ok, prepared} = DeepSeek.prepare(request(), config)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"model" => "deepseek-flash", "request" => prepared}
      Req.Test.json(conn, Map.put(artifacts(), "tokens", 17))
    end)

    assert {:ok, 17} = Tokenizer.count("deepseek-flash", prepared, config)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(
        conn,
        artifacts() |> Map.put("tokens", 17) |> Map.put("recipe_version", "other")
      )
    end)

    assert {:error, :tokenizer_unavailable} = Tokenizer.count("deepseek-flash", prepared, config)
  end

  test "readiness requires pinned recipe, encoding and tokenizer hash" do
    config = Keyword.put(Config.get(), :tokenizer_http_plug, {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, Map.put(artifacts(), "status", "ready")))
    assert Tokenizer.ready?(config)
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"status" => "ready"}))
    refute Tokenizer.ready?(config)
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, String.duplicate("x", 4097)))
    refute Tokenizer.ready?(config)
  end

  test "shared sidecar preserves separate DeepSeek artifacts and Granite digest checks" do
    config = Keyword.put(Config.get(), :tokenizer_http_plug, {Req.Test, __MODULE__})

    ready =
      Map.merge(artifacts(), %{
        "status" => "ready",
        "models" => %{Model.name() => Model.digest()},
        "runtime" => "0.35.1"
      })

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, ready))
    assert Tokenizer.ready?(config)
    assert Tokenizer.pinned_ready?(Model.name(), Model.digest(), config)
    refute Tokenizer.pinned_ready?("deepseek-flash", Model.digest(), config)
    refute Tokenizer.pinned_ready?(Model.name(), "changed", config)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "model" => Model.name(),
               "digest" => Model.digest(),
               "prompt" => "guard prompt"
             }

      Req.Test.json(conn, %{tokens: 100, digest: Model.digest(), runtime: "0.35.1"})
    end)

    assert {:ok, 100} =
             Tokenizer.count_pinned(Model.name(), Model.digest(), "guard prompt", config)

    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{tokens: 100, digest: "changed", runtime: "0.35.1"})
    )

    assert {:error, :tokenizer_unavailable} =
             Tokenizer.count_pinned(Model.name(), Model.digest(), "guard prompt", config)
  end
end
