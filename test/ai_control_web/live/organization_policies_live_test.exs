defmodule AiControlWeb.OrganizationPoliciesLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.{Organizations, Policies}
  alias AiControl.Policies.{Configuration, YAML}
  alias AiControlWeb.PolicyHTML

  setup %{conn: conn} do
    scope = organization_fixture()
    %{scope: scope, conn: log_in_user(conn, scope.user)}
  end

  test "budget form preserves unlimited, zero and hourly values through activation", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    view |> element("#policy-new") |> render_click()
    view |> element("#policy-budgets > summary") |> render_click()
    assert has_element?(view, "#policy-budget-help", "UTC hour")
    assert has_element?(view, "#policy-budget-help", "does not reset")

    view
    |> form("#policy-form",
      policy: %{
        budgets: %{
          organization: %{requests_per_hour: "0", tokens_per_hour: "5000"},
          agent: %{requests_per_hour: "", tokens_per_hour: "2000"},
          workflow: %{tool_calls: "3"}
        }
      }
    )
    |> render_submit()

    assert has_element?(view, "#policy-activate")
    view |> element("#policy-activate") |> render_click()
    {:ok, current} = Policies.current(scope)

    assert current.snapshot.settings["budgets"]["organization"] == %{
             "requests_per_hour" => 0,
             "tokens_per_hour" => 5000
           }

    assert current.snapshot.settings["budgets"]["agent"] == %{
             "requests_per_hour" => nil,
             "tokens_per_hour" => 2000
           }

    assert current.snapshot.settings["budgets"]["workflow"]["tool_calls"] == 3
  end

  test "v5 upgrade keeps the active v1 policy until deliberate activation", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    assert has_element?(view, "#policy-schema", "v1")
    view |> element("#policy-new") |> render_click()
    view |> element("#policy-upgrade") |> render_click()
    assert has_element?(view, "#policy-draft-schema", "v5")
    assert has_element?(view, "#policy-detector-sets")
    assert has_element?(view, "#policy-set-label-ner", "Named entity weights")
    assert has_element?(view, "#policy-ner-model-set option[value='pl-nkjp.v2'][selected]")
    view |> element("#policy-guards > summary") |> render_click()
    assert has_element?(view, "#policy-ner-entities option[value='person'][selected]")
    assert has_element?(view, "#policy-ner-entities option[value='address'][selected]")
    refute has_element?(view, "#policy-ner-entities option[value='organization'][selected]")

    view
    |> form("#policy-form",
      policy: %{guards: %{ner: %{entities: ["person", "address", "organization"]}}}
    )
    |> render_submit()

    assert has_element?(view, "#policy-diff-schema_version")
    assert {:ok, current} = Policies.current(scope)
    assert current.version.settings["schema_version"] == 1
    view |> element("#policy-activate") |> render_click()
    assert has_element?(view, "#policy-schema", "v5")
    assert {:ok, active} = Policies.current(scope)

    assert active.version.settings["guards"]["ner"]["entities"] == [
             "person",
             "address",
             "organization"
           ]
  end

  test "v2 YAML preserves optional entities and the tool allowlist through forms and export", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")

    source =
      Configuration.default(2)
      |> Map.put("guards", %{"ner" => %{"entities" => ["address", "place"], "required" => false}})
      |> Map.put("tools", %{"allowed_tools" => ["read_document"]})

    view |> form("#policy-import-form", yaml: %{text: YAML.encode(source)}) |> render_submit()
    assert has_element?(view, "##{PolicyHTML.tool_id("read_document")}[checked]")
    view |> form("#policy-form") |> render_submit()
    assert {:ok, [version]} = Policies.list_versions(scope)
    assert {:ok, expected} = Configuration.validate(source)
    assert version.settings == expected.settings
    assert version.configuration["tools"] == source["tools"]

    exported =
      get(
        conn,
        ~p"/organizations/#{scope.organization.id}/policies/versions/#{version.id}/export"
      )

    assert {:ok, yaml} = exported |> response(200) |> YAML.decode()
    assert {:ok, %{settings: settings}} = Configuration.validate(yaml)
    assert settings == expected.settings
  end

  test "saving, reviewing, activation and returning to global are separate actions", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    assert has_element?(view, "#policy-source", "Inherited")
    assert has_element?(view, "#policy-history-empty")
    view |> element("#policy-new") |> render_click()
    assert has_element?(view, "#policy-form")

    view
    |> form("#policy-form",
      policy: %{profile: "strict", allowed_models: "qwen3.5:4b", allowed_agents: ["*"]}
    )
    |> render_submit()

    assert has_element?(view, "#policy-preview")
    assert has_element?(view, "#policy-diff")
    assert {:ok, current} = Policies.current(scope)
    assert current.inherited?
    view |> element("#policy-activate") |> render_click()
    refute has_element?(view, "#policy-preview")
    assert has_element?(view, "#policy-source", "Organization policy")
    assert {:ok, current} = Policies.current(scope)
    assert current.version.settings["profile"] == "strict"
    view |> element("#policy-inherit") |> render_click()
    assert has_element?(view, "#policy-source", "Inherited")
    assert {:ok, versions} = Policies.list_versions(scope)
    assert length(versions) == 1
  end

  test "invalid form and YAML retain inputs without changing the active policy", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    view |> element("#policy-new") |> render_click()

    view
    |> form("#policy-form",
      policy: %{
        profile: "balanced",
        allowed_models: "qwen3.5:4b",
        allowed_agents: ["*"],
        rules: %{pii: %{threshold: "1.1"}}
      }
    )
    |> render_submit()

    assert has_element?(view, "#policy-errors")
    assert has_element?(view, "#policy-rule-pii-threshold[value='1.1']")
    view |> form("#policy-import-form", yaml: %{text: "unknown: DO-NOT-LOG"}) |> render_submit()
    assert has_element?(view, "#policy-errors")
    assert {:ok, current} = Policies.current(scope)
    assert current.inherited?
    assert {:ok, []} = Policies.list_versions(scope)
  end

  test "YAML import opens an editor and file import uses the same validation", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    source = Map.put(Configuration.default(), "profile", "relaxed")
    yaml = YAML.encode(source)
    view |> form("#policy-import-form", yaml: %{text: yaml}) |> render_submit()
    assert has_element?(view, "#policy-form")
    assert has_element?(view, "#policy_profile option[value='relaxed'][selected]")
    assert {:ok, []} = Policies.list_versions(scope)

    upload =
      file_input(view, "#policy-import-form", :policy_yaml, [
        %{name: "policy.yaml", content: yaml, type: "application/yaml"}
      ])

    _ = render_upload(upload, "policy.yaml")
    assert has_element?(view, "#policy-import-form button[id^=cancel-upload-]")
    view |> form("#policy-import-form", yaml: %{text: ""}) |> render_submit()
    assert has_element?(view, "#policy-form")
  end

  test "read-only access hides write controls and removal closes the page", %{
    conn: conn,
    scope: scope
  } do
    reader = member_fixture(scope, :user, %{permissions: ["policies.read"]})
    conn = log_in_user(conn, reader.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    assert has_element?(view, "#effective-policy")
    refute has_element?(view, "#policy-new")
    refute has_element?(view, "#policy-import-form")

    assert {:ok, _} =
             Organizations.update_member(scope, reader.membership.id, %{
               grants: %{permissions: []}
             })

    assert_redirect(view, ~p"/organizations/#{scope.organization.id}")
  end

  test "PubSub preserves unsaved edits and stale activation requires review", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    view |> element("#policy-new") |> render_click()
    view |> form("#policy-form", policy: %{allowed_models: "unsaved-model"}) |> render_change()

    {:ok, version} =
      Policies.create_version(scope, Map.put(Configuration.default(), "profile", "strict"))

    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    assert has_element?(view, "#policy-updated")
    assert has_element?(view, "#policy_allowed_models", "unsaved-model")
  end

  test "tenant isolation applies to exports, including inherited global versions", %{
    conn: conn,
    scope: scope
  } do
    {:ok, current} = Policies.current(scope)

    exported =
      get(
        conn,
        ~p"/organizations/#{scope.organization.id}/policies/versions/#{current.version.id}/export"
      )

    assert response(exported, 200) |> YAML.decode() |> elem(0) == :ok
    other = organization_fixture()
    {:ok, version} = Policies.create_version(other, Configuration.default())

    denied =
      get(
        conn,
        ~p"/organizations/#{scope.organization.id}/policies/versions/#{version.id}/export"
      )

    assert response(denied, 404)
  end

  test "open form sections survive validation and rollback first opens a comparison", %{
    conn: conn,
    scope: scope
  } do
    {:ok, initial} = Policies.current(scope)
    {:ok, old} = Policies.create_version(scope, Configuration.default())
    {:ok, _} = Policies.activate(scope, old.id, initial.set.revision)
    {:ok, current} = Policies.current(scope)

    {:ok, new} =
      Policies.create_version(scope, Map.put(Configuration.default(), "profile", "strict"))

    {:ok, _} = Policies.activate(scope, new.id, current.set.revision)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    view |> element("#policy-new") |> render_click()
    view |> element("#policy-budgets > summary") |> render_click()
    view |> form("#policy-form", policy: %{profile: "relaxed"}) |> render_change()
    assert has_element?(view, "#policy-budgets[open]")
    view |> element("#policy-rollback-#{old.id}") |> render_click()
    assert has_element?(view, "#policy-diff")
    assert has_element?(view, "#policy-activate[phx-click='rollback']")
    assert {:ok, unchanged} = Policies.current(scope)
    assert unchanged.version.id == new.id
    view |> element("#policy-activate") |> render_click()
    assert {:ok, restored} = Policies.current(scope)
    assert restored.version.id == old.id
  end

  test "an external activation refreshes comparison and requires deliberate review before retry",
       %{conn: conn, scope: scope} do
    {:ok, draft} =
      Policies.create_version(scope, Map.put(Configuration.default(), "profile", "relaxed"))

    {:ok, strict} =
      Policies.create_version(scope, Map.put(Configuration.default(), "profile", "strict"))

    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    view |> element("#policy-view-#{draft.id}") |> render_click()
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, strict.id, current.set.revision)
    assert has_element?(view, "#policy-diff-rules-pii-action", "Current: \"block\"")
    assert has_element?(view, "#policy-activate[disabled]")
    render_click(view, "activate", %{"id" => draft.id})
    assert {:ok, unchanged} = Policies.current(scope)
    assert unchanged.version.id == strict.id
    assert has_element?(view, "#policy-refresh-review")
    view |> element("#policy-refresh-review") |> render_click()
    refute has_element?(view, "#policy-activate[disabled]")
    view |> element("#policy-activate") |> render_click()
    assert {:ok, activated} = Policies.current(scope)
    assert activated.version.id == draft.id
  end

  test "refreshing an outdated historical comparison preserves rollback mode", %{
    conn: conn,
    scope: scope
  } do
    {:ok, current} = Policies.current(scope)
    {:ok, old} = Policies.create_version(scope, Configuration.default())
    {:ok, _} = Policies.activate(scope, old.id, current.set.revision)
    {:ok, current} = Policies.current(scope)

    {:ok, strict} =
      Policies.create_version(scope, Map.put(Configuration.default(), "profile", "strict"))

    {:ok, _} = Policies.activate(scope, strict.id, current.set.revision)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    view |> element("#policy-rollback-#{old.id}") |> render_click()
    {:ok, current} = Policies.current(scope)

    {:ok, relaxed} =
      Policies.create_version(scope, Map.put(Configuration.default(), "profile", "relaxed"))

    {:ok, _} = Policies.activate(scope, relaxed.id, current.set.revision)
    assert has_element?(view, "#policy-diff-profile", "Current: \"relaxed\"")
    assert has_element?(view, "#policy-activate[phx-click='rollback'][disabled]")
    view |> element("#policy-refresh-review") |> render_click()
    assert has_element?(view, "#policy-activate[phx-click='rollback']")
    refute has_element?(view, "#policy-activate[disabled]")
  end

  test "YAML errors stay beside their input and preserve the editor", %{conn: conn, scope: scope} do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    view |> element("#policy-new") |> render_click()
    view |> form("#policy-form", policy: %{allowed_models: "unsaved-model"}) |> render_change()

    view
    |> form("#policy-import-form", yaml: %{text: "profile: strict\nprofile: relaxed"})
    |> render_submit()

    assert has_element?(view, "#policy-import-errors", "keys must be unique")

    assert has_element?(
             view,
             "#yaml_text[aria-invalid='true'][aria-describedby='policy-import-errors']"
           )

    assert has_element?(view, "#policy_allowed_models", "unsaved-model")
    assert {:ok, []} = Policies.list_versions(scope)

    view
    |> form("#policy-import-form", yaml: %{text: YAML.encode(Configuration.default())})
    |> render_submit()

    refute has_element?(view, "#policy-import-errors")
  end
end
