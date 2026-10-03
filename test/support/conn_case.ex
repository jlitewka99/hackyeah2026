defmodule AiControlWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AiControlWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias AiControl.Accounts
  alias AiControl.Accounts.Scope
  alias AiControl.AccountsFixtures

  using do
    quote do
      use AiControlWeb, :verified_routes

      # Import conveniences for testing with connections
      import AiControlWeb.ConnCase
      import Phoenix.ConnTest
      import Plug.Conn

      # The default endpoint for testing
      @endpoint AiControlWeb.Endpoint
    end
  end

  setup tags do
    AiControl.DataCase.setup_sandbox(tags)
    # Separate peer addresses keep production limits enabled in concurrent tests.
    peer = System.unique_integer([:positive])

    conn = %{
      Phoenix.ConnTest.build_conn()
      | remote_ip: {127, 1, rem(div(peer, 256), 256), rem(peer, 256)}
    }

    {:ok, conn: conn}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.to_list()

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
