defmodule Mix.Tasks.AiControl.BootstrapOrganizer do
  @shortdoc "Bootstraps the sole organizer from environment variables"
  @moduledoc """
  Creates the sole organizer using AI_CONTROL_ORGANIZER_EMAIL and
  AI_CONTROL_ORGANIZER_PASSWORD. Repeating it preserves the existing account.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run([]) do
    email = System.get_env("AI_CONTROL_ORGANIZER_EMAIL")
    password = System.get_env("AI_CONTROL_ORGANIZER_PASSWORD")

    require_credentials!(email, password)

    case AiControl.Accounts.bootstrap_organizer(email, password) do
      {:ok, {_user, :created}} ->
        Mix.shell().info("Organizer account created.")

      {:ok, {_user, :existing}} ->
        Mix.shell().info("Organizer account already exists; unchanged.")

      {:error, :organizer_exists} ->
        Mix.raise("An organizer with a different email already exists.")

      {:error, :email_taken} ->
        Mix.raise("The email belongs to an existing account.")

      {:error, %Ecto.Changeset{}} ->
        Mix.raise("Invalid organizer email or password (12–72 characters, at most 72 bytes).")
    end
  end

  def run(_args), do: Mix.raise("This command takes no arguments; use environment variables.")

  defp require_credentials!(email, password) do
    if !(is_binary(email) and is_binary(password) and email != "" and password != "") do
      Mix.raise("Set AI_CONTROL_ORGANIZER_EMAIL and AI_CONTROL_ORGANIZER_PASSWORD.")
    end
  end
end
