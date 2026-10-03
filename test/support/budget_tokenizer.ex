defmodule AiControl.TestBudgetTokenizer do
  @moduledoc false
  @behaviour AiControl.Budgets.Tokenizer

  @impl true
  def count(model, prompt, config) do
    if callback = config[:test_tokenizer], do: callback.(model, prompt), else: {:ok, 12}
  end

  @impl true
  def ready?(_), do: true
end
