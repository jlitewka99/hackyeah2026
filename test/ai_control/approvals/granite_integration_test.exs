defmodule AiControl.Approvals.GraniteIntegrationTest do
  use AiControl.DataCase, async: false

  import AiControl.ApprovalsFixtures

  alias AiControl.Approvals.Approval
  alias AiControl.Gateway.Config
  alias AiControl.Guards.Granite
  alias AiControl.Policies.ConfigurationV6
  alias AiControl.Repo
  alias AiControl.Tools.Sandbox

  setup do
    c = approval_fixture()
    review_policy(c.scope, %{"granite" => Map.put(ConfigurationV6.defaults(), "enabled", true)})
    old = Application.fetch_env!(:ai_control, Config)
    score = start_supervised!({Agent, fn -> "yes" end})
    parent = self()

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.merge(
        guards: %{"granite" => Granite},
        granite_provider: AiControl.TestGraniteProvider,
        test_granite: fn _, _ ->
          send(parent, :granite_called)

          {:ok, Agent.get(score, & &1),
           %{"prompt_tokens" => 40, "completion_tokens" => 6, "total_tokens" => 46}}
        end
      )
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    Map.put(c, :score, score)
  end

  test "Granite refuses before an approval is created and before any effect", c do
    Agent.update(c.score, fn _ -> "no" end)
    assert {:error, :policy_blocked} = review_call(c)
    assert_received :granite_called
    assert Repo.aggregate(Approval, :count) == 0
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "approved resume runs Granite again and its refusal prevents the effect", c do
    record = pending(c)
    assert_received :granite_called
    approve(c, record)
    Agent.update(c.score, fn _ -> "no" end)
    assert {:error, :policy_blocked} = review_call(c, write_payload(), approval_id: record.id)
    assert_received :granite_called
    assert %{status: "invalidated", ciphertext: nil} = Repo.get!(Approval, record.id)
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "approval plus a successful Granite recheck dispatches exactly once", c do
    record = pending(c)
    assert_received :granite_called
    approve(c, record)
    assert {:ok, _} = review_call(c, write_payload(), approval_id: record.id)
    assert_received :granite_called
    assert %{status: "consumed", ciphertext: nil} = Repo.get!(Approval, record.id)

    assert Sandbox.inspect_state(c.sandbox).files["copy.txt"] ==
             write_payload()["arguments"]["content"]

    assert {:error, :approval_used} = review_call(c, write_payload(), approval_id: record.id)
    refute_received :granite_called
  end
end
