defmodule AiControl.Security.HTTPError do
  @moduledoc "Content-free classification of HTTP client failures for future downstream adapters."
  def classify(%Req.TransportError{reason: :timeout}), do: :upstream_timeout
  def classify(%Req.TransportError{}), do: :upstream_unavailable
  def classify(%Req.Response{status: status}) when status >= 400, do: :upstream_rejected
  def classify(_), do: :upstream_invalid_response
end
