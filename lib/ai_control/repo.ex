defmodule AiControl.Repo do
  use Ecto.Repo,
    otp_app: :ai_control,
    adapter: Ecto.Adapters.Postgres
end
