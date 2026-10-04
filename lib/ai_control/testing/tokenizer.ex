defmodule AiControl.Testing.Tokenizer do
  @moduledoc false
  @behaviour AiControl.Budgets.Tokenizer

  @impl true
  def count(_, _, _), do: {:ok, 12}
  @impl true
  def ready?(_), do: true
end
