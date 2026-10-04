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

  # Imported literals can match every byte. Stop with an unavailable guard instead
  # of truncating redaction coverage or allocating an unbounded match collection.
  def scan_bounded(fields, guard, category, detectors, limit \\ 1024) do
    started = System.monotonic_time()

    result =
      for(
        {text, index} <- Enum.with_index(fields),
        detector <- detectors,
        do: {text, index, detector}
      )
      |> Enum.reduce_while({:ok, [], limit}, fn {text, index, detector},
                                                {:ok, findings, remaining} ->
        case scan_matches(text, index, detector, guard, category, 0, findings, remaining) do
          {:ok, _, _} = value -> {:cont, value}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, findings, _} ->
        detections = findings |> Enum.reverse() |> Enum.uniq()

        GuardResult.new(%{
          guard: guard,
          status: :ok,
          detections: detections,
          signals: %{"#{category}_count" => length(detections)},
          duration_us:
            System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
        })

      error ->
        error
    end
  end

  defp scan_matches(
         text,
         index,
         {id, pattern, validate} = detector,
         guard,
         category,
         offset,
         findings,
         remaining
       ) do
    case Regex.run(pattern, text, return: :index, offset: offset) do
      nil ->
        {:ok, findings, remaining}

      _ when remaining == 0 ->
        {:error, :guard_unavailable}

      match ->
        {first, size} = hd(match)
        found = candidate(match, text, index, guard, category, id, validate)

        scan_matches(
          text,
          index,
          detector,
          guard,
          category,
          first + max(size, 1),
          found ++ findings,
          remaining - 1
        )
    end
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
