defmodule AiControl.Gateway.LiveDeepSeekTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures
  import Ecto.Query

  alias AiControl.Gateway.Config

  @moduletag :live_models
  @moduletag timeout: 150_000

  test "real DeepSeek generates through the authenticated audited gateway", %{conn: conn} do
    old = Application.fetch_env!(:ai_control, Config)
    models = File.read!("priv/models/deepseek-demo.json") |> Jason.decode!()

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.put(:models, models)
      |> Keyword.put(:api_key, System.fetch_env!("DEEPSEEK_API_KEY"))
      |> Keyword.delete(:http_plug)
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture(%{name: "Isolated real DeepSeek acceptance"})
    agent = agent_fixture(scope)
    {_key, token} = key_fixture(scope, agent)
    activate_gateway_policy(scope)
    conn = conn |> put_req_header("authorization", "Bearer " <> token)
    models_conn = get(conn, "/v1/models")
    assert json_response(models_conn, 200)["data"] |> Enum.map(& &1["id"]) == ["deepseek-flash"]

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/chat/completions",
        Jason.encode!(%{
          "model" => "deepseek-flash",
          "stream" => false,
          "max_tokens" => 512,
          "messages" => [
            %{
              "role" => "user",
              "content" => "Odpowiedz jednym krótkim zdaniem po polsku: czym jest Kraków?"
            }
          ]
        })
      )

    response = json_response(conn, 200)
    content = get_in(response, ["choices", Access.at(0), "message", "content"])
    assert is_binary(content) && String.length(content) > 0
    assert response["usage"]["total_tokens"] > 0
    request_id = conn.assigns.request_id

    events =
      AiControl.Repo.all(from(e in AiControl.Audit.Event, where: e.request_id == ^request_id))

    assert Enum.count(events, &(&1.kind == :decision)) == 2
    assert Enum.any?(events, &(&1.kind == :gateway && &1.reason_codes == ["completed"]))
  end
end
