defmodule AiControl.OrganizationsTest do
  use AiControl.DataCase, async: true

  import AiControl.OrganizationsFixtures

  alias AiControl.Accounts.Scope
  alias AiControl.Organizations
  alias AiControl.Organizations.{Access, Grants, Membership}

  test "only the organizer creates organizations and supplied owner IDs are ignored" do
    scope = organization_fixture()
    user = member_fixture(scope)

    assert {:error, :forbidden} =
             Organizations.create_organization(user.scope, %{name: "Forbidden"})

    assert {:ok, organization} =
             Organizations.create_organization(scope, %{name: "Allowed", status: "suspended"})

    assert organization.status == :active
  end

  test "memberships and queries cannot cross organization boundaries" do
    first = organization_fixture()
    second = organization_fixture()
    admin = member_fixture(first, :admin)
    other = member_fixture(second)
    assert {:error, :not_found} = Organizations.fetch_scope(admin.scope, second.organization.id)
    assert {:error, :not_found} = Organizations.get_member(admin.scope, other.membership.id)

    assert {:error, :not_found} =
             Organizations.update_member(admin.scope, other.membership.id, %{role: :admin})

    assert {:error, :not_found} = Organizations.remove_member(admin.scope, other.membership.id)

    assert Enum.map(Organizations.list_organizations(admin.scope), & &1.id) == [
             first.organization.id
           ]

    assert {:error, :not_found} = Organizations.fetch_scope(admin.scope, "invalid-uuid")
  end

  test "admin manages users but cannot edit admins, self, or promote a user" do
    scope = organization_fixture()
    admin = member_fixture(scope, :admin)
    second_admin = member_fixture(scope, :admin)
    user = member_fixture(scope)

    assert {:error, :forbidden} =
             Organizations.remove_member(admin.scope, second_admin.membership.id)

    assert {:error, :forbidden} =
             Organizations.update_member(admin.scope, admin.membership.id, %{
               grants: %{permissions: ["ai.use"]}
             })

    assert {:error, :forbidden} =
             Organizations.update_member(admin.scope, user.membership.id, %{role: :admin})

    assert {:ok, _} = Organizations.remove_member(admin.scope, user.membership.id)
  end

  test "admin delegation is limited and preserves grants outside their access" do
    scope = organization_fixture()
    admin = member_fixture(scope, :admin, %{permissions: ["events.read"]})
    user = member_fixture(scope, :user, %{permissions: ["policies.manage"]})

    assert {:error, :forbidden} =
             Organizations.update_member(admin.scope, user.membership.id, %{
               grants: %{permissions: ["ai.use"]}
             })

    assert {:ok, updated} =
             Organizations.update_member(admin.scope, user.membership.id, %{
               grants: %{permissions: ["events.read"]}
             })

    assert Enum.sort(updated.grants.permissions) == ["events.read", "policies.manage"]

    assert {:ok, updated} =
             Organizations.update_member(admin.scope, user.membership.id, %{
               grants: %{permissions: []}
             })

    assert updated.grants.permissions == ["policies.manage"]

    assert {:error, :forbidden} =
             Organizations.update_member(admin.scope, user.membership.id, %{
               grants: %{agents: ["*"]}
             })
  end

  test "superadmin can manage admins and transfer their role exactly once" do
    scope = organization_fixture()
    owner = member_fixture(scope, :superadmin, %{permissions: ["events.read"]})
    admin = member_fixture(scope, :admin)
    assert {:error, :forbidden} = Organizations.remove_member(scope, owner.membership.id)

    assert {:ok, _} =
             Organizations.update_member(owner.scope, admin.membership.id, %{
               grants: %{permissions: ["policies.manage"]}
             })

    assert {:ok, transferred} =
             Organizations.transfer_superadmin(owner.scope, admin.membership.id)

    assert transferred.role == :superadmin
    previous = Repo.get!(Membership, owner.membership.id)
    assert previous.role == :admin
    assert previous.grants.permissions == ["events.read"]

    assert {:error, :forbidden} =
             Organizations.transfer_superadmin(owner.scope, admin.membership.id)
  end

  test "role and grants are refreshed rather than trusting stale scopes" do
    scope = organization_fixture()
    admin = member_fixture(scope, :admin, %{permissions: ["events.read"]})
    user = member_fixture(scope)
    assert {:ok, _} = Access.authorize(admin.scope, "events.read")

    assert {:ok, _} =
             Organizations.update_member(scope, admin.membership.id, %{
               role: :user,
               grants: %{permissions: []}
             })

    assert {:error, :forbidden} = Access.authorize(admin.scope, "events.read")
    assert {:error, :forbidden} = Organizations.remove_member(admin.scope, user.membership.id)
    assert {:error, :forbidden} = Access.authorize(user.scope, "policies.manage")
  end

  test "suspension blocks members but preserves access to another organization" do
    first = organization_fixture()
    second = organization_fixture()
    user = member_fixture(first)

    Repo.insert!(
      Membership.changeset(
        %Membership{organization_id: second.organization.id, user_id: user.user.id},
        %{role: :user}
      )
    )

    assert {:ok, _} = Organizations.set_status(first, :suspended)
    assert {:error, :not_found} = Organizations.refresh_scope(user.scope)
    assert {:ok, _} = Organizations.fetch_scope(Scope.for_user(user.user), second.organization.id)
    assert {:ok, suspended} = Organizations.refresh_scope(first)
    assert suspended.access_mode == :organizer
    assert {:ok, _} = Organizations.set_status(first, :active)
    assert {:ok, _} = Organizations.refresh_scope(user.scope)
  end

  test "unknown permissions and resources are rejected even with a wildcard" do
    scope = organization_fixture()
    user = member_fixture(scope)

    assert {:error, %Ecto.Changeset{}} =
             Organizations.update_member(scope, user.membership.id, %{
               grants: %{permissions: ["everything"]}
             })

    assert {:error, :unknown_resource} =
             Organizations.update_member(scope, user.membership.id, %{
               grants: %{agents: [Ecto.UUID.generate()]}
             })

    assert {:error, :forbidden} =
             Access.authorize(scope, "ai.use", %{agent: Ecto.UUID.generate(), model: "unknown"})

    assert {:error, :forbidden} = Access.authorize(scope, "ai.use")
    assert Grants.subset?(%Grants{agents: ["one"]}, %Grants{agents: ["*"]})
    refute Grants.subset?(%Grants{agents: ["*"]}, %Grants{agents: ["one"]})
  end
end
