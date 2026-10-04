defmodule AiControl.ReleaseTest do
  use AiControl.DataCase, async: true

  import AiControl.AccountsFixtures

  test "organizer existence reflects the database, not a local setup marker" do
    refute AiControl.Release.organizer_exists?()

    assert {:ok, _} =
             AiControl.Accounts.bootstrap_organizer(unique_user_email(), valid_user_password())

    assert AiControl.Release.organizer_exists?()
  end
end
