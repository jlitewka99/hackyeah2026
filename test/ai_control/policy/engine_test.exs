defmodule AiControl.Policy.EngineTest do
  use AiControl.DataCase, async: true

  import AiControl.OrganizationsFixtures
  import AiControl.SecurityFixtures

  alias AiControl.Policy.{Engine, Snapshot}
  alias AiControl.Security.SecurityAssessment

  setup do
    scope = organization_fixture()
    policy = policy_fixture()
    %{scope: scope, policy: policy, context: context_fixture(scope, policy)}
  end

  test "a passed required guard with no findings allows", %{context: context, policy: policy} do
    assessment = assessment_fixture(context)
    assert {:ok, decision} = Engine.evaluate(context, assessment, policy)
    assert decision.action == :allow
    assert decision.rule_ids == []
    assert decision.reason_codes == ["policy.allow"]
    assert {:ok, ^decision} = Engine.evaluate(context, assessment, policy)
  end

  test "redaction retains locations and rule evidence", %{context: context, policy: policy} do
    finding = detection_fixture()
    assessment = assessment_fixture(context, [result_fixture(%{detections: [finding]})])
    assert {:ok, decision} = Engine.evaluate(context, assessment, policy)
    assert decision.action == :redact
    assert decision.redactions == [finding.location]
    assert decision.rule_ids == ["pii.default"]
  end

  test "block wins over redact regardless of finding order", %{scope: scope} do
    policy =
      policy_fixture(%{
        rules: %{
          "pii" => %{id: "pii.default", action: :redact},
          "secret" => %{id: "secret.default", action: :block}
        }
      })

    context = context_fixture(scope, policy)

    findings = [
      detection_fixture(),
      detection_fixture(%{category: "secret", rule_id: "secret.token"})
    ]

    for ordered <- [findings, Enum.reverse(findings)] do
      assessment = assessment_fixture(context, [result_fixture(%{detections: ordered})])
      assert {:ok, decision} = Engine.evaluate(context, assessment, policy)
      assert decision.action == :block
      assert decision.redactions == []
      assert decision.rule_ids == ["pii.default", "secret.default"]
    end
  end

  test "threshold applies at its exact boundary", %{scope: scope} do
    policy =
      policy_fixture(%{rules: %{"pii" => %{id: "pii.default", action: :redact, threshold: 0.8}}})

    context = context_fixture(scope, policy)

    for {score, action} <- [{0.799, :allow}, {0.8, :redact}, {0.801, :redact}] do
      finding = detection_fixture(%{confidence: score})
      assessment = assessment_fixture(context, [result_fixture(%{detections: [finding]})])
      assert {:ok, decision} = Engine.evaluate(context, assessment, policy)
      assert decision.action == action
    end
  end

  test "missing, skipped or failed required guards block", %{context: context, policy: policy} do
    for results <- [
          [],
          [result_fixture(%{status: :skipped})],
          [result_fixture(%{status: :error, error_code: "provider_unavailable"})]
        ] do
      assessment = assessment_fixture(context, results)
      assert {:ok, decision} = Engine.evaluate(context, assessment, policy)
      assert decision.action == :block
      assert "required_guard_unavailable" in decision.reason_codes
    end
  end

  test "optional guard failures remain evidence without blocking", %{
    context: context,
    policy: policy
  } do
    results = [
      result_fixture(),
      result_fixture(%{guard: "semantic", status: :error, error_code: "provider_unavailable"})
    ]

    assessment = assessment_fixture(context, results)
    assert {:ok, decision} = Engine.evaluate(context, assessment, policy)
    assert decision.action == :allow
    assert assessment.failed_guards == ["semantic"]
  end

  test "unknown categories and non-redactable findings block", %{context: context, policy: policy} do
    for {finding, reason} <- [
          {detection_fixture(%{category: "unknown"}), "unmapped_detection"},
          {detection_fixture(%{location: nil}), "redaction_unavailable"}
        ] do
      assessment = assessment_fixture(context, [result_fixture(%{detections: [finding]})])
      assert {:ok, decision} = Engine.evaluate(context, assessment, policy)
      assert decision.action == :block
      assert reason in decision.reason_codes
    end
  end

  test "different snapshots, stages or forged assessments are rejected", %{
    context: context,
    policy: policy
  } do
    assessment = assessment_fixture(context)

    assert {:error, :invalid_security_data} =
             Engine.evaluate(context, assessment, %{policy | version: "v2"})

    assert {:error, :invalid_security_data} =
             Engine.evaluate(context, %{assessment | stage: :output}, policy)

    assert {:error, :invalid_security_data} =
             Engine.evaluate(context, %SecurityAssessment{}, policy)

    assert {:error, :invalid_security_data} =
             Engine.evaluate(context, assessment, %{
               policy
               | rules: %{"pii" => %{id: "p", action: :unknown}}
             })
  end

  test "checksums are computed from rules and stale checksums cannot authorize changed actions",
       %{scope: scope} do
    first = policy_fixture()
    second = policy_fixture(%{rules: %{"pii" => %{id: "pii.default", action: :block}}})
    refute first.checksum == second.checksum
    context = context_fixture(scope, first)
    assessment = assessment_fixture(context)
    forged = %{first | rules: second.rules}
    assert {:error, :invalid_security_data} = Engine.evaluate(context, assessment, forged)

    assert {:error, :invalid_security_data} =
             Snapshot.new(%{
               version: first.version,
               checksum: first.checksum,
               rules: second.rules,
               required_guards: ["pii"]
             })
  end
end
