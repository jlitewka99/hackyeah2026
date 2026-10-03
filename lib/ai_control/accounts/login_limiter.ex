defmodule AiControl.Accounts.LoginLimiter do
  @moduledoc """
  Shared authentication limits backed by supervised Hammer ETS counters.

  A window starts with the first attempt and lasts 15 minutes: five attempts per
  normalized email and twenty per peer IP. Each counter is updated atomically.
  Checking IP first bounds email keys from a single peer and counts rejected
  email attempts against that peer's limit. Email keys contain SHA-256 hashes.
  Counters are local to one instance and reset when the ETS owner restarts.
  """
  use Hammer, backend: :ets, algorithm: :fix_window_per_key

  alias AiControl.Accounts.User

  @window to_timeout(minute: 15)

  def check(ip, email \\ nil, backend \\ __MODULE__) do
    with :ok <- check_key(backend, {:ip, ip}, 20) do
      if is_binary(email) do
        fingerprint = :crypto.hash(:sha256, User.normalize_email(email))
        check_key(backend, {:email, fingerprint}, 5)
      else
        :ok
      end
    end
  end

  defp check_key(backend, key, limit) do
    case backend.hit(key, @window, limit) do
      {:allow, _count} -> :ok
      {:deny, milliseconds} -> {:error, max(1, div(milliseconds + 999, 1000))}
    end
  end
end
