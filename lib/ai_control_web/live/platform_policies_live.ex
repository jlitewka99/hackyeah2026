defmodule AiControlWeb.PlatformPoliciesLive do
  use AiControlWeb, :live_view

  alias AiControlWeb.PolicyLive

  def mount(_, _, socket), do: PolicyLive.mount(socket, :global)
  def handle_event(event, params, socket), do: PolicyLive.event(event, params, socket)
  def handle_info(message, socket), do: PolicyLive.info(message, socket)
end
