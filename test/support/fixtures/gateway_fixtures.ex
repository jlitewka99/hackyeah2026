defmodule AiControl.GatewayFixtures do
  @moduledoc "Explicit local test policies; never alters the platform policy."
  alias AiControl.{ApiKeys, Policies}
  alias AiControl.Policies.Configuration

  def principal_fixture(scope, agent) do
    {_key, token} = AiControl.AgentsFixtures.key_fixture(scope, agent)
    {:ok, principal} = ApiKeys.authenticate(token)
    principal
  end

  def activate_gateway_policy(scope, overrides \\ %{}) do
    guards = Map.new(Configuration.guards(), &{&1, %{"enabled" => false, "required" => false}})
    source = Configuration.default() |> Map.put("guards", guards) |> Map.merge(overrides)
    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    version
  end

  def request,
    do: %{
      "model" => "qwen3.5:4b",
      "messages" => [%{"role" => "user", "content" => "Zażółć gęślą jaźń"}]
    }

  def response(content \\ "Bezpieczna odpowiedź"),
    do: %{
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => content}, "finish_reason" => "stop"}
      ],
      "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4, "total_tokens" => 16}
    }
end
