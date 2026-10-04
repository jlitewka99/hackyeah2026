defmodule AiControl.Approvals.LiveTest do
  use AiControl.DataCase, async: false

  import AiControl.ApprovalsFixtures

  alias AiControl.Approvals.Approval
  alias AiControl.{Gateway, Repo}
  alias AiControl.Gateway.Config
  alias AiControl.Policies.Configuration
  alias AiControl.Workflows.Run

  @moduletag :live_models
  @moduletag timeout: 240_000

  test "real pinned models, controls and tokenizer run only after approval" do
    old = Application.fetch_env!(:ai_control, Config)

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.drop([:http_plug, :ner_http_plug, :tokenizer_http_plug, :semantic_http_plug])
      |> Keyword.put(:models, Jason.decode!(File.read!("priv/models/ollama-demo.json")))
      |> Keyword.put(:guards, Config.guard_modules())
      |> Keyword.put(:tokenizer, AiControl.Budgets.Tokenizer)
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    c = approval_fixture()

    review_policy(c.scope, %{
      "guards" =>
        Map.new(
          Configuration.guards(6),
          &{&1, %{"enabled" => true, "required" => true}}
        )
    })

    params = %{
      "model" => "qwen3.5:4b",
      "max_tokens" => 64,
      "messages" => [
        %{"role" => "user", "content" => "Oblicz dwa plus dwa. Odpowiedz krótko po polsku."}
      ]
    }

    opts = [run_context: c.reference, idempotency_key: c.key]

    assert {:error, {:approval_required, %{approval_id: id}}} =
             Gateway.chat(c.principal, params, opts)

    assert %{tokens: 0, reserved_tokens: 0, calls: 1} = Repo.get!(Run, c.run.id)
    approve(c, Repo.get!(Approval, id))

    assert {:ok, response} =
             Gateway.chat(c.principal, params, Keyword.put(opts, :approval_id, id))

    assert response["usage"]["total_tokens"] > 0
    assert %{status: "consumed", ciphertext: nil} = Repo.get!(Approval, id)
    assert %{tokens: tokens, reserved_tokens: 0, calls: 1} = Repo.get!(Run, c.run.id)
    assert tokens == response["usage"]["total_tokens"]

    assert {:error, :approval_used} =
             Gateway.chat(c.principal, params, Keyword.put(opts, :approval_id, id))
  end
end
