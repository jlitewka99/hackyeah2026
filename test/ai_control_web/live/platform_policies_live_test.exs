defmodule AiControlWeb.PlatformPoliciesLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  test "only organizers can open and export platform policies", %{conn: conn} do
    scope = organizer_scope_fixture()
    conn = log_in_user(conn, scope.user)
    {:ok, view, _} = live(conn, ~p"/platform/policies")
    assert has_element?(view, "#policy-page")
    assert has_element?(view, "#policy-new")
    member = member_fixture(organization_fixture())
    denied = conn |> log_in_user(member.user) |> get(~p"/platform/policies")
    assert html_response(denied, 403)
  end
end
