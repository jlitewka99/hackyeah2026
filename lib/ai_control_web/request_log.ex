defmodule AiControlWeb.RequestLog do
  @moduledoc "Suppresses access-log paths containing authentication tokens."

  def level(%{path_info: ["users", "log-in", _token]}), do: false
  def level(%{path_info: ["users", "settings", "confirm-email", _token]}), do: false
  def level(%{path_info: ["invitations" | _]}), do: false
  def level(_conn), do: :info
end
