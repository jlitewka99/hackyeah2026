defmodule AiControl.Gateway.Provider do
  @moduledoc "Replaceable backend. Errors must be content-free atoms; streams return a complete envelope."
  @callback models(keyword()) :: {:ok, map()} | {:error, atom()}
  @callback chat(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  @callback prepare(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  @callback chat_stream(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  @optional_callbacks chat_stream: 2
end
