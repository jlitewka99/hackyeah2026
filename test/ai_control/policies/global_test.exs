defmodule AiControl.Policies.GlobalTest do
  use AiControl.DataCase, async: false

  import AiControl.OrganizationsFixtures

  alias AiControl.{Audit, Policies}
  alias AiControl.Policies.Configuration

  test "global changes reach inheriting organizations and leave overrides independent" do
    organizer = organizer_scope_fixture()
    first = organization_fixture()
    second = organization_fixture()
    {:ok, second_current} = Policies.current(second)
    {:ok, own} = Policies.create_version(second, Configuration.default())
    {:ok, _} = Policies.activate(second, own.id, second_current.set.revision)
    {:ok, global} = Policies.current(organizer, :global)

    {:ok, version} =
      Policies.create_version(
        organizer,
        Map.put(Configuration.default(), "profile", "strict"),
        :global
      )

    {:ok, _} = Policies.activate(organizer, version.id, global.set.revision, :global)
    {:ok, inherited} = Policies.current(first)
    assert inherited.version.id == version.id
    assert inherited.inherited?
    {:ok, independent} = Policies.current(second)
    assert independent.version.id == own.id
    {:ok, _} = Policies.inherit(second, independent.set.revision)
    {:ok, inherited} = Policies.current(second)
    assert inherited.version.id == version.id
    assert {:ok, organization_events} = Audit.list_events(second)
    restored = Enum.find(organization_events, &(&1.event_type == "policy.inheritance_restored"))
    assert restored.data["after"]["policy_source"] == "global"
    assert restored.data["after"]["policy_version_id"] == version.id
    assert restored.data["after"]["policy_checksum"] == version.checksum
    assert {:ok, events} = Audit.list_platform_events(organizer)
    assert Enum.count(events, &(&1.event_type == "policy.activated")) == 1
    assert Enum.all?(events, &is_nil(&1.organization_id))
    assert {:ok, organization_events} = Audit.list_events(first)
    refute Enum.any?(organization_events, &(&1.scope == :platform))
    assert {:error, :forbidden} = Audit.list_platform_events(member_fixture(first).scope)
  end

  test "global policies cannot select a tenant's concrete agent" do
    organizer = organizer_scope_fixture()
    source = Map.put(Configuration.default(), "allowed_agents", [Ecto.UUID.generate()])
    assert {:error, [{"allowed_agents", _}]} = Policies.create_version(organizer, source, :global)
  end

  test "cache owner can restart and snapshots rebuild from persisted versions" do
    organizer = organizer_scope_fixture()
    {:ok, current} = Policies.current(organizer, :global)
    assert :ok = Supervisor.terminate_child(AiControl.Supervisor, AiControl.Policies.Cache)
    assert {:ok, rebuilt} = Policies.current(organizer, :global)
    assert rebuilt.snapshot == current.snapshot
    assert {:ok, _} = Supervisor.restart_child(AiControl.Supervisor, AiControl.Policies.Cache)
    {:ok, rebuilt} = Policies.current(organizer, :global)
    assert rebuilt.snapshot == current.snapshot
  end
end
