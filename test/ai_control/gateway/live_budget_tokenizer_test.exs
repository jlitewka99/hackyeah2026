defmodule AiControl.Gateway.LiveBudgetTokenizerTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.Budgets.Reservation
  alias AiControl.{Gateway, Repo}
  alias AiControl.Gateway.Config

  @moduletag :live_models
  @moduletag timeout: 180_000

  test "pinned tokenizer counts the actual Polish, history and tool prompts exactly" do
    old = Application.fetch_env!(:ai_control, Config)
    models = File.read!("priv/models/ollama-demo.json") |> Jason.decode!()

    Application.put_env(
      :ai_control,
      Config,
      old |> Keyword.put(:models, models) |> Keyword.delete(:http_plug)
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)

    activate_gateway_policy(scope, %{
      "budgets" => %{"organization" => %{"tokens_per_hour" => 10_000}}
    })

    history = [
      %{"role" => "system", "content" => "Odpowiadaj krótko po polsku."},
      %{"role" => "user", "content" => "Czym jest Kraków?"},
      %{"role" => "assistant", "content" => "Miastem w Polsce."},
      %{"role" => "user", "content" => "Czy leży nad Wisłą?"}
    ]

    tools = [
      %{
        "type" => "function",
        "function" => %{
          "name" => "city_info",
          "description" => "Informacje o mieście",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"city" => %{"type" => "string"}}
          }
        }
      }
    ]

    tool_history = [
      %{"role" => "user", "content" => "Sprawdź Kraków."},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => "call_city",
            "type" => "function",
            "function" => %{"name" => "city_info", "arguments" => ~s({"city":"Kraków"})}
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => "call_city", "content" => "Kraków leży nad Wisłą."},
      %{"role" => "user", "content" => "Podsumuj wynik."}
    ]

    for {scenario, params} <- [
          {:polish, request()},
          {:history, Map.put(request(), "messages", history)},
          {:tools, Map.put(request(), "tools", tools)},
          {:tool_history,
           request() |> Map.put("tools", tools) |> Map.put("messages", tool_history)}
        ] do
      id = Ecto.UUID.generate()

      assert {:ok, response} =
               Gateway.chat(principal, Map.put(params, "max_tokens", 32), request_id: id)

      receipt = Repo.get_by!(Reservation, request_id: id)
      assert receipt.input_tokens == response["usage"]["prompt_tokens"]
      assert receipt.usage == response["usage"]
      assert receipt.status == "settled"
      assert receipt.reserved_tokens == receipt.input_tokens + 32

      IO.puts(
        "tokenizer acceptance #{scenario}: input=#{receipt.input_tokens} actual=#{response["usage"]["prompt_tokens"]} output=#{response["usage"]["completion_tokens"]}"
      )
    end
  end
end
