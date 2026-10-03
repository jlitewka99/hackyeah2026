defmodule AiControlWeb.WorkspaceSwitcherTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.AccountsFixtures
  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.Organizations
  alias AiControl.Organizations.Membership
  alias AiControl.Repo

  @desktop "desktop-navigation-workspace-switcher"
  @mobile "mobile-navigation-workspace-switcher"

  test "both switchers display the current workspace and navigate to another", %{conn: conn} do
    first = organization_fixture(%{name: "Alpha"})
    second = organization_fixture(%{name: "beta"})
    conn = log_in_user(conn, first.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{first.organization.id}")

    for id <- [@desktop, @mobile] do
      assert has_element?(view, "##{id}-trigger", "Alpha")
      view |> element("##{id}-trigger") |> render_click()
      assert has_element?(view, "##{id}-option-#{first.organization.id}-link[aria-current=true]")
      assert has_element?(view, "##{id}-option-#{second.organization.id}-link")

      view |> form("##{id}-search-form", workspace_search: %{query: "BETA"}) |> render_change()
      refute has_element?(view, "##{id}-option-#{first.organization.id}-link")
      assert has_element?(view, "##{id}-option-#{second.organization.id}-link")
      view |> element("##{id}-trigger") |> render_click()
    end

    view |> element("##{@desktop}-trigger") |> render_click()

    assert {:ok, next, _} =
             view
             |> element("##{@desktop}-option-#{second.organization.id}-link")
             |> render_click()
             |> follow_redirect(conn, ~p"/organizations/#{second.organization.id}")

    assert has_element?(next, "##{@desktop}-trigger", "beta")
  end

  test "search has an empty state and resets when reopened", %{conn: conn} do
    organization = organization_fixture()
    {:ok, view, _} = live(log_in_user(conn, organization.user), ~p"/users/settings")
    view |> element("##{@desktop}-trigger") |> render_click()

    view
    |> form("##{@desktop}-search-form", workspace_search: %{query: "missing"})
    |> render_change()

    refute has_element?(view, "##{@desktop}-options [data-workspace-option]")
    assert has_element?(view, "##{@desktop}-empty", "No workspaces found")
    view |> element("##{@desktop}-trigger") |> render_click()
    refute has_element?(view, "##{@desktop}-panel")
    view |> element("##{@desktop}-trigger") |> render_click()
    assert has_element?(view, "##{@desktop}-option-#{organization.organization.id}-link")
  end

  test "ordinary accounts only see active memberships and updates reach settings", %{conn: conn} do
    first = organization_fixture()
    second = organization_fixture()
    hidden = organization_fixture()
    member = member_fixture(first)

    membership =
      Repo.insert!(
        Membership.changeset(
          %Membership{organization_id: second.organization.id, user_id: member.user.id},
          %{role: :user}
        )
      )

    {:ok, view, _} = live(log_in_user(conn, member.user), ~p"/users/settings")
    view |> element("##{@desktop}-trigger") |> render_click()
    assert has_element?(view, "##{@desktop}-option-#{first.organization.id}-link")
    assert has_element?(view, "##{@desktop}-option-#{second.organization.id}-link")
    refute has_element?(view, "##{@desktop}-option-#{hidden.organization.id}-link")

    assert {:ok, _} = Organizations.remove_member(second, membership.id)
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "##{@desktop}-option-#{second.organization.id}-link")
    assert has_element?(view, "##{@desktop}-option-#{first.organization.id}-link")

    assert {:ok, _} = Organizations.set_status(first, :suspended)
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "##{@desktop}-options [data-workspace-option]")
    assert has_element?(view, "##{@desktop}-empty", "No workspaces available")
  end

  test "organizers see newly created and suspended workspaces without reloading", %{conn: conn} do
    organizer = organizer_scope_fixture()
    {:ok, view, _} = live(log_in_user(conn, organizer.user), ~p"/users/settings")
    view |> element("##{@desktop}-trigger") |> render_click()

    assert {:ok, organization} =
             Organizations.create_organization(organizer, %{name: "New workspace"})

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "##{@desktop}-option-#{organization.id}-link")
    {:ok, scope} = Organizations.fetch_scope(organizer, organization.id)
    assert {:ok, _} = Organizations.set_status(scope, :suspended)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "##{@desktop}-option-#{organization.id}-link", "Suspended")
  end

  test "an account with no memberships can still use settings", %{conn: conn} do
    {:ok, view, _} = live(log_in_user(conn, user_fixture()), ~p"/users/settings")
    assert has_element?(view, "##{@desktop}-trigger", "Choose workspace")
    view |> element("##{@desktop}-trigger") |> render_click()
    assert has_element?(view, "##{@desktop}-empty", "No workspaces available")
    assert has_element?(view, "#email_form")
  end

  test "new workspaces update the open agents and API keys panels", %{conn: conn} do
    scope = organization_fixture()
    conn = log_in_user(conn, scope.user)

    for page <- ["agents", "api-keys"] do
      {:ok, view, _} = live(conn, "/organizations/#{scope.organization.id}/#{page}")
      view |> element("##{@desktop}-trigger") |> render_click()

      assert {:ok, organization} =
               Organizations.create_organization(scope, %{name: "New workspace from #{page}"})

      _ = :sys.get_state(view.pid)
      assert has_element?(view, "##{@desktop}-option-#{organization.id}-link")
    end
  end
end
