defmodule AiControl.SecurityFixtures do
  @moduledoc "Content-free contexts and explicit policy snapshots for security tests."
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.{Detection, GuardResult, SecurityAssessment, SecurityContext}

  def policy_fixture(attrs \\ %{}) do
    {:ok, policy} =
      Snapshot.new(
        Map.merge(
          %{
            version: "test-v1",
            required_guards: ["pii"],
            rules: %{"pii" => %{id: "pii.default", action: :redact}}
          },
          attrs
        )
      )

    policy
  end

  def context_fixture(scope, policy, attrs \\ %{}) do
    {:ok, context} =
      SecurityContext.from_scope(
        scope,
        Map.merge(
          %{stage: :input, policy_version: policy.version, policy_checksum: policy.checksum},
          attrs
        )
      )

    context
  end

  def detection_fixture(attrs \\ %{}) do
    {:ok, detection} =
      Detection.new(
        Map.merge(
          %{
            guard: "pii",
            category: "pii",
            rule_id: "pii.email",
            confidence: 1,
            location: %{field_index: 0, start_byte: 3, end_byte: 10}
          },
          attrs
        )
      )

    detection
  end

  def result_fixture(attrs \\ %{}) do
    {:ok, result} =
      GuardResult.new(Map.merge(%{guard: "pii", status: :ok, duration_us: 10}, attrs))

    result
  end

  def assessment_fixture(context, results \\ [result_fixture()]) do
    {:ok, assessment} = SecurityAssessment.new(context, results)
    assessment
  end
end
