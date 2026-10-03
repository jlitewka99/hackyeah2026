defmodule AiControl.Budgets.Pricing do
  @moduledoc "Operator rates per million tokens; never inferred from a local model."
  alias AiControl.Gateway.Config

  def snapshot(model), do: Map.get(Config.get(:prices), model)

  def valid?(prices) when is_map(prices),
    do: Enum.all?(prices, fn {model, price} -> is_binary(model) && price?(price) end)

  def valid?(_), do: false

  defp price?(
         %{"currency" => currency, "input_per_million" => input, "output_per_million" => output} =
           price
       ) do
    map_size(price) == 3 && is_binary(currency) && Regex.match?(~r/\A[A-Z]{3}\z/, currency) &&
      rate?(input) && rate?(output)
  end

  defp price?(_), do: false
  defp rate?(value) when is_binary(value), do: Regex.match?(~r/\A\d{1,12}(\.\d{1,12})?\z/, value)
  defp rate?(_), do: false
  def cost(nil, _), do: nil

  def cost(price, usage) do
    input = Decimal.mult(Decimal.new(price["input_per_million"]), usage["prompt_tokens"])
    output = Decimal.mult(Decimal.new(price["output_per_million"]), usage["completion_tokens"])
    Decimal.div(Decimal.add(input, output), 1_000_000) |> Decimal.round(12)
  end
end
