defmodule AiControlWeb.OrganizationKnowledgeLiveTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.KnowledgeFixtures
  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.Policies.Configuration

  setup %{conn: conn} do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    activate_knowledge_policy(scope)
    %{scope: scope, agent: agent, conn: log_in_user(conn, scope.user)}
  end

  test "tabs, filters and checked resource detail", c do
    resource = document_fixture(c.scope, c.agent)
    path = "/organizations/#{c.scope.organization.id}/knowledge"
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "#knowledge-open-#{resource["id"]}")
    view |> form("#knowledge-filter-form", filters: %{query: "missing"}) |> render_submit()
    refute has_element?(view, "#knowledge-open-#{resource["id"]}")
    view |> element("#knowledge-memory-tab") |> render_click()
    assert has_element?(view, "#knowledge-memory-tab[aria-current=page]")
    {:ok, detail, _} = live(c.conn, path <> "/#{resource["id"]}")
    assert has_element?(detail, "#knowledge-checked-content")
    assert has_element?(detail, "#knowledge-edit")
    assert has_element?(detail, "#knowledge-delete")
  end

  test "explicit editor creates checked text and upload accepts UTF-8 Markdown", c do
    path = "/organizations/#{c.scope.organization.id}/knowledge"
    {:ok, view, _} = live(c.conn, path <> "/new")

    upload =
      file_input(view, "#knowledge-resource-form", :document, [
        %{
          last_modified: 0,
          name: "source.md",
          content: "support from upload",
          type: "text/markdown"
        }
      ])

    assert render_upload(upload, "source.md")

    view
    |> form("#knowledge-resource-form",
      resource: %{
        title: "Uploaded guide",
        owner_agent_id: c.agent.id,
        trust_level: "untrusted",
        content: "replaced"
      }
    )
    |> render_submit()

    assert_redirect(view, 2_000)
    assert {:ok, [stored]} = AiControl.Knowledge.search(c.scope, %{"query" => "upload"})
    assert stored["content"] == "support from upload"
    assert stored["origin"] == "upload"
  end

  test "readers have no management actions and ACL revocation clears detail", c do
    resource = document_fixture(c.scope, c.agent)

    member =
      member_fixture(c.scope, :user, %{permissions: ["knowledge.read"], agents: [c.agent.id]})

    conn = log_in_user(build_conn(), member.user)
    path = "/organizations/#{c.scope.organization.id}/knowledge"
    {:ok, view, _} = live(conn, path <> "/#{resource["id"]}")
    assert has_element?(view, "#knowledge-checked-content")
    refute has_element?(view, "#knowledge-edit")

    AiControl.Repo.update!(
      Ecto.Changeset.change(member.membership,
        grants: %{permissions: ["knowledge.read"], agents: []}
      )
    )

    send(view.pid, {:organization_access_changed, c.scope.organization.id})
    assert_redirect(view, path)
  end

  test "blocked text is absent while safe recovery action remains", c do
    resource =
      document_fixture(c.scope, c.agent, %{"content" => "support email synthetic@example.test"})

    guards =
      Map.new(
        Configuration.guards(5),
        &{&1, %{"enabled" => false, "required" => false}}
      )
      |> Map.put("pii", %{"enabled" => true, "required" => true})

    activate_knowledge_policy(c.scope, %{
      "guards" => guards,
      "rules" => %{"pii" => %{"action" => "block"}}
    })

    {:ok, view, _} =
      live(c.conn, "/organizations/#{c.scope.organization.id}/knowledge/#{resource["id"]}")

    assert has_element?(view, "#knowledge-error")
    refute has_element?(view, "#knowledge-checked-content")
    assert has_element?(view, "#knowledge-delete-blocked")
  end
end
