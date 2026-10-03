defmodule AiControl.Gateway.Provider do
  @moduledoc "Replaceable non-streaming backend. Errors must be content-free atoms."
  @callback models(keyword()) :: {:ok, map()} | {:error, atom()}
  @callback chat(map(), keyword()) :: {:ok, map()} | {:error, atom()}
end
