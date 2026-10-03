defmodule AiControl.Guards.PiiTest do
  use ExUnit.Case, async: true

  alias AiControl.Guards.Pii

  test "valid identifiers, formats and contextual cards retain exact UTF-8 spans" do
    for {id, value} <- [
          {"pesel", "44051401458"},
          {"pesel", "00222912349"},
          {"pesel", "440514-01458"},
          {"nip", "5261040828"},
          {"nip", "526-104-08-28"},
          {"regon", "000331501"},
          {"regon", "00033150100000"},
          {"nrb", "61 1090 1014 0000 0712 1981 2874"},
          {"iban", "PL61109010140000071219812874"},
          {"iban", "GB82 WEST 1234 5698 7654 32"},
          {"iban", "DE89370400440532013000"},
          {"card", "4111 1111 1111 1111"},
          {"email", "jan.kowalski+test@example.org"}
        ] do
      prefix = "Żółć 😀 card: "
      {:ok, result} = Pii.assess([prefix <> value <> "."], nil, nil, [])
      finding = Enum.find(result.detections, &(&1.rule_id == "pii.#{id}.v1"))
      assert finding, "Missing #{id}"

      assert finding.location == %{
               field_index: 0,
               start_byte: byte_size(prefix),
               end_byte: byte_size(prefix <> value)
             }
    end
  end

  test "invalid dates, checksums, unsupported lengths and distant digits do not match their type" do
    for {id, value} <- [
          {"pesel", "99023112340"},
          {"pesel", "44051401459"},
          {"pesel", "440514\n01458"},
          {"nip", "5261040829"},
          {"regon", "000331502"},
          {"regon", "00033150100001"},
          {"iban", "ZZ61109010140000071219812874"},
          {"iban", "DE89370400440532013001"},
          {"iban", "DE8937040044053201300"},
          {"nrb", "61\n1090 1014 0000 0712 1981 2874"},
          {"card", "card: 4111111111111112"},
          {"card", "4111111111111111"},
          {"email", "example.org"}
        ] do
      {:ok, result} = Pii.assess([value], nil, nil, [])
      refute Enum.any?(result.detections, &(&1.rule_id == "pii.#{id}.v1")), "Unexpected #{id}"
    end
  end

  test "numbers embedded in code identifiers cannot be stripped into candidates" do
    for text <- [
          "key44051401458suffix",
          "sha_5261040828_suffix",
          "prefix000331501x",
          "00000000000000000000000000"
        ] do
      {:ok, result} = Pii.assess([text], nil, nil, [])
      assert result.detections == []
    end
  end
end
