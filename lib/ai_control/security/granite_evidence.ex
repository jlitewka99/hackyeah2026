defmodule AiControl.Security.GraniteEvidence do
  @moduledoc "Closed, content-free historical evidence. No criterion text or reasoning."
  alias AiControl.Budgets.Usage
  alias AiControl.Guards.Granite.Model
  alias AiControl.Security.Validation

  @keys ~w(criterion_id criterion_hash task trigger status score block_on interpretation duration_us usage action_index)
  @triggers ~w(earlier_findings qwen_label prompt_guard_score high_risk_tool privileged_resource retrieved_sources not_selected not_applicable)

  def valid?(%{"model" => model, "digest" => digest, "checks" => checks} = value) do
    map_size(value) == 3 and model == Model.name() and Validation.checksum?(digest) and
      is_list(checks) and length(checks) in 1..136 and Enum.all?(checks, &check?/1)
  end

  def valid?(_), do: false

  def outcome_valid?(result) do
    checks = result.evidence["checks"]
    failed = Enum.any?(checks, &(&1["status"] == "error"))
    selected = Enum.any?(checks, &(&1["status"] != "skipped"))
    blocked = Enum.any?(checks, &(&1["interpretation"] == "block"))

    expected =
      cond do
        failed -> :error
        selected -> :ok
        true -> :skipped
      end

    result.status == expected and
      length(result.detections) == if(blocked and not failed, do: 1, else: 0) and
      Enum.all?(
        result.detections,
        &(&1.category == "granite_violation" and &1.rule_id == "granite.violation.v1")
      )
  end

  def matches_plan?(evidence, plan) do
    keys = ~w(criterion_id criterion_hash task trigger block_on action_index)

    valid?(evidence) and evidence["digest"] == Model.digest() and
      Enum.map(evidence["checks"], &Map.take(&1, keys)) ==
        Enum.map(plan, &Map.take(&1.evidence, keys))
  end

  def required?(results) do
    case Enum.find(results, &(&1.guard == "granite")) do
      %{status: :skipped, evidence: evidence} ->
        not (valid?(evidence) and Enum.all?(evidence["checks"], &(&1["status"] == "skipped")))

      _ ->
        true
    end
  end

  defp check?(check) when is_map(check) do
    Enum.sort(Map.keys(check)) == Enum.sort(@keys) and
      Validation.code?(check["criterion_id"]) and Validation.checksum?(check["criterion_hash"]) and
      check["task"] in ~w(suspicious_input tool_action groundedness) and
      check["trigger"] in @triggers and check["block_on"] in ~w(yes no) and
      Validation.duration?(check["duration_us"]) and
      action_index?(check["action_index"]) and
      outcome?(check)
  end

  defp check?(_), do: false

  defp action_index?(nil), do: true
  defp action_index?(index), do: Validation.duration?(index)

  defp outcome?(%{
         "status" => "ok",
         "score" => score,
         "block_on" => block,
         "interpretation" => interpretation,
         "usage" => usage
       }),
       do:
         score in ~w(yes no) and interpretation == if(score == block, do: "block", else: "allow") and
           match?({:ok, ^usage}, Usage.normalize(usage))

  defp outcome?(%{
         "status" => status,
         "score" => nil,
         "interpretation" => interpretation,
         "usage" => nil,
         "trigger" => trigger
       })
       when status in ~w(error skipped),
       do:
         (status == "error" and interpretation == "unavailable" and
            trigger not in ~w(not_selected not_applicable)) or
           (status == "skipped" and interpretation == "skipped" and
              trigger in ~w(not_selected not_applicable))

  defp outcome?(_), do: false
end
