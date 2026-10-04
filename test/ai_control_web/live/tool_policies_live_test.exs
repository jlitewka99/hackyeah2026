defmodule AiControlWeb.ToolPoliciesLiveTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.Policies
  alias AiControl.Policies.{Configuration, Draft, YAML}
  alias AiControl.Tools.Catalog
  alias AiControlWeb.PolicyHTML

  test "tool checkboxes persist through save, review, activation and export", %{conn: conn} do
    scope = organization_fixture()
    conn = log_in_user(conn, scope.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    view |> element("#policy-new") |> render_click()
    view |> element("#policy-upgrade") |> render_click()
    view |> element("#policy-tools > summary") |> render_click()

    for tool <- Catalog.all() do
      assert has_element?(view, "#" <> PolicyHTML.tool_id(tool["name"]))
    end

    view
    |> form("#policy-form",
      policy: %{
        tool_selection: %{"file.read" => "true", "file.write" => "true"},
        budgets: %{workflow: %{tool_calls: "5"}}
      }
    )
    |> render_submit()

    assert has_element?(view, "#policy-diff-tools-allowed_tools")
    {:ok, before} = Policies.current(scope)

    refute get_in(before.version.settings, ["tools", "allowed_tools"]) == [
             "file.read",
             "file.write"
           ]

    view |> element("#policy-activate") |> render_click()
    {:ok, current} = Policies.current(scope)
    assert current.version.settings["tools"]["allowed_tools"] == ["file.read", "file.write"]
    assert has_element?(view, "#policy-effective-tools", "file.read")
    assert {:ok, source} = current.version.configuration |> YAML.encode() |> YAML.decode()
    assert source["tools"]["allowed_tools"] == ["file.read", "file.write"]
    view |> element("#policy-new") |> render_click()

    view
    |> form("#policy-form",
      policy: %{tool_selection: %{"file.read" => "false", "file.write" => "false"}}
    )
    |> render_submit()

    view |> element("#policy-activate") |> render_click()
    {:ok, empty} = Policies.current(scope)
    assert empty.version.settings["tools"]["allowed_tools"] == []
  end

  test "unsupported imported identifiers are preserved and removable without changing old versions" do
    source =
      Configuration.default(2)
      |> Map.put("tools", %{"allowed_tools" => ["future.operation", "file.read"]})

    draft = Draft.from_source(source)

    params =
      draft
      |> Draft.source()
      |> Map.put("tool_selection", %{"future.operation" => "true", "file.read" => "true"})

    params = Map.put(params, "allowed_models", "qwen3.5:4b")
    {:ok, changeset, config} = Draft.validate(params)
    assert config.source["tools"]["allowed_tools"] == ["future.operation", "file.read"]

    assert PolicyHTML.unknown_tools(Phoenix.Component.to_form(changeset, as: :policy)) == [
             "future.operation"
           ]

    params = put_in(params, ["tool_selection", "future.operation"], "false")
    {:ok, _, removed} = Draft.validate(params)
    assert removed.source["tools"]["allowed_tools"] == ["file.read"]
    assert source["tools"]["allowed_tools"] == ["future.operation", "file.read"]
  end

  test "reader cannot access the editor or submit tool changes", %{conn: conn} do
    scope = organization_fixture()
    member = member_fixture(scope, :user, %{permissions: ["policies.read"]})

    {:ok, view, _} =
      conn
      |> log_in_user(member.user)
      |> live(~p"/organizations/#{scope.organization.id}/policies")

    refute has_element?(view, "#policy-new")
    refute has_element?(view, "#policy-tools")
  end

  test "platform uses the same tool section", %{conn: conn} do
    user = organizer_scope_fixture().user
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/platform/policies")
    view |> element("#policy-new") |> render_click()
    view |> element("#policy-upgrade") |> render_click()
    assert has_element?(view, "#policy-tools")

    view
    |> form("#policy-form", policy: %{tool_selection: %{"command.run" => "true"}})
    |> render_submit()

    view |> element("#policy-activate") |> render_click()
    assert has_element?(view, "#policy-effective-tools", "command.run")
  end
end
