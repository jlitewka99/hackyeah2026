defmodule AiControl.LoginLimiterBackend do
  @moduledoc false
  use Hammer, backend: :ets, algorithm: :fix_window_per_key
end
