defmodule AiControl.AuditTest do
  use AiControl.DataCase, async: true

  import AiControl.OrganizationsFixtures
  import AiControl.SecurityFixtures

  alias AiControl.{Audit, Organizations, Security}
  alias AiControl.Audit.Event
  alias AiControl.Policy.Engine
  alias AiControl.Security.{Fingerprint, SecurityAssessment}

  test "persisted decisions explain all outcomes without checked content" do
    scope = organization_fixture()
    secret = "private prompt with response and token ąć"
    {:ok, fingerprint} = Fingerprint.content(scope.organization.id, :input, secret)
    policy = policy_fixture()

    for {results, action} <- [
          {[result_fixture()], :allow},
          {[result_fixture(%{detections: [detection_fixture()]})], :redact},
          {[], :block}
        ] do
      context = context_fixture(scope, policy, %{fingerprint: fingerprint})
      assessment = assessment_fixture(context, results)
      assert {:ok, decision} = Security.evaluate_and_audit(context, assessment, policy)
      assert decision.action == action
      assert {:ok, event} = Audit.get_event(scope, assessment.id)
      assert event.action == action
      assert event.policy_version == policy.version
      assert event.policy_checksum == policy.checksum
      assert event.rule_ids == decision.rule_ids
      assert event.reason_codes == decision.reason_codes
      assert event.fingerprint_digest == fingerprint.digest
      assert event.fingerprint_key_id == fingerprint.key_id
      assert event.user_id == scope.user.id
      refute inspect(event) =~ secret
      refute Map.has_key?(event.data, "prompt")
      refute Map.has_key?(event.data, "response")
    end
  end

  test "decision retries are idempotent and conflicting evidence is rejected" do
    scope = organization_fixture()
    policy = policy_fixture()
    context = context_fixture(scope, policy)
    assessment = assessment_fixture(context)
    {:ok, decision} = Engine.evaluate(context, assessment, policy)
    assert {:ok, first} = Audit.record_decision(context, assessment, decision)
    assert {:ok, ^first} = Audit.record_decision(context, assessment, decision)
    assert Repo.aggregate(from(e in Event, where: e.id == ^assessment.id), :count) == 1

    assert {:error, :audit_conflict} =
             Audit.record_decision(context, assessment, %{
               decision
               | action: :block,
                 reason_codes: ["policy.block"]
             })

    assert Repo.get!(Event, assessment.id).action == :allow
  end

  test "tenant isolation and events.read are checked on every lookup" do
    first = organization_fixture()
    second = organization_fixture()
    reader = member_fixture(first, :user, %{permissions: ["events.read"]})
    denied = member_fixture(first)
    policy = policy_fixture()
    context = context_fixture(second, policy)
    assessment = assessment_fixture(context)
    assert {:ok, _} = Security.evaluate_and_audit(context, assessment, policy)
    assert {:error, :not_found} = Audit.get_event(reader.scope, assessment.id)
    assert {:error, :forbidden} = Audit.list_events(denied.scope)
    assert {:ok, events} = Audit.list_events(reader.scope)
    assert Enum.all?(events, &(&1.organization_id == first.organization.id))

    assert {:ok, _} =
             Organizations.update_member(first, reader.membership.id, %{
               grants: %{permissions: []}
             })

    assert {:error, :forbidden} = Audit.list_events(reader.scope)
    assert {:error, :forbidden} = Audit.get_event(reader.scope, hd(events).id)
  end

  test "removed and suspended members lose audit access while organizer can investigate" do
    scope = organization_fixture()
    reader = member_fixture(scope, :user, %{permissions: ["events.read"]})
    assert {:ok, _} = Organizations.set_status(scope, :suspended)
    assert {:error, :forbidden} = Audit.list_events(reader.scope)
    assert {:ok, _} = Audit.list_events(scope)
    assert {:ok, _} = Organizations.set_status(scope, :active)
    assert {:ok, _} = Organizations.remove_member(scope, reader.membership.id)
    assert {:error, :forbidden} = Audit.list_events(reader.scope)
  end

  test "unknown fields, raw exceptions and forged assessments never reach persistence" do
    scope = organization_fixture()

    assert {:error, :invalid_audit_data} =
             Audit.record_admin(scope, "organization.created", %{
               target_id: scope.organization.id,
               prompt: "secret"
             })

    assert {:error, :invalid_audit_data} =
             Audit.record_admin(scope, "organization.created", %{
               target_id: scope.organization.id,
               after: %{status: "active", response: "secret"}
             })

    assert {:error, :invalid_audit_data} =
             Audit.record_admin(scope, "organization.created", %{
               target_id: scope.organization.id,
               after: %RuntimeError{message: "secret"}
             })

    assert {:error, :invalid_audit_data} =
             Audit.record_admin(scope, "unknown.event", %{target_id: scope.organization.id})

    policy = policy_fixture()
    context = context_fixture(scope, policy)
    assessment = assessment_fixture(context)
    {:ok, decision} = Engine.evaluate(context, assessment, policy)

    assert {:error, :invalid_audit_data} =
             Audit.record_decision(context, %SecurityAssessment{}, decision)

    assert {:error, :invalid_audit_data} =
             Audit.record_decision(context, assessment, %{
               decision
               | request_id: Ecto.UUID.generate()
             })

    assert Repo.aggregate(Event, :count) == 1
  end

  test "optional agent identities require UUIDs but no step 3 schemas" do
    scope = organization_fixture()
    policy = policy_fixture()
    context = context_fixture(scope, policy)

    context = %{
      context
      | actor_type: :agent,
        user_id: nil,
        agent_id: Ecto.UUID.generate(),
        api_key_id: Ecto.UUID.generate()
    }

    assessment = assessment_fixture(context)
    assert {:ok, _} = Security.evaluate_and_audit(context, assessment, policy)
    assert {:ok, event} = Audit.get_event(scope, assessment.id)
    assert event.agent_id == context.agent_id
    assert event.api_key_id == context.api_key_id
    assert event.actor_type == :agent
  end

  test "list pagination is bounded and malformed IDs do not expose records" do
    scope = organization_fixture()
    assert {:ok, [_]} = Audit.list_events(scope, limit: 1)
    assert {:ok, []} = Audit.list_events(scope, offset: 1)
    assert {:error, :invalid_audit_data} = Audit.list_events(scope, limit: 201)
    assert {:error, :invalid_audit_data} = Audit.list_events(scope, payload: "secret")
    assert {:error, :not_found} = Audit.get_event(scope, "secret-id")
  end

  test "output evidence preserves direction and its own fingerprint" do
    scope = organization_fixture()
    policy = policy_fixture()

    {:ok, fingerprint} =
      Fingerprint.content(scope.organization.id, :output, "private-model-output")

    context = context_fixture(scope, policy, %{stage: :output, fingerprint: fingerprint})

    assessment =
      assessment_fixture(context, [result_fixture(%{detections: [detection_fixture()]})])

    assert {:ok, decision} = Security.evaluate_and_audit(context, assessment, policy)
    assert decision.action == :redact
    assert {:ok, event} = Audit.get_event(scope, assessment.id)
    assert event.stage == :output
    assert event.fingerprint_digest == fingerprint.digest
    assert event.data["detections"] |> hd() |> Map.fetch!("confidence") == 1
    refute inspect(event) =~ "private-model-output"
  end

  test "audit alone explains why a detected value was allowed below threshold" do
    scope = organization_fixture()

    policy =
      policy_fixture(%{rules: %{"pii" => %{id: "pii.threshold", action: :block, threshold: 0.8}}})

    context = context_fixture(scope, policy)
    finding = detection_fixture(%{confidence: 0.7})
    assessment = assessment_fixture(context, [result_fixture(%{detections: [finding]})])
    assert {:ok, %{action: :allow}} = Security.evaluate_and_audit(context, assessment, policy)
    assert {:ok, event} = Audit.get_event(scope, assessment.id)
    rule = event.data["policy_evidence"]["rules"]["pii"]
    observed = hd(event.data["detections"])
    assert rule["action"] == "block"
    assert observed["confidence"] < rule["threshold"]
    assert event.rule_ids == []
    assert event.data["policy_evidence"]["required_guards"] == ["pii"]
  end
end
