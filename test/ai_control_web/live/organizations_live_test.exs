defmodule AiControlWeb.OrganizationsLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.Organizations
  alias AiControl.Organizations.Membership
  alias AiControl.Repo

  test "organizer creates an organization through the actual form", %{conn: conn} do
    organizer = organizer_scope_fixture()
    {:ok, view, _} = live(log_in_user(conn, organizer.user), ~p"/platform/organizations")

    view
    |> form("#organization-create-form", organization: %{name: "New workspace"})
    |> render_submit()

    assert has_element?(view, "#organization-list a", "New workspace")
    assert has_element?(view, "#owner-invitation-form")
  end

  test "membership controls and routes follow administrative roles", %{conn: conn} do
    organization = organization_fixture()
    admin = member_fixture(organization, :admin, %{permissions: ["events.read"]})
    user = member_fixture(organization)
    other_admin = member_fixture(organization, :admin)
    conn = log_in_user(conn, admin.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{organization.organization.id}/members")
    assert has_element?(view, "#edit-#{user.membership.id}")
    refute has_element?(view, "#edit-#{other_admin.membership.id}")
    refute has_element?(view, "#remove-#{admin.membership.id}")
    assert has_element?(view, "#invite-access-ai-use[disabled]")
    assert has_element?(view, "#invite-access-events-read:not([disabled])")
    conn = log_in_user(conn, user.user)

    assert html_response(
             get(conn, ~p"/organizations/#{organization.organization.id}/members"),
             403
           )
  end

  test "forged member IDs and role submissions cannot cross a boundary", %{conn: conn} do
    first = organization_fixture()
    second = organization_fixture()
    admin = member_fixture(first, :admin)
    other = member_fixture(second)
    conn = log_in_user(conn, admin.user)
    assert html_response(get(conn, ~p"/organizations/#{second.organization.id}"), 404)
    {:ok, view, _} = live(conn, ~p"/organizations/#{first.organization.id}/members")
    render_click(view, "remove", %{id: other.membership.id})
    assert {:ok, _} = Organizations.refresh_scope(other.scope)

    render_submit(view, "invite", %{
      invitation: %{email: "forged@example.com", role: "admin"},
      access: %{permissions: ["ai.use"]}
    })

    assert has_element?(view, "#flash-group")
    assert {:ok, []} = Organizations.list_invitations(admin.scope)

    render_submit(view, "invite", %{
      invitation: %{email: "malformed@example.com", role: "user"},
      access: %{permissions: "events.read"}
    })

    assert has_element?(view, "#member-invitation-form")
    assert {:ok, []} = Organizations.list_invitations(admin.scope)
  end

  test "permission changes update an open view without refreshing", %{conn: conn} do
    organization = organization_fixture()
    user = member_fixture(organization, :user, %{permissions: ["events.read"]})

    {:ok, view, _} =
      live(log_in_user(conn, user.user), ~p"/organizations/#{organization.organization.id}")

    assert has_element?(view, "#permission-list p", "Events: read")

    assert {:ok, _} =
             Organizations.update_member(organization, user.membership.id, %{
               grants: %{permissions: []}
             })

    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#permission-list p", "Events: read")
    assert has_element?(view, "#permissions-empty")
  end

  test "membership removal redirects an open view and other organizations still work", %{
    conn: conn
  } do
    first = organization_fixture()
    second = organization_fixture()
    user = member_fixture(first)

    other = %Membership{
      organization_id: second.organization.id,
      user_id: user.user.id
    }

    Repo.insert!(Membership.changeset(other, %{role: :user}))
    conn = log_in_user(conn, user.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{first.organization.id}")
    assert {:ok, _} = Organizations.remove_member(first, user.membership.id)
    assert_redirect(view, ~p"/organizations")
    assert {:ok, _, _} = live(conn, ~p"/organizations/#{second.organization.id}")
    assert {:ok, _, _} = live(conn, ~p"/users/settings")
  end

  test "suspension and admin demotion invalidate open management views", %{conn: conn} do
    organization = organization_fixture()
    admin = member_fixture(organization, :admin)
    conn = log_in_user(conn, admin.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{organization.organization.id}/members")

    assert {:ok, _} =
             Organizations.update_member(organization, admin.membership.id, %{role: :user})

    assert_redirect(view, ~p"/organizations/#{organization.organization.id}")
    {:ok, overview, _} = live(conn, ~p"/organizations/#{organization.organization.id}")
    assert {:ok, _} = Organizations.set_status(organization, :suspended)
    assert_redirect(overview, ~p"/organizations")
  end

  test "access form stores selected function permissions", %{conn: conn} do
    organization = organization_fixture()
    user = member_fixture(organization)
    conn = log_in_user(conn, organization.user)

    {:ok, view, _} =
      live(
        conn,
        ~p"/organizations/#{organization.organization.id}/members/#{user.membership.id}/access"
      )

    view
    |> form("#member-access-form",
      access: %{
        role: "admin",
        permissions: ["events.read"],
        all_agents: "false",
        all_models: "false"
      }
    )
    |> render_submit()

    assert_redirect(view, ~p"/organizations/#{organization.organization.id}/members")
    assert {:ok, current} = Organizations.refresh_scope(user.scope)
    assert current.membership.role == :admin
    assert current.grants.permissions == ["events.read"]
  end
end
