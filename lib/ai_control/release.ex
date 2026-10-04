defmodule AiControl.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  alias AiControl.Policies.Bootstrap

  @app :ai_control

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &migrate_repo/1)
    end
  end

  defp migrate_repo(repo) do
    fresh? = Enum.all?(Ecto.Migrator.migrations(repo), fn {status, _, _} -> status == :down end)
    result = Ecto.Migrator.run(repo, :up, all: true)
    if fresh?, do: Bootstrap.seed_new_installation(repo)
    result
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def bootstrap_organizer do
    load_app()
    {:ok, _} = Application.ensure_all_started(:bcrypt_elixir)
    email = System.fetch_env!("AI_CONTROL_ORGANIZER_EMAIL")
    password = System.fetch_env!("AI_CONTROL_ORGANIZER_PASSWORD")

    {:ok, result, _} =
      Ecto.Migrator.with_repo(AiControl.Repo, fn _ ->
        AiControl.Accounts.bootstrap_organizer(email, password)
      end)

    case result do
      {:ok, _} -> :ok
      _ -> raise "Organizer bootstrap failed"
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
