defmodule AiControl.Guards.Registry do
  @moduledoc "Pinned offline detector catalog; changing a set requires a new set identifier."
  @path Path.expand("../../../priv/guards/iban.v1.json", __DIR__)
  @hash_path Path.expand("../../../priv/guards/iban.v1.sha256", __DIR__)
  @external_resource @path
  @external_resource @hash_path
  @raw File.read!(@path)
  @expected String.trim(File.read!(@hash_path))
  @catalog Jason.decode!(@raw)
  @detectors_path Path.expand("../../../priv/guards/detectors.v1.json", __DIR__)
  @detectors_hash_path Path.expand("../../../priv/guards/detectors.v1.sha256", __DIR__)
  @external_resource @detectors_path
  @external_resource @detectors_hash_path
  @detectors_raw File.read!(@detectors_path)
  @detectors_expected String.trim(File.read!(@detectors_hash_path))
  @countries Map.new(@catalog["countries"], fn {country, format} ->
               {country, %{length: format["length"], pattern: Regex.compile!(format["pattern"])}}
             end)
  @sets %{
    "pii" => "builtin.v1",
    "secret" => "builtin.v1",
    "signatures" => "builtin.v1",
    "ner" => "pl-nkjp.v1"
  }

  def sets, do: @sets
  def country(code), do: Map.get(@countries, code)
  def valid?, do: checksum(@raw) == @expected && checksum(@detectors_raw) == @detectors_expected
  defp checksum(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
