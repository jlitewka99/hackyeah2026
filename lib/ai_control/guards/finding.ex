defmodule AiControl.Guards.Finding do
  @moduledoc false
  alias AiControl.Security.{Detection, GuardResult}

  def scan(fields, guard, category, detectors) do
    started = System.monotonic_time()

    detections =
      fields
      |> Enum.with_index()
      |> Enum.flat_map(&scan_field(&1, detectors, guard, category))
      |> Enum.uniq()

    GuardResult.new(%{
      guard: guard,
      status: :ok,
      detections: detections,
      signals: %{"#{category}_count" => length(detections)},
      duration_us:
        System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
    })
  end

  defp scan_field({text, index}, detectors, guard, category) do
    Enum.flat_map(detectors, fn {id, pattern, validate} ->
      Regex.scan(pattern, text, return: :index)
      |> Enum.flat_map(&candidate(&1, text, index, guard, category, id, validate))
    end)
  end

  defp candidate(match, text, index, guard, category, id, validate) do
    {first, size} = List.last(match)
    value = binary_part(text, first, size)

    if validate.(value, text, first),
      do: [new(guard, category, id, index, first, first + size)],
      else: []
  end

  def new(guard, category, id, index, first, last, score \\ 1.0) do
    {:ok, finding} =
      Detection.new(%{
        guard: guard,
        category: category,
        rule_id: id,
        confidence: score,
        location: %{field_index: index, start_byte: first, end_byte: last}
      })

    finding
  end
end
