defmodule AiControlWeb.PlatformPoliciesLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  test "organizer upgrades a global draft without activating it", %{conn: conn} do
    scope = organizer_scope_fixture()
    {:ok, view, _} = live(log_in_user(conn, scope.user), ~p"/platform/policies")
    view |> element("#policy-new") |> render_click()
    view |> element("#policy-upgrade") |> render_click()
    assert has_element?(view, "#policy-draft-schema", "v6")
    view |> element("#policy-guards > summary") |> render_click()
    assert has_element?(view, "#policy-guard-moderation-mode option[value='']", "disabled")
    refute has_element?(view, "#policy-rule-prompt_injection-threshold")
    refute has_element?(view, "#policy-rule-content_safety-action option[value='redact']")

    view
    |> form("#policy-form", %{
      "policy" => %{
        "guards" => %{
          "semantic" => %{"severities" => ["Unsafe", "Controversial"]},
          "moderation" => %{
            "mode" => "required",
            "categories" => ["Violent", "PII"],
            "severities" => ["Unsafe"]
          }
        }
      }
    })
    |> render_change()

    assert has_element?(view, "#policy-schema", "v1")
    view |> form("#policy-form") |> render_submit()
    assert has_element?(view, "#policy-diff-schema_version")
    assert has_element?(view, "#policy-activate")
    assert has_element?(view, "#policy-diff-guards-moderation-enabled")
    assert has_element?(view, "#policy-diff-guards-semantic-severities")
    assert has_element?(view, "#policy-schema", "v1")
  end

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
