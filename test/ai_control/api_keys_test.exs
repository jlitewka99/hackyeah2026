defmodule AiControl.ApiKeysTest do
  use AiControl.DataCase, async: true

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import ExUnit.CaptureLog

  alias AiControl.{Agents, ApiKeys, Organizations, Repo}
  alias AiControl.ApiKeys.{ApiKey, Principal}
  alias AiControl.Organizations.Membership

  setup do
    scope = organization_fixture()
    %{scope: scope, agent: agent_fixture(scope)}
  end

  test "secrets have 256 random bits and only their hashes and public prefixes persist", %{
    scope: scope,
    agent: agent
  } do
    {key, token} = key_fixture(scope, agent)
    ["aic", id, secret] = String.split(token, "_", parts: 3)
    assert id == key.id
    assert {:ok, random} = Base.url_decode64(secret, padding: false)
    assert byte_size(random) == 32
    stored = Repo.get!(ApiKey, key.id)
    assert stored.token_hash == :crypto.hash(:sha256, token)
    assert stored.prefix == "aic_#{String.slice(id, 0, 8)}"

    assert DateTime.diff(stored.expires_at, stored.inserted_at) in (90 * 86_400 - 1)..(90 * 86_400 +
                                                                                         1)

    refute Map.has_key?(key, :token_hash)
    assert {:ok, [^key]} = ApiKeys.list_keys(scope)

    assert {:ok,
            %Principal{organization_id: organization_id, agent_id: agent_id, api_key_id: ^id}} =
             ApiKeys.authenticate(token)

    assert organization_id == scope.organization.id
    assert agent_id == agent.id
    {_other_key, other_token} = key_fixture(scope, agent)
    refute token == other_token
  end

  test "expiration supports UTC custom dates, no expiration, and rejects invalid dates", %{
    scope: scope,
    agent: agent
  } do
    custom = DateTime.utc_now(:second) |> DateTime.add(2, :day) |> DateTime.to_naive()
    {key, _} = key_fixture(scope, agent, %{expiry_mode: :custom, expiry_at: custom})
    assert DateTime.to_naive(key.expires_at) == custom
    {key, token} = key_fixture(scope, agent, %{expiry_mode: :never})
    assert key.expires_at == nil
    assert {:ok, _} = ApiKeys.authenticate(token)

    for attrs <- [
          %{expiry_mode: :custom},
          %{expiry_mode: :custom, expiry_at: ~N[2020-01-01 00:00:00]},
          %{expiry_mode: :custom, expiry_at: "invalid"},
          %{expiry_mode: "unknown"}
        ] do
      assert {:error, %Ecto.Changeset{}} =
               ApiKeys.create_key(scope, agent.id, Map.put(attrs, :label, "Invalid date"))
    end
  end

  test "expired keys including the current second fail without sleeping", %{
    scope: scope,
    agent: agent
  } do
    {key, token} = key_fixture(scope, agent)

    Repo.get!(ApiKey, key.id)
    |> Ecto.Changeset.change(expires_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:error, :invalid_api_key} = ApiKeys.authenticate(token)
    assert {:error, :inactive_key} = ApiKeys.rotate_key(scope, key.id)
  end

  test "revocation is immediate, permanent, and idempotent", %{scope: scope, agent: agent} do
    {key, token} = key_fixture(scope, agent)
    assert {:ok, revoked} = ApiKeys.revoke_key(scope, key.id)
    assert revoked.revoked_at
    assert {:ok, ^revoked} = ApiKeys.revoke_key(scope, key.id)
    assert {:error, :invalid_api_key} = ApiKeys.authenticate(token)
    assert {:error, :inactive_key} = ApiKeys.rotate_key(scope, key.id)
    assert ApiKeys.status(revoked) == :revoked
  end

  test "rotation creates one new identity, renews expiration and invalidates old secret", %{
    scope: scope,
    agent: agent
  } do
    {key, token} = key_fixture(scope, agent)

    assert {:ok, {replacement, replacement_token}} =
             ApiKeys.rotate_key(scope, key.id, %{label: "Replacement", expiry_mode: :never})

    refute replacement.id == key.id
    assert replacement.agent_id == agent.id
    assert replacement.label == "Replacement"
    assert replacement.expires_at == nil
    assert {:error, :invalid_api_key} = ApiKeys.authenticate(token)
    assert {:ok, _} = ApiKeys.authenticate(replacement_token)
    assert {:error, :inactive_key} = ApiKeys.rotate_key(scope, key.id)
    assert {:ok, keys} = ApiKeys.list_keys(scope)
    assert length(keys) == 2
  end

  test "invalid replacement rolls back and leaves old key usable", %{scope: scope, agent: agent} do
    {key, token} = key_fixture(scope, agent)
    assert {:error, %Ecto.Changeset{}} = ApiKeys.rotate_key(scope, key.id, %{label: ""})
    assert Repo.get!(ApiKey, key.id).revoked_at == nil
    assert Repo.aggregate(ApiKey, :count) == 1
    assert {:ok, _} = ApiKeys.authenticate(token)
  end

  test "suspension blocks keys and issuance; restoration respects expiration and revocation", %{
    scope: scope,
    agent: agent
  } do
    {key, token} = key_fixture(scope, agent)
    {revoked, revoked_token} = key_fixture(scope, agent)
    assert {:ok, _} = ApiKeys.revoke_key(scope, revoked.id)
    assert {:ok, _} = Agents.set_status(scope, agent.id, :suspended)
    assert {:error, :invalid_api_key} = ApiKeys.authenticate(token)
    assert {:error, :inactive_agent} = ApiKeys.create_key(scope, agent.id, %{label: "Suspended"})
    assert {:error, :inactive_agent} = ApiKeys.rotate_key(scope, key.id)
    assert {:ok, _} = Agents.set_status(scope, agent.id, :active)
    assert {:ok, _} = ApiKeys.authenticate(token)
    assert {:error, :invalid_api_key} = ApiKeys.authenticate(revoked_token)
    assert {:ok, _} = Organizations.set_status(scope, :suspended)
    assert {:error, :invalid_api_key} = ApiKeys.authenticate(token)
    assert {:error, :inactive_agent} = ApiKeys.create_key(scope, agent.id, %{label: "Suspended"})
    assert {:ok, _} = Organizations.set_status(scope, :active)
    assert {:ok, _} = ApiKeys.authenticate(token)
  end

  test "key workflows work without agents.read and filter by selected agents", %{
    scope: scope,
    agent: agent
  } do
    hidden = agent_fixture(scope)
    key_fixture(scope, hidden)

    user =
      member_fixture(scope, :user, %{
        permissions: ["api_keys.read", "api_keys.manage"],
        agents: [agent.id]
      })

    assert {:error, :forbidden} = Agents.list_agents(user.scope)
    assert {:ok, [^agent]} = Agents.list_for_permission(user.scope, "api_keys.manage")
    assert {:ok, {key, _}} = ApiKeys.create_key(user.scope, agent.id, %{label: "Scoped key"})
    assert {:ok, [^key]} = ApiKeys.list_keys(user.scope)
    assert {:error, :forbidden} = ApiKeys.list_keys(user.scope, hidden.id)
    assert {:error, :forbidden} = ApiKeys.create_key(user.scope, hidden.id, %{label: "Denied"})
  end

  test "foreign IDs, arbitrary attrs and stale membership cannot cross boundaries", %{
    scope: scope,
    agent: agent
  } do
    other = organization_fixture()
    foreign = agent_fixture(other)
    {foreign_key, _} = key_fixture(other, foreign)

    {key, _} =
      key_fixture(scope, agent, %{
        organization_id: other.organization.id,
        agent_id: foreign.id,
        revoked_at: DateTime.utc_now(:second),
        token_hash: "injected",
        prefix: "injected"
      })

    assert key.organization_id == scope.organization.id
    assert key.agent_id == agent.id
    refute key.revoked_at
    refute key.prefix == "injected"
    assert {:error, :forbidden} = ApiKeys.create_key(scope, foreign.id, %{label: "Foreign"})
    assert {:error, :forbidden} = ApiKeys.rotate_key(scope, foreign_key.id)
    assert {:error, :forbidden} = ApiKeys.revoke_key(scope, foreign_key.id)
    user = member_fixture(scope, :user, %{permissions: ["api_keys.manage"], agents: [agent.id]})
    assert {:ok, _} = Organizations.remove_member(scope, user.membership.id)
    assert {:error, _} = ApiKeys.create_key(user.scope, agent.id, %{label: "Stale scope"})
  end

  test "read and write permissions are independent and keys outlive their creator's membership",
       %{scope: scope, agent: agent} do
    user = member_fixture(scope, :user, %{permissions: ["api_keys.manage"], agents: [agent.id]})
    assert {:ok, {key, token}} = ApiKeys.create_key(user.scope, agent.id, %{label: "Application"})
    assert {:error, :forbidden} = ApiKeys.list_keys(user.scope)
    reader = member_fixture(scope, :user, %{permissions: ["api_keys.read"], agents: [agent.id]})
    assert {:error, :forbidden} = ApiKeys.revoke_key(reader.scope, key.id)
    assert {:ok, _} = Organizations.remove_member(scope, user.membership.id)
    assert {:ok, _} = ApiKeys.authenticate(token)
  end

  test "the database rejects an agent from a different organization", %{
    agent: agent
  } do
    other = organization_fixture()

    malformed = %ApiKey{
      organization_id: other.organization.id,
      agent_id: agent.id,
      token_hash: :crypto.strong_rand_bytes(32),
      prefix: "aic_test"
    }

    assert {:error, %Ecto.Changeset{errors: errors}} =
             Repo.insert(ApiKey.changeset(malformed, %{label: "Foreign agent"}))

    assert Keyword.has_key?(errors, :agent_id)
  end

  test "secret-free metadata, notifications and logs", %{scope: scope, agent: agent} do
    Phoenix.PubSub.subscribe(AiControl.PubSub, "organizations:#{scope.organization.id}:access")

    log =
      capture_log([level: :debug], fn ->
        {key, token} = key_fixture(scope, agent)
        assert_receive {:organization_access_changed, organization_id}
        assert organization_id == scope.organization.id
        assert {:ok, _} = ApiKeys.authenticate(token)
        assert {:ok, metadata} = ApiKeys.list_keys(scope)
        refute inspect(metadata) =~ token
        assert {:ok, _} = ApiKeys.revoke_key(scope, key.id)
        send(self(), {:token_for_log_assertion, token})
      end)

    assert_receive {:token_for_log_assertion, token}
    refute log =~ token
    refute log =~ Enum.at(String.split(token, "_", parts: 3), 2)
    refute inspect(%ApiKey{token_hash: "sensitive_hash"}) =~ "sensitive_hash"
  end

  test "invalid token shapes never authenticate" do
    for token <- [
          nil,
          "",
          "invalid",
          "Bearer secret",
          String.duplicate("x", 84),
          "aic_#{Ecto.UUID.generate()}_#{String.duplicate("!", 43)}"
        ] do
      assert {:error, :invalid_api_key} = ApiKeys.authenticate(token)
    end
  end

  test "a forged scope refreshes the current membership", %{scope: scope, agent: agent} do
    member = member_fixture(scope)
    forged = %{member.scope | grants: scope.grants}
    assert {:error, :forbidden} = ApiKeys.create_key(forged, agent.id, %{label: "Forged scope"})
    assert Repo.get!(Membership, member.membership.id).grants.permissions == []
  end
end
