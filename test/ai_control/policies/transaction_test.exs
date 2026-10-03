defmodule AiControl.Policies.TransactionTest do
  use AiControl.DataCase, async: false

  import AiControl.OrganizationsFixtures
  import ExUnit.CaptureLog

  alias AiControl.Policies
  alias AiControl.Policies.{Activation, Configuration, Version}

  test "audit rejection rolls back activation and suppresses PubSub" do
    scope = organization_fixture()
    {:ok, current} = Policies.current(scope)
    {:ok, version} = Policies.create_version(scope, Configuration.default())
    Phoenix.PubSub.subscribe(AiControl.PubSub, Policies.topic(scope, :organization))
    reject("policy.activated")

    assert {:error, :audit_unavailable} =
             Policies.activate(scope, version.id, current.set.revision)

    assert {:ok, unchanged} = Policies.current(scope)
    assert unchanged.version.id == current.version.id
    assert unchanged.set.revision == current.set.revision
    assert Repo.aggregate(from(a in Activation, where: a.set_id == ^current.set.id), :count) == 0
    refute_received :policies_changed
  end

  test "a failed version audit leaves no version and no submitted values in logs" do
    scope = organization_fixture()
    reject("policy.version_created")
    {:ok, current} = Policies.current(scope)
    text = "sensitive-marker-DO-NOT-LOG"
    source = Map.put(Configuration.default(), "allowed_models", [text])

    logs =
      capture_log([level: :debug], fn ->
        assert {:error, :audit_unavailable} = Policies.create_version(scope, source)
        assert {:error, _} = Policies.import_yaml("unknown: #{text}")
      end)

    refute logs =~ text
    assert Repo.aggregate(from(v in Version, where: v.set_id == ^current.set.id), :count) == 0
  end

  test "failed platform audit cannot change the inherited global policy" do
    scope = organizer_scope_fixture()
    {:ok, current} = Policies.current(scope, :global)

    {:ok, version} =
      Policies.create_version(
        scope,
        Map.put(Configuration.default(), "profile", "strict"),
        :global
      )

    reject("policy.activated")

    assert {:error, :audit_unavailable} =
             Policies.activate(scope, version.id, current.set.revision, :global)

    assert {:ok, unchanged} = Policies.current(scope, :global)
    assert unchanged.version.id == current.version.id
  end

  defp reject(event) do
    Repo.query!(
      "ALTER TABLE audit_events ADD CONSTRAINT policy_audit_test_rejection CHECK (event_type <> '#{event}') NOT VALID",
      [],
      log: false
    )
  end
end
