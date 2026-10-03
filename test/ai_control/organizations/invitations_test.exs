defmodule AiControl.Organizations.InvitationsTest do
  use AiControl.DataCase, async: true

  import AiControl.AccountsFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.Accounts
  alias AiControl.Accounts.Scope
  alias AiControl.Organizations
  alias AiControl.Organizations.{Invitations, Membership}

  test "invitation creates no account until password activation and can only be accepted once" do
    scope = organization_fixture()
    {invitation, token} = invitation_fixture(scope)
    assert Accounts.get_user_by_email(invitation.email) == nil
    assert invitation.token_hash != token
    assert {:ok, _} = Invitations.preview(token)
    assert {:error, %Ecto.Changeset{}} = Invitations.accept(token, nil, %{"password" => "short"})
    assert Accounts.get_user_by_email(invitation.email) == nil
    refute invitation_for(invitation.id).accepted_at

    assert {:ok, result} =
             Invitations.accept(token, nil, %{
               "password" => valid_user_password(),
               "password_confirmation" => valid_user_password()
             })

    assert result.user.confirmed_at
    assert result.membership.organization_id == scope.organization.id
    assert Accounts.get_user_by_email_and_password(invitation.email, valid_user_password())
    assert {:error, :invalid_invitation} = Invitations.accept(token, nil, %{})
  end

  test "existing accounts must authenticate without changing their password or other memberships" do
    scope = organization_fixture()
    other = organization_fixture()
    existing = member_fixture(other)
    {invitation, token} = invitation_fixture(scope, %{email: existing.user.email})

    assert {:error, :authentication_required} =
             Invitations.accept(token, nil, %{"password" => "overwritten password"})

    assert {:error, :wrong_account} =
             Invitations.accept(token, Scope.for_user(user_fixture()), %{})

    assert {:ok, result} =
             Invitations.accept(token, Scope.for_user(existing.user), %{
               "password" => "overwritten password"
             })

    assert result.user.hashed_password == existing.user.hashed_password
    assert Repo.get!(Membership, existing.membership.id)
    assert invitation_for(invitation.id).accepted_at
  end

  test "tokens expire at the exact boundary and malformed tokens are rejected" do
    scope = organization_fixture()
    {invitation, token} = invitation_fixture(scope)
    assert DateTime.diff(invitation.expires_at, invitation.inserted_at) == 86_400
    expire_invitation(invitation)
    assert {:error, :invalid_invitation} = Invitations.preview(token)
    assert {:error, :invalid_invitation} = Invitations.accept(token, nil, %{})
    assert {:error, :invalid_invitation} = Invitations.preview("malformed")
    assert {:error, :invalid_invitation} = Invitations.preview(nil)
  end

  test "revocation and resend invalidate the old token" do
    scope = organization_fixture()
    {invitation, token} = invitation_fixture(scope)
    assert {:ok, replacement} = Invitations.resend(scope, invitation.id, &"[TOKEN]#{&1}[TOKEN]")
    assert replacement.id != invitation.id
    assert {:error, :invalid_invitation} = Invitations.preview(token)
    assert invitation_for(invitation.id).revoked_at
    assert {:ok, _} = Invitations.revoke(scope, replacement.id)
    assert invitation_for(replacement.id).revoked_at
  end

  test "admin invitation grants and role cannot exceed their access" do
    scope = organization_fixture()
    admin = member_fixture(scope, :admin, %{permissions: ["events.read"]})

    assert {:error, :forbidden} =
             Invitations.issue(admin.scope, %{email: unique_user_email(), role: :admin}, & &1)

    assert {:error, :forbidden} =
             Invitations.issue(
               admin.scope,
               %{email: unique_user_email(), role: :user, grants: %{permissions: ["ai.use"]}},
               & &1
             )

    assert {:ok, _} =
             Invitations.issue(
               admin.scope,
               %{
                 email: unique_user_email(),
                 role: :user,
                 grants: %{permissions: ["events.read"]}
               },
               & &1
             )
  end

  test "acceptance rechecks the inviter grants and organization status" do
    scope = organization_fixture()
    admin = member_fixture(scope, :admin, %{permissions: ["events.read"]})
    {_, token} = invitation_fixture(admin.scope, %{grants: %{permissions: ["events.read"]}})

    assert {:ok, _} =
             Organizations.update_member(scope, admin.membership.id, %{grants: %{permissions: []}})

    assert {:error, :invalid_invitation} =
             Invitations.accept(token, nil, %{"password" => valid_user_password()})

    {_, other_token} = invitation_fixture(scope)
    assert {:ok, _} = Organizations.set_status(scope, :suspended)
    assert {:error, :invalid_invitation} = Invitations.accept(other_token, nil, %{})
  end

  test "only the organizer invites a first owner and only one is pending" do
    scope = organization_fixture()
    {_, token} = invitation_fixture(scope, %{role: :superadmin})

    assert {:error, :pending_superadmin} =
             Invitations.issue(scope, %{email: unique_user_email(), role: :superadmin}, & &1)

    assert {:ok, result} =
             Invitations.accept(token, nil, %{
               "password" => valid_user_password(),
               "password_confirmation" => valid_user_password()
             })

    assert result.membership.role == :superadmin

    assert {:error, :forbidden} =
             Invitations.issue(scope, %{email: unique_user_email(), role: :superadmin}, & &1)
  end

  test "cross-organization invitation IDs cannot be revoked" do
    first = organization_fixture()
    second = organization_fixture()
    admin = member_fixture(first, :admin)
    {invitation, _} = invitation_fixture(second)
    assert {:error, :not_found} = Invitations.revoke(admin.scope, invitation.id)
    refute invitation_for(invitation.id).revoked_at
  end
end
