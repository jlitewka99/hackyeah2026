defmodule AiControl.Security.Validation do
  @moduledoc false

  def build(module, attrs, allowed, validate) when is_map(attrs) and not is_struct(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in allowed)) do
      value = struct(module, attrs)
      if validate.(value), do: {:ok, value}, else: {:error, :invalid_security_data}
    else
      {:error, :invalid_security_data}
    end
  end

  def build(_, _, _, _), do: {:error, :invalid_security_data}

  def uuid?(value), do: is_binary(value) && match?({:ok, ^value}, Ecto.UUID.cast(value))
  def optional_uuid?(nil), do: true
  def optional_uuid?(value), do: uuid?(value)
  def code?(value), do: is_binary(value) && Regex.match?(~r/\A[a-z][a-z0-9_.-]{0,79}\z/, value)
  def checksum?(value), do: is_binary(value) && Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  def score?(value), do: is_number(value) && value >= 0 && value <= 1
  def duration?(value), do: is_integer(value) && value >= 0
  def codes?(values), do: is_list(values) && Enum.all?(values, &code?/1)
  def utc?(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: true
  def utc?(_), do: false
end
