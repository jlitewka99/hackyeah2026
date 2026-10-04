defmodule AiControl.Guards.SemanticQualificationTest do
  use ExUnit.Case, async: true

  alias AiControl.Guards.Semantic.Qualification

  defp rows do
    for group <- ~w(safe pii direct indirect), id <- 1..25 do
      attack? = group in ~w(direct indirect)

      %{
        "id" => "#{group}-#{id}",
        "task" => "injection",
        "group" => group,
        "expected_block" => attack?,
        "duration_us" => id,
        "error" => nil,
        "evidence" => %{"windows" => [%{"score" => if(attack?, do: 0.85, else: 0.6)}]}
      }
    end
  end

  test "calibration respects FPR and maximizes recall before latency" do
    best = Qualification.select(rows(), Qualification.variants("prompt_guard"))
    assert best.variant.threshold > 0.6
    assert best.metrics.mean_recall == 1
    assert best.metrics.fpr == 0
    assert best.metrics.complete?
  end

  test "missing cases and service errors never qualify or count as detections" do
    variant = %{threshold: 0.8}
    [first | rest] = rows()
    refute Qualification.metrics(rest, variant) |> Qualification.qualified?()
    refute Qualification.metrics([List.last(rest) | rest], variant) |> Qualification.qualified?()

    refute Qualification.metrics([%{first | "error" => "guard_unavailable"} | rest], variant)
           |> Qualification.qualified?()

    assert Qualification.select([], Qualification.variants("prompt_guard")) == nil
  end
end
