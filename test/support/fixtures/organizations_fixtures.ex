defmodule AiControl.OrganizationsFixtures do
  @moduledoc "Organization fixtures and invitation mail capture."
  import AiControl.AccountsFixtures
  import Ecto.Query

  alias AiControl.Accounts
  alias AiControl.Accounts.{Scope, User}
  alias AiControl.Organizations
  alias AiControl.Organizations.{Grants, Invitation, Invitations, Membership}
  alias AiControl.Repo

  def organizer_scope_fixture do
    organizer = Repo.one(from(u in User, where: u.organizer))

    organizer =
      organizer ||
        elem(elem(Accounts.bootstrap_organizer(unique_user_email(), valid_user_password()), 1), 0)

    Scope.for_user(organizer)
  end

  def organization_fixture(attrs \\ %{}) do
    scope = organizer_scope_fixture()

    {:ok, organization} =
      Organizations.create_organization(
        scope,
        Map.merge(%{name: "Workspace #{System.unique_integer([:positive])}"}, attrs)
      )

    {:ok, scope} = Organizations.fetch_scope(scope, organization.id)
    scope
  end

  def member_fixture(scope, role \\ :user, grants \\ %{}) do
    user = user_fixture() |> set_password()

    {:ok, membership} =
      Repo.insert(
        Membership.changeset(
          %Membership{organization_id: scope.organization.id, user_id: user.id},
          %{role: role, grants: grants}
        )
      )

    {:ok, member_scope} = Organizations.fetch_scope(Scope.for_user(user), scope.organization.id)
    %{user: user, membership: membership, scope: member_scope}
  end

  def invitation_fixture(scope, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{email: unique_user_email(), role: :user, grants: Grants.attrs(%Grants{})},
        attrs
      )

    marker = fn token -> "[TOKEN]#{token}[TOKEN]" end
    {:ok, invitation} = Invitations.issue(scope, attrs, marker)
    recipient = invitation.email
    subject = "Join #{scope.organization.name} on AiControl"

    token =
      receive do
        {:email, %Swoosh.Email{subject: ^subject, to: [{_, ^recipient}]} = email} ->
          email.text_body |> String.split("[TOKEN]") |> Enum.at(1)
      after
        1_000 -> raise "Invitation email was not delivered"
      end

    {invitation, token}
  end

  def expire_invitation(invitation, at \\ DateTime.utc_now(:second)) do
    Repo.update!(Ecto.Changeset.change(invitation, expires_at: at))
  end

  def invitation_for(id), do: Repo.get!(Invitation, id)
end
