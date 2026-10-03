defmodule AiControl.Security.DomainTest do
  use AiControl.DataCase, async: true

  import AiControl.OrganizationsFixtures
  import AiControl.SecurityFixtures

  alias AiControl.Organizations
  alias AiControl.Policy.Snapshot

  alias AiControl.Security.{
    Decision,
    Detection,
    Fingerprint,
    GuardResult,
    SecurityAssessment,
    SecurityContext
  }

  test "scope sets identity and clients cannot override it or select another organization" do
    scope = organization_fixture()
    policy = policy_fixture()
    context = context_fixture(scope, policy)
    assert context.user_id == scope.user.id
    assert context.organization_id == scope.organization.id
    assert context.actor_type == :user

    assert {:error, :forbidden} =
             SecurityContext.from_scope(scope, %{organization_id: Ecto.UUID.generate()})

    assert {:error, :forbidden} =
             SecurityContext.from_scope(scope, %{user_id: Ecto.UUID.generate()})

    assert {:error, :forbidden} =
             SecurityContext.from_scope(scope, %{request_id: "client-secret"})

    reader = member_fixture(scope, :user)
    assert {:ok, _} = Organizations.remove_member(scope, reader.membership.id)

    assert {:error, :forbidden} =
             SecurityContext.from_scope(reader.scope, %{
               stage: :input,
               policy_version: policy.version,
               policy_checksum: policy.checksum
             })

    assert {:ok, _} = Organizations.set_status(scope, :suspended)

    assert {:error, :forbidden} =
             SecurityContext.from_scope(scope, %{
               stage: :input,
               policy_version: policy.version,
               policy_checksum: policy.checksum
             })
  end

  test "constructors reject content, unknown keys, malformed locations and unsafe signals" do
    assert {:error, :invalid_security_data} = Detection.new(%{text: "private-content"})

    assert {:error, :invalid_security_data} =
             Detection.new(%{
               guard: "pii",
               category: "pii",
               rule_id: "pii.email",
               confidence: 1,
               location: %{field_index: 0, start_byte: 9, end_byte: 3}
             })

    assert {:error, :invalid_security_data} =
             GuardResult.new(%{
               guard: "pii",
               status: :ok,
               signals: %{"risk_score" => "raw-response"}
             })

    assert {:error, :invalid_security_data} =
             GuardResult.new(%{guard: "pii", status: :ok, signals: %{"raw-response" => 1}})

    assert {:error, :invalid_security_data} =
             GuardResult.new(%{guard: "pii", status: :error, error_code: "secret in exception"})

    assert {:error, :invalid_security_data} =
             GuardResult.new(%{guard: "pii", status: :error, error_code: "github_pat_secret"})

    assert {:error, :invalid_security_data} = Decision.new(%{action: :allow, payload: "secret"})
    assert {:error, :invalid_security_data} = Snapshot.new(%{version: "v1", checksum: "invalid"})
    assert {:error, :invalid_security_data} = SecurityContext.new(%{prompt: "secret"})
  end

  test "assessments reject forged findings and duplicate guard results" do
    scope = organization_fixture()
    context = context_fixture(scope, policy_fixture())
    result = result_fixture()
    assert {:error, :invalid_security_data} = SecurityAssessment.new(context, [result, result])

    assert {:error, :invalid_security_data} =
             GuardResult.new(%{guard: "other", status: :ok, detections: [detection_fixture()]})

    assessment = assessment_fixture(context)
    refute SecurityAssessment.valid?(%{assessment | duration_us: 0})
    refute SecurityAssessment.valid?(%{assessment | detections: [detection_fixture()]})
  end

  test "fingerprints are stable and separated by tenant and stage without retaining content" do
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()
    content = "sensitive content ąć"
    assert {:ok, fingerprint} = Fingerprint.content(first, :input, content)
    assert {:ok, ^fingerprint} = Fingerprint.content(first, :input, content)
    assert {:ok, other_stage} = Fingerprint.content(first, :output, content)
    assert {:ok, other_tenant} = Fingerprint.content(second, :input, content)
    refute fingerprint.digest == other_stage.digest
    refute fingerprint.digest == other_tenant.digest
    refute inspect(fingerprint) =~ content
    assert fingerprint.key_id == "test-v1"
    scope = organization_fixture()
    policy = policy_fixture()
    context = context_fixture(scope, policy)
    refute SecurityContext.valid?(%{context | fingerprint: fingerprint})
    {:ok, wrong_stage} = Fingerprint.content(scope.organization.id, :output, content)
    refute SecurityContext.valid?(%{context | fingerprint: wrong_stage})
    assert {:error, :invalid_security_data} = Fingerprint.content("not-an-id", :input, content)
  end
end
