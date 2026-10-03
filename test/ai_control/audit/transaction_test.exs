defmodule AiControl.Audit.TransactionTest do
  use AiControl.DataCase, async: false

  import AiControl.AccountsFixtures
  import AiControl.OrganizationsFixtures
  import AiControl.SecurityFixtures

  alias AiControl.{Accounts, Audit, Organizations, Security}
  alias AiControl.Audit.Event
  alias AiControl.Organizations.{Invitation, Invitations, Membership, Organization}

  test "real database rejection rolls back organization creation" do
    scope = organizer_scope_fixture()
    reject_event("organization.created")

    assert {:error, :audit_unavailable} =
             Organizations.create_organization(scope, %{name: "Rollback org"})

    refute Repo.get_by(Organization, name: "Rollback org")
  end

  test "a failed audit cannot release a security decision" do
    scope = organization_fixture()
    policy = policy_fixture()
    context = context_fixture(scope, policy)
    assessment = assessment_fixture(context)
    reject_event("security.decision")
    assert {:error, :audit_unavailable} = Security.evaluate_and_audit(context, assessment, policy)
    refute Repo.get(Event, assessment.id)
  end

  test "status, access and removal roll back without PubSub on audit failure" do
    scope = organization_fixture()
    member = member_fixture(scope)
    Phoenix.PubSub.subscribe(AiControl.PubSub, "organizations:#{scope.organization.id}:access")

    for {type, callback} <- [
          {"organization.status_changed", fn -> Organizations.set_status(scope, :suspended) end},
          {"member.access_changed",
           fn ->
             Organizations.update_member(scope, member.membership.id, %{
               grants: %{permissions: ["events.read"]}
             })
           end},
          {"member.removed", fn -> Organizations.remove_member(scope, member.membership.id) end}
        ] do
      reject_event(type)
      assert {:error, :audit_unavailable} = callback.()
      assert Repo.get!(Organization, scope.organization.id).status == :active
      assert Repo.get!(Membership, member.membership.id).grants.permissions == []
      refute_received {:organization_access_changed, _}
      allow_events()
    end
  end

  test "failed ownership audit restores both roles" do
    scope = organization_fixture()
    owner = member_fixture(scope, :superadmin)
    target = member_fixture(scope, :admin)
    reject_event("superadmin.transferred")

    assert {:error, :audit_unavailable} =
             Organizations.transfer_superadmin(owner.scope, target.membership.id)

    assert Repo.get!(Membership, owner.membership.id).role == :superadmin
    assert Repo.get!(Membership, target.membership.id).role == :admin
  end

  test "issuance audit failure creates no invitation and sends no email" do
    scope = organization_fixture()
    reject_event("invitation.issued")
    email = unique_user_email()

    assert {:error, :audit_unavailable} =
             Invitations.issue(scope, %{email: email, role: :user}, & &1)

    refute Repo.get_by(Invitation, email: email)
    refute_received {:email, _}
  end

  test "acceptance audit failure restores token and rolls back new account and membership" do
    scope = organization_fixture()
    {invitation, token} = invitation_fixture(scope)
    reject_event("invitation.accepted")

    assert {:error, :audit_unavailable} =
             Invitations.accept(token, nil, %{
               "password" => valid_user_password(),
               "password_confirmation" => valid_user_password()
             })

    refute Accounts.get_user_by_email(invitation.email)
    refute Repo.get!(Invitation, invitation.id).accepted_at
    assert {:ok, _} = Invitations.preview(token)
    assert Repo.aggregate(Membership, :count) == 0
  end

  test "revocation audit failure leaves token usable" do
    scope = organization_fixture()
    {invitation, token} = invitation_fixture(scope)
    reject_event("invitation.revoked")
    assert {:error, :audit_unavailable} = Invitations.revoke(scope, invitation.id)
    assert {:ok, _} = Invitations.preview(token)
  end

  test "mail failure persists audited revocation and audit failure drops the new token" do
    scope = organization_fixture()
    previous = Application.fetch_env!(:ai_control, AiControl.Mailer)
    Application.put_env(:ai_control, AiControl.Mailer, adapter: AiControl.FailingMailAdapter)
    on_exit(fn -> Application.put_env(:ai_control, AiControl.Mailer, previous) end)

    email = unique_user_email()

    assert {:error, :delivery_failed} =
             Invitations.issue(scope, %{email: email, role: :user}, & &1)

    invitation = Repo.get_by!(Invitation, email: email)
    assert invitation.revoked_at
    assert Repo.get_by!(Event, event_type: "invitation.delivery_failed", target_id: invitation.id)

    reject_event("invitation.delivery_failed")
    other_email = unique_user_email()

    assert {:error, :audit_unavailable} =
             Invitations.issue(scope, %{email: other_email, role: :user}, & &1)

    refute Repo.get_by(Invitation, email: other_email)
  end

  test "administrative evidence retains old grants and removed member references" do
    scope = organization_fixture()
    member = member_fixture(scope, :user, %{permissions: ["events.read"]})

    assert {:ok, _} =
             Organizations.update_member(scope, member.membership.id, %{
               grants: %{permissions: []}
             })

    event =
      Repo.get_by!(Event, event_type: "member.access_changed", target_id: member.membership.id)

    assert event.data["before"]["permissions"] == ["events.read"]
    assert event.data["after"]["permissions"] == []
    refute event.data["before"]["grants_fingerprint"] == event.data["after"]["grants_fingerprint"]
    assert {:ok, _} = Organizations.remove_member(scope, member.membership.id)
    assert {:ok, persisted} = Audit.get_event(scope, event.id)
    assert persisted.target_id == member.membership.id
    refute Repo.get(Membership, member.membership.id)
  end

  defp reject_event(type) do
    Repo.query!(
      "ALTER TABLE audit_events ADD CONSTRAINT audit_test_rejection CHECK (event_type <> '#{type}') NOT VALID",
      [],
      log: false
    )
  end

  defp allow_events,
    do:
      Repo.query!("ALTER TABLE audit_events DROP CONSTRAINT audit_test_rejection", [], log: false)
end
