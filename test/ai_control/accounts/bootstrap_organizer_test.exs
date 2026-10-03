defmodule AiControl.Accounts.BootstrapOrganizerTest do
  use AiControl.DataCase, async: false

  import AiControl.AccountsFixtures

  alias AiControl.Accounts
  alias AiControl.Accounts.User

  test "creates a confirmed organizer with a UUID and hashed password" do
    email = unique_user_email()
    assert {:ok, {user, :created}} = Accounts.bootstrap_organizer(email, valid_user_password())
    assert user.organizer
    assert user.confirmed_at
    assert Ecto.UUID.cast(user.id) == {:ok, user.id}
    assert user.password == nil
    assert user.hashed_password != valid_user_password()
    assert Accounts.get_user_by_email_and_password(email, valid_user_password()).id == user.id
  end

  test "repeat bootstrap preserves credentials and existing sessions" do
    email = unique_user_email()
    assert {:ok, {user, :created}} = Accounts.bootstrap_organizer(email, valid_user_password())
    token = Accounts.generate_user_session_token(user)

    assert {:ok, {same, :existing}} =
             Accounts.bootstrap_organizer(
               "  " <> String.upcase(email) <> "  ",
               "a different password"
             )

    assert same.id == user.id
    assert same.hashed_password == user.hashed_password
    assert Accounts.get_user_by_session_token(token)

    assert {:error, :organizer_exists} =
             Accounts.bootstrap_organizer(unique_user_email(), valid_user_password())

    assert Repo.aggregate(User, :count) == 1
  end

  test "does not promote an existing account" do
    user = user_fixture()

    assert {:error, :email_taken} =
             Accounts.bootstrap_organizer(user.email, valid_user_password())

    refute Repo.get!(User, user.id).organizer
  end

  test "invalid email or password leaves the database empty" do
    assert {:error, changeset} = Accounts.bootstrap_organizer("invalid", "short")
    assert errors_on(changeset).email
    assert errors_on(changeset).password
    assert Repo.aggregate(User, :count) == 0
  end

  test "organizer privilege cannot be supplied through user registration" do
    assert {:ok, user} = Accounts.register_user(%{email: unique_user_email(), organizer: true})
    refute user.organizer
  end

  test "database enforces one organizer independently of the bootstrap command" do
    assert {:ok, {_user, :created}} =
             Accounts.bootstrap_organizer(unique_user_email(), valid_user_password())

    changeset =
      %User{organizer: true}
      |> User.email_changeset(%{email: unique_user_email()})
      |> unique_constraint(:organizer, name: :users_single_organizer_index)

    assert {:error, changeset} = Repo.insert(changeset)
    assert errors_on(changeset).organizer == ["has already been taken"]
  end
end
