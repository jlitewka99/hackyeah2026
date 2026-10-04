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

  def stream_chunk(delta, finish \\ nil) do
    Jason.encode!(%{
      "id" => "backend-id",
      "created" => 1,
      "model" => "qwen3.5:4b",
      "object" => "chat.completion.chunk",
      "choices" => [
        %{"index" => 0, "delta" => delta, "finish_reason" => finish}
      ]
    })
  end

  def stream_body(parts \\ ["Bezpieczna odpowiedź"]) do
    chunks = Enum.map(parts, &stream_chunk(%{"content" => &1}))

    Enum.map_join(
      chunks ++ [stream_chunk(%{}, "stop"), stream_usage(), "[DONE]"],
      &("data: " <> &1 <> "\n\n")
    )
  end

  def stream_usage do
    Jason.encode!(%{
      "id" => "backend-id",
      "created" => 1,
      "model" => "qwen3.5:4b",
      "object" => "chat.completion.chunk",
      "choices" => [],
      "usage" => response()["usage"]
    })
  end
end
