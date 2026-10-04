defmodule AiControl.Gateway.StreamEvidence do
  @moduledoc "Closed content-free evidence for buffered SSE delivery."
  @counts ~w(received_bytes received_chunks sent_bytes sent_chunks)
  @keys ["mode", "delivery" | @counts]
  def new,
    do: Map.merge(%{"mode" => "buffered", "delivery" => "preparing"}, Map.new(@counts, &{&1, 0}))

  def valid?(value) when is_map(value),
    do:
      Enum.sort(Map.keys(value)) == Enum.sort(@keys) && value["mode"] == "buffered" &&
        value["delivery"] in ~w(preparing ready completed failed cancelled) &&
        Enum.all?(@counts, &(is_integer(value[&1]) && value[&1] >= 0))

  def valid?(_), do: false
end
