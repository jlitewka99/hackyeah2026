defmodule AiControl.Policies.GuardContractTest do
  use AiControl.DataCase, async: true

  import AiControl.OrganizationsFixtures
  import AiControl.SecurityFixtures

  alias AiControl.Policies.{Configuration, Version}
  alias AiControl.Policy.{Engine, Snapshot}

  test "semantic availability follows profiles and configured stages" do
    scope = organization_fixture()

    for {profile, stage, expected} <- [
          {"relaxed", :input, :allow},
          {"balanced", :input, :block},
          {"strict", :output, :allow}
        ] do
      policy = snapshot(Map.put(Configuration.default(), "profile", profile))
      context = context_fixture(scope, policy, %{stage: stage})
      results = for guard <- ~w(pii secret signatures), do: result_fixture(%{guard: guard})

      assert {:ok, decision} =
               Engine.evaluate(context, assessment_fixture(context, results), policy)

      assert decision.action == expected
    end
  end

  test "disabled guards cannot enforce their findings and every decision setting changes checksum" do
    scope = organization_fixture()

    source =
      Map.put(Configuration.default(), "guards", %{
        "pii" => %{"enabled" => false, "required" => false}
      })

    policy = snapshot(source)
    context = context_fixture(scope, policy)

    results =
      for guard <- ~w(pii secret signatures semantic),
          do:
            result_fixture(%{
              guard: guard,
              detections: if(guard == "pii", do: [detection_fixture()], else: [])
            })

    assert {:ok, %{action: :allow}} =
             Engine.evaluate(context, assessment_fixture(context, results), policy)

    id = Ecto.UUID.generate()
    base = snapshot(Configuration.default(), id)

    for {key, value} <- [
          {"allowed_models", []},
          {"allowed_agents", []},
          {"agent_models", %{Ecto.UUID.generate() => []}},
          {"budgets", %{"workflow" => %{"tool_calls" => 0}}},
          {"guards", %{"semantic" => %{"required" => false}}}
        ] do
      refute snapshot(Map.put(Configuration.default(), key, value), id).checksum == base.checksum
    end
  end

  defp snapshot(source, id \\ Ecto.UUID.generate()) do
    {:ok, config} = Configuration.validate(source)
    {:ok, snapshot} = Snapshot.from_version(%Version{id: id, settings: config.settings})
    snapshot
  end
end
