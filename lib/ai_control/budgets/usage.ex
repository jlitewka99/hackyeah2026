defmodule AiControl.Budgets.Usage do
  @moduledoc "The same content-free usage contract for target and guard models."
  @keys ~w(prompt_tokens completion_tokens total_tokens)
  def normalize(usage) when is_map(usage) do
    if Enum.all?(
         @keys,
         &(is_integer(usage[&1]) && usage[&1] >= 0 && usage[&1] <= 9_000_000_000_000_000)
       ) &&
         usage["total_tokens"] == usage["prompt_tokens"] + usage["completion_tokens"] do
      {:ok, Map.take(usage, @keys)}
    else
      {:error, :invalid_usage}
    end
  end

  def normalize(_), do: {:error, :invalid_usage}
end
