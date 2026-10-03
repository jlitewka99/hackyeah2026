defmodule AiControl.Guards.Semantic.Provider do
  @moduledoc "Classification transport independent of policy enforcement."
  @callback analyze([String.t()], String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  @callback ready?(keyword()) :: boolean()
end
