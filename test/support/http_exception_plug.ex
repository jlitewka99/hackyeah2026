defmodule AiControl.HTTPExceptionPlug do
  @moduledoc false
  @behaviour Plug

  def init(opts), do: opts
  def call(_conn, _opts), do: raise("private-http-exception-body")
end
