ExUnit.start(
  exclude:
    [:live_models, :live_ner] ++
      if(System.get_env("TEST_RUNNER_DATABASE_URL"), do: [], else: [:runner])
)

Ecto.Adapters.SQL.Sandbox.mode(AiControl.Repo, :manual)
