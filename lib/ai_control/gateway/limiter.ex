defmodule AiControl.Gateway.Limiter do
  @moduledoc "Per-node ingress counters. All credentials of one agent share a counter."
  use Hammer, backend: :ets, algorithm: :fix_window_per_key

  alias AiControl.Gateway.Config

  def check_ip(ip) do
    case hit({:ingress_ip, ip}, 60_000, Config.get(:ip_requests_per_minute)) do
      {:allow, _} -> :ok
      {:deny, ms} -> {:error, {:rate_limited, max(1, div(ms + 999, 1000))}}
    end
  end

  def check(identity) do
    key =
      case identity do
        %AiControl.ApiKeys.Principal{} -> {:agent, identity.organization_id, identity.agent_id}
        %AiControl.Accounts.Scope{} -> {:user, identity.organization.id, identity.user.id}
      end

    case hit(key, 60_000, Config.get(:requests_per_minute)) do
      {:allow, _} -> :ok
      {:deny, ms} -> {:error, {:rate_limited, max(1, div(ms + 999, 1000))}}
    end
  end
end
