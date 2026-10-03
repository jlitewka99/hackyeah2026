defmodule AiControlWeb.ModelAccessLiveTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.Gateway.Config
  alias AiControl.Organizations
  alias AiControl.Organizations.{Invitation, Membership}
  alias AiControl.Repo

  test "specific models can be assigned on invitation and member access", %{conn: conn} do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    scope = organization_fixture()
    member = member_fixture(scope)
    conn = log_in_user(conn, scope.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/members")
    assert has_element?(view, "#invite-access-specific-models")
    assert has_element?(view, "#invite-access-model-1[value='qwen3.5:4b']")

    view
    |> form("#member-invitation-form",
      invitation: %{email: "models@example.test", role: "user"},
      access: %{models: ["qwen3.5:4b"], all_models: "false"}
    )
    |> render_submit()

    assert Repo.get_by!(Invitation, email: "models@example.test").grants.models == ["qwen3.5:4b"]

    {:ok, view, _} =
      live(
        conn,
        ~p"/organizations/#{scope.organization.id}/members/#{member.membership.id}/access"
      )

    view
    |> form("#member-access-form",
      access: %{models: ["catalog-model"], all_models: "false", role: "user"}
    )
    |> render_submit()

    assert_redirect(view, ~p"/organizations/#{scope.organization.id}/members")
    assert Repo.get!(Membership, member.membership.id).grants.models == ["catalog-model"]
  end

  test "admin choices respect delegation and preserve inaccessible existing models", %{conn: conn} do
    scope = organization_fixture()
    admin = member_fixture(scope, :admin, %{permissions: ["ai.use"], models: ["qwen3.5:4b"]})
    member = member_fixture(scope, :user, %{models: ["catalog-model"]})
    conn = log_in_user(conn, admin.user)

    {:ok, view, _} =
      live(
        conn,
        ~p"/organizations/#{scope.organization.id}/members/#{member.membership.id}/access"
      )

    assert has_element?(view, "#member-access-all-models[disabled]")
    assert has_element?(view, "#member-access-model-0[value='qwen3.5:4b']")
    refute has_element?(view, "input[name='access[models][]'][value='catalog-model']")

    view
    |> form("#member-access-form",
      access: %{models: ["qwen3.5:4b"], role: "user"}
    )
    |> render_submit()

    assert_redirect(view, ~p"/organizations/#{scope.organization.id}/members")

    assert Repo.get!(Membership, member.membership.id).grants.models |> Enum.sort() == [
             "catalog-model",
             "qwen3.5:4b"
           ]

    assert {:ok, _} = Organizations.refresh_scope(admin.scope)
  end

  test "an empty operator catalog has a clear resource state", %{conn: conn} do
    old = Application.fetch_env!(:ai_control, Config)
    Application.put_env(:ai_control, Config, Keyword.put(old, :models, %{}))
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture()

    {:ok, view, _} =
      live(log_in_user(conn, scope.user), ~p"/organizations/#{scope.organization.id}/members")

    assert has_element?(view, "#invite-access-specific-models p")
    refute has_element?(view, "input[name='access[models][]']")
  end
end
