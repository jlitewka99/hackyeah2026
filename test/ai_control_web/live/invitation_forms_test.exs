defmodule AiControlWeb.InvitationFormsTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AccountsFixtures
  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions, only: [set_swoosh_global: 1]

  alias AiControl.Organizations

  setup :set_swoosh_global

  test "invitation form delegates multiple concrete agents", %{conn: conn} do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    other = agent_fixture(scope)

    {:ok, view, _} =
      live(log_in_user(conn, scope.user), ~p"/organizations/#{scope.organization.id}/members")

    assert has_element?(view, "#invite-access-agent-#{agent.id}[type=checkbox]")

    view
    |> form("#member-invitation-form",
      invitation: %{email: "agents@example.test", role: "user"},
      access: %{
        permissions: ["agents.read"],
        agents: ["false", agent.id, "false", other.id],
        all_agents: "false"
      }
    )
    |> render_submit()

    assert {:ok, [invitation]} = Organizations.list_invitations(scope)
    assert Enum.sort(invitation.grants.agents) == Enum.sort([agent.id, other.id])
    assert has_element?(view, "#invite-access-agent-#{agent.id}[checked]")
    assert has_element?(view, "#invite-access-agent-#{other.id}[checked]")
  end

  test "member invitation shows email errors and clears them after successful submission", %{
    conn: conn
  } do
    organization = organization_fixture()

    {:ok, view, _} =
      live(
        log_in_user(conn, organization.user),
        ~p"/organizations/#{organization.organization.id}/members"
      )

    access = %{permissions: ["events.read"], all_agents: "true", all_models: "true"}
    invalid_email = String.duplicate("x", 150) <> "@example.com"

    view
    |> form("#member-invitation-form",
      invitation: %{email: invalid_email, role: "admin"},
      access: access
    )
    |> render_submit()

    assert has_element?(view, "#member-invitation-form .field-error[role=alert]", "160")
    assert has_element?(view, "#invitation_email[aria-invalid=true]")
    assert has_element?(view, "#invitation_email[value='#{invalid_email}']")
    assert has_element?(view, "#invitation_role option[value=admin][selected]")
    assert {:ok, []} = Organizations.list_invitations(organization)
    refute_receive {:email, %Swoosh.Email{}}

    email = unique_user_email()

    view
    |> form("#member-invitation-form",
      invitation: %{email: email, role: "admin"},
      access: access
    )
    |> render_submit()

    refute has_element?(view, "#member-invitation-form .field-error")
    refute has_element?(view, "#invitation_email[aria-invalid=true]")
    assert has_element?(view, "#invitation_email[value='#{email}']")
    assert has_element?(view, "#invitation_role option[value=admin][selected]")
    assert {:ok, [invitation]} = Organizations.list_invitations(organization)
    assert invitation.email == email
    assert invitation.role == :admin
    assert invitation.grants.permissions == ["events.read"]
    assert invitation.grants.agents == ["*"]
    assert invitation.grants.models == ["*"]
    assert has_element?(view, "#invitations-#{invitation.id}")
    assert_receive {:email, %Swoosh.Email{to: [{_, ^email}]}}
  end

  test "first superadmin invitation shows email errors and retains the organization on success",
       %{
         conn: conn
       } do
    organization = organization_fixture()
    id = organization.organization.id
    {:ok, view, _} = live(log_in_user(conn, organization.user), ~p"/platform/organizations")
    invalid_email = String.duplicate("x", 150) <> "@example.com"

    view
    |> form("#owner-invitation-form",
      invitation: %{email: invalid_email, organization_id: id}
    )
    |> render_submit()

    assert has_element?(view, "#owner-invitation-form .field-error[role=alert]", "160")
    assert has_element?(view, "#invitation_email[aria-invalid=true]")
    assert has_element?(view, "#invitation_email[value='#{invalid_email}']")
    assert has_element?(view, "#owner-organization option[value='#{id}'][selected]")
    assert {:ok, []} = Organizations.list_invitations(organization)
    refute_receive {:email, %Swoosh.Email{}}

    email = unique_user_email()

    view
    |> form("#owner-invitation-form", invitation: %{email: email, organization_id: id})
    |> render_submit()

    refute has_element?(view, "#owner-invitation-form .field-error")
    refute has_element?(view, "#invitation_email[aria-invalid=true]")
    assert has_element?(view, "#invitation_email[value='#{email}']")
    assert has_element?(view, "#owner-organization option[value='#{id}'][selected]")
    assert {:ok, [invitation]} = Organizations.list_invitations(organization)
    assert invitation.email == email
    assert invitation.role == :superadmin
    assert_receive {:email, %Swoosh.Email{to: [{_, ^email}]}}
  end
end
