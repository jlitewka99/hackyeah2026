defmodule AiControl.Organizations.AccessTest do
  use AiControl.DataCase, async: false

  import AiControl.AccountsFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.Organizations
  alias AiControl.Organizations.{Access, Invitation, Invitations}

  setup do
    previous = Application.get_env(:ai_control, :organization_resource_resolver)

    Application.put_env(
      :ai_control,
      :organization_resource_resolver,
      AiControl.TestOrganizationResourceResolver
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ai_control, :organization_resource_resolver, previous),
        else: Application.delete_env(:ai_control, :organization_resource_resolver)
    end)

    :ok
  end

  test "AI requires both owned agent and model selectors, even for the organizer" do
    first = organization_fixture()
    second = organization_fixture()
    agent = "#{first.organization.id}:agent"
    model = "#{first.organization.id}:model"

    user =
      member_fixture(first, :user, %{permissions: ["ai.use"], agents: [agent], models: [model]})

    assert {:ok, _} = Access.authorize(user.scope, "ai.use", %{agent: agent, model: model})

    assert {:error, :forbidden} =
             Access.authorize(user.scope, "ai.use", %{
               agent: "#{second.organization.id}:agent",
               model: model
             })

    assert {:error, :forbidden} =
             Access.authorize(first, "ai.use", %{
               agent: agent,
               model: "#{second.organization.id}:model"
             })

    assert {:ok, _} =
             Organizations.update_member(first, user.membership.id, %{grants: %{models: []}})

    assert {:error, :forbidden} =
             Access.authorize(user.scope, "ai.use", %{agent: agent, model: model})

    assert {:ok, _} = Organizations.set_status(first, :suspended)

    assert {:error, :forbidden} =
             Access.authorize(first, "ai.use", %{agent: agent, model: model})
  end

  test "specific resource grants can be delegated only within the admin selectors" do
    scope = organization_fixture()
    agent = "#{scope.organization.id}:agent"
    admin = member_fixture(scope, :admin, %{permissions: ["agents.read"], agents: [agent]})
    user = member_fixture(scope)

    assert {:ok, _} =
             Organizations.update_member(admin.scope, user.membership.id, %{
               grants: %{permissions: ["agents.read"], agents: [agent]}
             })

    assert {:error, :forbidden} =
             Organizations.update_member(admin.scope, user.membership.id, %{
               grants: %{agents: ["*"]}
             })

    assert {:error, :unknown_resource} =
             Organizations.update_member(scope, user.membership.id, %{
               grants: %{agents: ["other-org:agent"]}
             })
  end

  test "delivery failure revokes the token and permits resend" do
    scope = organization_fixture()
    previous = Application.get_env(:ai_control, AiControl.Mailer)
    Application.put_env(:ai_control, AiControl.Mailer, adapter: AiControl.FailingMailAdapter)

    try do
      assert {:error, :delivery_failed} =
               Invitations.issue(scope, %{email: unique_user_email(), role: :user}, & &1)
    after
      Application.put_env(:ai_control, AiControl.Mailer, previous)
    end

    [failed] = Repo.all(Invitation)
    assert failed.revoked_at
    assert {:ok, _} = Invitations.resend(scope, failed.id, & &1)
  end
end
