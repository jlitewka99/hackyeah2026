defmodule AiControl.Tools.RequestTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.{Agents, ApiKeys, Organizations, Policies, Tools}
  alias AiControl.Policies.Configuration
  alias AiControl.Tools.Catalog

  setup do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)
    activate(scope, ["file.read"])
    %{scope: scope, agent: agent, principal: principal}
  end

  test "request binds verified identity and policy; inspect excludes content", context do
    assert {:ok, request} = Tools.prepare(context.principal, read("private-example.txt"))
    assert request.organization_id == context.scope.organization.id
    assert request.agent_id == context.agent.id
    assert request.api_key_id == context.principal.api_key_id
    assert request.policy.settings["tools"]["allowed_tools"] == ["file.read"]
    refute inspect(request) =~ "private-example"
    refute inspect(request) =~ context.principal.api_key_id
  end

  test "body cannot replace tenant, agent, identity, policy or schemas", context do
    for key <- ~w(organization_id agent_id api_key_id identity policy parameters request_id) do
      assert {:error, :invalid_tool_request} =
               Tools.prepare(context.principal, Map.put(read(), key, Ecto.UUID.generate()))
    end

    assert {:error, :forbidden} = Tools.prepare(context.scope, read())
    assert {:error, :forbidden} = Tools.prepare(%{}, read())
  end

  test "unknown operation and wrong argument schemas deny", context do
    for tool <- ["file.execute", "database.delete", "shell", "*", nil] do
      assert {:error, :tool_not_allowed} =
               Tools.prepare(context.principal, %{"tool" => tool, "arguments" => %{}})
    end

    for args <- [nil, [], "{}", %{}, %{"path" => 1}, %{"path" => "a", "extra" => true}] do
      assert {:error, :invalid_tool_arguments} =
               Tools.prepare(context.principal, %{"tool" => "file.read", "arguments" => args})
    end

    assert {:error, :invalid_tool_request} = Tools.prepare(context.principal, [])
    assert {:error, :invalid_tool_arguments} = Catalog.validate("file.read", %{"path" => <<255>>})

    assert {:error, :invalid_tool_arguments} =
             Catalog.validate("file.write", %{
               "path" => "a",
               "content" => String.duplicate("x", 32_769)
             })
  end

  test "v1, empty tool list and excluded agent deny", context do
    activate_gateway_policy(context.scope)
    assert {:error, :tool_not_allowed} = Tools.prepare(context.principal, read())
    activate(context.scope, [])
    assert {:error, :tool_not_allowed} = Tools.prepare(context.principal, read())
    activate(context.scope, ["file.read"], %{"allowed_agents" => []})
    assert {:error, :agent_not_allowed} = Tools.prepare(context.principal, read())
  end

  test "prepared snapshot stays pinned while new requests see activated policy", context do
    {:ok, request} = Tools.prepare(context.principal, read())
    activate(context.scope, [])
    assert :ok = Tools.authorize(request)
    assert {:error, :tool_not_allowed} = Tools.prepare(context.principal, read())

    assert {:error, :policy_unavailable} =
             Tools.authorize(%{
               request
               | policy: %{request.policy | checksum: String.duplicate("0", 64)}
             })
  end

  test "live key revocation stops a prepared request", context do
    {:ok, request} = Tools.prepare(context.principal, read())
    assert {:ok, _} = ApiKeys.revoke_key(context.scope, context.principal.api_key_id)
    assert {:error, :forbidden} = Tools.authorize(request)
    assert {:error, :forbidden} = Tools.prepare(context.principal, read())
  end

  test "expired and malformed identities fail before resource access", context do
    {:ok, request} = Tools.prepare(context.principal, read())
    key = Repo.get!(AiControl.ApiKeys.ApiKey, context.principal.api_key_id)

    Repo.update!(
      Ecto.Changeset.change(key, expires_at: DateTime.add(DateTime.utc_now(:second), -60))
    )

    assert {:error, :forbidden} = Tools.authorize(request)

    for field <- [:organization_id, :agent_id, :api_key_id] do
      assert {:error, :forbidden} =
               Tools.prepare(Map.put(context.principal, field, "invalid"), read())
    end
  end

  test "Unicode schema lengths and total encoded request size are bounded", context do
    unicode = String.duplicate("ą", 20_000)
    assert :ok = Catalog.validate("file.write", %{"path" => "a", "content" => unicode})

    oversized = %{
      "tool" => "file.write",
      "arguments" => %{"path" => "a", "content" => String.duplicate("😀", 20_000)}
    }

    assert {:error, :tool_request_too_large} = Tools.prepare(context.principal, oversized)
  end

  test "agent and organization suspension stop prepared requests", context do
    {:ok, request} = Tools.prepare(context.principal, read())
    assert {:ok, _} = Agents.set_status(context.scope, context.agent.id, :suspended)
    assert {:error, :forbidden} = Tools.authorize(request)
    assert {:ok, _} = Agents.set_status(context.scope, context.agent.id, :active)
    assert {:ok, _} = Organizations.set_status(context.scope, :suspended)
    assert {:error, :forbidden} = Tools.authorize(request)
  end

  test "mixing verified identity fields from different tenants denies", context do
    other = organization_fixture()
    agent = agent_fixture(other)
    principal = principal_fixture(other, agent)

    for forged <- [
          %{context.principal | organization_id: other.organization.id},
          %{context.principal | agent_id: principal.agent_id},
          %{context.principal | api_key_id: principal.api_key_id}
        ] do
      assert {:error, :forbidden} = Tools.prepare(forged, read())
    end
  end

  defp read(path \\ "documents/report.txt"),
    do: %{"tool" => "file.read", "arguments" => %{"path" => path}}

  defp activate(scope, tools, overrides \\ %{}) do
    source =
      Configuration.default(2)
      |> Map.put("tools", %{"allowed_tools" => tools})
      |> Map.merge(overrides)

    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    version
  end
end
