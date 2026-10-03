defmodule AiControl.Guards.Pii do
  @moduledoc "Bounded candidates with checksums; offsets always refer to the supplied UTF-8 text."
  @behaviour AiControl.Gateway.Guard

  alias AiControl.Guards.{Finding, Registry}

  @impl true
  def assess(fields, _context, _snapshot, _config),
    do: Finding.scan(fields, "pii", "pii", detectors())

  @impl true
  def ready?(_), do: Registry.valid?()

  defp detectors do
    [
      {"pii.pesel.v1", ~r/(?<![\p{L}\p{N}_])(?:[0-9]{11}|[0-9]{6}[- ][0-9]{5})(?![\p{L}\p{N}_])/u,
       fn value, _, _ -> pesel?(digits(value)) end},
      {"pii.nip.v1",
       ~r/(?<![\p{L}\p{N}_])(?:[0-9]{10}|[0-9]{3}-[0-9]{3}-[0-9]{2}-[0-9]{2}|[0-9]{3}-[0-9]{2}-[0-9]{2}-[0-9]{3})(?![\p{L}\p{N}_])/u,
       fn value, _, _ -> checksum?(digits(value), [6, 5, 7, 2, 3, 4, 5, 6, 7], :reject_ten) end},
      {"pii.regon.v1", ~r/(?<![\p{L}\p{N}_])(?:[0-9]{14}|[0-9]{9})(?![\p{L}\p{N}_])/u,
       fn value, _, _ -> regon?(digits(value)) end},
      {"pii.nrb.v1",
       ~r/(?<![\p{L}\p{N}_])(?:[0-9]{26}|[0-9]{2}(?:[ \x{00a0}][0-9]{4}){6})(?![\p{L}\p{N}_])/u,
       fn value, _, _ -> iban?("PL" <> compact(value)) end},
      {"pii.iban.v1",
       ~r/(?<![\p{L}\p{N}_])(?:[A-Za-z]{2}[0-9]{2}[A-Za-z0-9]{11,30}|[A-Za-z]{2}[0-9]{2}(?:[ \x{00a0}][A-Za-z0-9]{4}){2,7}(?:[ \x{00a0}][A-Za-z0-9]{1,4})?)(?![\p{L}\p{N}_])/u,
       fn value, _, _ -> iban?(compact(value)) end},
      {"pii.card.v1",
       ~r/(?<![\p{L}\p{N}_])(?:[0-9]{13,19}|[0-9]{4}(?:[- ][0-9]{4}){2,3}(?:[- ][0-9]{1,3})?|[0-9]{4}[- ][0-9]{6}[- ][0-9]{5})(?![\p{L}\p{N}_])/u,
       fn value, text, first ->
         numbers = digits(value)

         length(numbers) in 13..19 && varied?(numbers) && luhn?(numbers) &&
           card_context?(text, first)
       end},
      {"pii.email.v1",
       ~r/(?<![\p{L}\p{N}_.+%-])[\p{L}\p{N}_.+%-]+@[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?(?:\.[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?)+/u,
       fn value, _, _ -> byte_size(value) <= 254 end}
    ]
  end

  defp compact(value), do: value |> String.replace(~r/[- \x{00a0}]/u, "") |> String.upcase()
  defp digits(value), do: compact(value) |> :binary.bin_to_list() |> Enum.map(&(&1 - ?0))
  defp varied?(numbers), do: length(Enum.uniq(numbers)) > 1

  defp pesel?([y1, y2, month1, month2, day1, day2 | _] = numbers) do
    month = month1 * 10 + month2

    century =
      Enum.find([{80, 1800}, {0, 1900}, {20, 2000}, {40, 2100}, {60, 2200}], fn {offset, _} ->
        (month - offset) in 1..12
      end)

    case century do
      {offset, base} ->
        match?({:ok, _}, Date.new(base + y1 * 10 + y2, month - offset, day1 * 10 + day2)) &&
          rem(weighted(numbers, [1, 3, 7, 9, 1, 3, 7, 9, 1, 3, 1]), 10) == 0

      _ ->
        false
    end
  end

  defp regon?(numbers) when length(numbers) == 9,
    do: checksum?(numbers, [8, 9, 2, 3, 4, 5, 6, 7], :zero_ten)

  defp regon?(numbers),
    do:
      regon?(Enum.take(numbers, 9)) &&
        checksum?(numbers, [2, 4, 8, 5, 0, 9, 7, 3, 6, 1, 2, 4, 8], :zero_ten)

  defp checksum?(numbers, weights, mode) do
    check = rem(weighted(numbers, weights), 11)
    check = if check == 10 && mode == :zero_ten, do: 0, else: check
    varied?(numbers) && check == List.last(numbers)
  end

  defp weighted(numbers, weights), do: Enum.zip_with(numbers, weights, &*/2) |> Enum.sum()

  defp iban?(<<country::binary-size(2), _::binary>> = value) do
    case Registry.country(country) do
      %{length: size, pattern: pattern} when byte_size(value) == size ->
        <<head::binary-size(4), tail::binary>> = value
        Regex.match?(pattern, value) && mod97(tail <> head) == 1

      _ ->
        false
    end
  end

  defp mod97(text) do
    text
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn
      char, acc when char in ?0..?9 -> rem(acc * 10 + char - ?0, 97)
      char, acc -> rem(acc * 100 + char - ?A + 10, 97)
    end)
  end

  defp luhn?(numbers) do
    numbers
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {number, index} ->
      doubled = if rem(index, 2) == 1, do: number * 2, else: number
      if doubled > 9, do: doubled - 9, else: doubled
    end)
    |> Enum.sum()
    |> rem(10)
    |> Kernel.==(0)
  end

  defp card_context?(text, first) do
    prefix = binary_part(text, 0, first) |> String.slice(-48, 48)

    Regex.match?(
      ~r/(?:\bcard|\bkart[ayę]|\bpan|\bvisa|\bmastercard|\bamex)[^\n]{0,32}\z/iu,
      prefix
    )
  end
end
