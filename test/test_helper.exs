ExUnit.start(exclude: [:live_models, :live_ner])
Ecto.Adapters.SQL.Sandbox.mode(AiControl.Repo, :manual)
