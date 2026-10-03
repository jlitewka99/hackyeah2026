defmodule Mix.Tasks.AiControl.BootstrapOrganizerTest do
  use AiControl.DataCase, async: false

  import AiControl.AccountsFixtures
  import ExUnit.CaptureIO

  alias Mix.Tasks.AiControl.BootstrapOrganizer

  setup do
    original =
      for key <- ~w(AI_CONTROL_ORGANIZER_EMAIL AI_CONTROL_ORGANIZER_PASSWORD),
          do: {key, System.get_env(key)}

    on_exit(fn ->
      for {key, value} <- original do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "requires environment credentials and rejects command line arguments" do
    System.delete_env("AI_CONTROL_ORGANIZER_EMAIL")
    System.delete_env("AI_CONTROL_ORGANIZER_PASSWORD")
    assert_raise Mix.Error, fn -> BootstrapOrganizer.run([]) end
    assert_raise Mix.Error, fn -> BootstrapOrganizer.run(["secret"]) end
  end

  test "reports creation and idempotence without echoing credentials" do
    email = unique_user_email()
    password = valid_user_password()
    System.put_env("AI_CONTROL_ORGANIZER_EMAIL", email)
    System.put_env("AI_CONTROL_ORGANIZER_PASSWORD", password)
    created = capture_io(fn -> BootstrapOrganizer.run([]) end)
    existing = capture_io(fn -> BootstrapOrganizer.run([]) end)
    assert created =~ "created"
    assert existing =~ "unchanged"

    for output <- [created, existing] do
      refute output =~ email
      refute output =~ password
    end
  end
end
