defmodule AiControlWeb.PromptGuardPolicyLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.OrganizationsFixtures
  import AiControl.SecurityFixtures
  import Phoenix.LiveViewTest

  alias AiControl.{Audit, Gateway, Policies, Security}
  alias AiControl.Guards.Semantic.PromptGuard
  alias AiControl.Policies.Configuration

  test "provider draft, threshold, review and activation stay separate", %{conn: conn} do
    scope = organization_fixture()
    conn = log_in_user(conn, scope.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    view |> element("#policy-new") |> render_click()
    view |> element("#policy-upgrade") |> render_click()
    view |> element("#policy-guards > summary") |> render_click()
    assert has_element?(view, "#policy-semantic-provider option[value=qwen][selected]")

    view
    |> form("#policy-form", policy: %{guards: %{semantic: %{provider: "prompt_guard"}}})
    |> render_change()

    assert has_element?(view, "#policy-score-help")
    assert has_element?(view, "#policy-rule-prompt_injection-threshold")
    refute has_element?(view, "#policy-semantic-severities")
    assert {:ok, old} = Policies.current(scope)
    assert old.version.settings["schema_version"] == 1

    view
    |> form("#policy-form", policy: %{rules: %{prompt_injection: %{threshold: "1.2"}}})
    |> render_change()

    assert has_element?(view, "#policy-rule-prompt_injection-threshold[aria-invalid=true]")

    view
    |> form("#policy-form", policy: %{rules: %{prompt_injection: %{threshold: "0.85"}}})
    |> render_submit()

    assert has_element?(view, "#policy-diff-guards-semantic-provider")
    assert has_element?(view, "#policy-provider-change-notice", "maximum malicious score")
    assert has_element?(view, "#policy-activate")
    assert {:ok, current} = Policies.current(scope)
    assert current.version.id == old.version.id
    view |> element("#policy-activate") |> render_click()
    assert has_element?(view, "#policy-active-provider", "Llama Prompt Guard")
    assert {:ok, active} = Policies.current(scope)
    assert active.snapshot.settings["rules"]["prompt_injection"]["threshold"] == 0.85
    {:ok, overview, _} = live(conn, ~p"/organizations/#{scope.organization.id}")
    assert has_element?(overview, "#active-provider-semantic", "Llama Prompt Guard")

    {:ok, policy_view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/policies")
    policy_view |> element("#policy-new") |> render_click()
    policy_view |> element("#policy-guards > summary") |> render_click()

    policy_view
    |> form("#policy-form", policy: %{guards: %{semantic: %{provider: "qwen"}}})
    |> render_change()

    policy_view |> form("#policy-form") |> render_submit()

    assert has_element?(
             policy_view,
             "#policy-diff-guards-semantic-provider",
             "Qwen3Guard Gen 0.6B"
           )

    assert has_element?(
             policy_view,
             "#policy-diff-rules-prompt_injection-threshold",
             "Severity labels"
           )

    assert has_element?(policy_view, "#policy-provider-change-notice", "Label mapping replaces")
  end

  test "event readers see the recorded score and historical threshold", %{conn: conn} do
    scope = organization_fixture()

    source =
      Configuration.default(4)
      |> Map.put("guards", %{"semantic" => %{"provider" => "prompt_guard"}})
      |> Map.put("rules", %{"prompt_injection" => %{"threshold" => 0.85}})

    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    {:ok, active} = Policies.current(scope)
    {:ok, context} = Gateway.context(scope, active.snapshot, Ecto.UUID.generate(), :input)

    evidence = %{
      "model_set" => PromptGuard.model_set(),
      "revision" => PromptGuard.revision(),
      "task" => "injection",
      "signal_kind" => "classifier_score",
      "windows" => [%{"field_index" => 0, "start_byte" => 0, "end_byte" => 5, "score" => 0.9}]
    }

    result = result_fixture(%{guard: "semantic", evidence: evidence})

    {:ok, _} =
      Security.evaluate_and_audit(context, assessment_fixture(context, [result]), active.snapshot)

    {:ok, events} = Audit.list_events(scope)
    event = Enum.find(events, &(&1.kind == :decision))
    reader = member_fixture(scope, :user, %{permissions: ["events.read"]})
    conn = log_in_user(conn, reader.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/events/#{event.id}")
    assert has_element?(view, "#event-model-signal", "0.9")
    assert has_element?(view, "#event-model-signal", "0.85")
    assert has_element?(view, "#event-evidence")
    assert get(conn, ~p"/organizations/#{scope.organization.id}/policies").status == 403
  end
end
