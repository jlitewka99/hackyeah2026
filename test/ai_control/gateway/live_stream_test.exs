defmodule AiControl.Gateway.LiveStreamTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.Gateway.Config
  alias AiControl.Guards.{Pii, Secret, Signatures}
  alias AiControl.{Policies, Repo}
  alias AiControl.Policies.Configuration

  @moduletag :live_models
  @moduletag timeout: 180_000

  test "real DeepSeek completes SSE through actual deterministic output guards" do
    old = Application.fetch_env!(:ai_control, Config)
    models = File.read!("priv/models/deepseek-demo.json") |> Jason.decode!()

    config =
      old
      |> Keyword.put(:api_key, System.fetch_env!("DEEPSEEK_API_KEY"))
      |> Keyword.delete(:http_plug)
      |> Keyword.put(:models, models)
      |> Keyword.put(:guards, %{"pii" => Pii, "secret" => Secret, "signatures" => Signatures})

    Application.put_env(:ai_control, Config, config)
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    {_, token} = key_fixture(scope, agent)

    guards =
      Map.new(Configuration.guards(3), &{&1, %{"enabled" => false, "required" => false}})
      |> Map.merge(
        Map.new(~w(pii secret signatures), &{&1, %{"enabled" => true, "required" => true}})
      )

    {:ok, version} =
      Policies.create_version(scope, Configuration.default(3) |> Map.put("guards", guards))

    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)

    server =
      start_supervised!(
        {Bandit, plug: AiControlWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    response =
      Req.post!("http://127.0.0.1:#{port}/v1/chat/completions",
        headers: [{"authorization", "Bearer " <> token}, {"accept", "text/event-stream"}],
        retry: false,
        receive_timeout: 150_000,
        json: %{
          "model" => "deepseek-flash",
          "stream" => true,
          "max_tokens" => 64,
          "stream_options" => %{"include_usage" => true},
          "messages" => [
            %{
              "role" => "user",
              "content" => "Odpowiedz jednym krótkim zdaniem: czym jest Kraków?"
            }
          ]
        }
      )

    assert response.status == 200
    assert response.body =~ "data: [DONE]"
    refute response.body =~ "event: error"
    receipt = Repo.get_by!(AiControl.Budgets.Reservation, organization_id: scope.organization.id)
    assert receipt.status == "settled"
    assert receipt.usage["total_tokens"] > 0
  end
end
