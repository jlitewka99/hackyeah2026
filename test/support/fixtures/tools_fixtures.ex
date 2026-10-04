defmodule AiControl.ToolsFixtures do
  @moduledoc false
  alias AiControl.{ApiKeys, Policies}
  alias AiControl.Policies.Configuration
  alias AiControl.Tools.{Catalog, Config, Sandbox}

  def tool_fixture(opts \\ []) do
    scope = AiControl.OrganizationsFixtures.organization_fixture()
    agent = AiControl.AgentsFixtures.agent_fixture(scope)
    {_key, token} = AiControl.AgentsFixtures.key_fixture(scope, agent)
    {:ok, principal} = ApiKeys.authenticate(token)
    workflow = Ecto.UUID.generate()

    grant =
      Keyword.get(opts, :grant, %{
        paths: ["report.txt", "copy.txt", "missing.txt"],
        tables: ["reports"],
        recipients: ["demo@example.com"],
        commands: ["status", "echo"]
      })

    sandbox =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Sandbox,
           [
             name: Config.via(scope.organization.id),
             organization_id: scope.organization.id,
             contexts: %{agent.id => workflow},
             grants: %{agent.id => grant},
             files: Keyword.get(opts, :files, %{"report.txt" => "Zażółć gęślą jaźń"}),
             tables:
               Keyword.get(opts, :tables, %{"reports" => [%{"label" => "demo", "count" => 1}]})
           ]},
          id: scope.organization.id
        )
      )

    version = activate_tools(scope)

    %{
      scope: scope,
      agent: agent,
      principal: principal,
      token: token,
      workflow: workflow,
      sandbox: sandbox,
      version: version
    }
  end

  def activate_tools(scope, overrides \\ %{}) do
    guards = Map.new(Configuration.guards(3), &{&1, %{"enabled" => false, "required" => false}})

    source =
      Configuration.default(3)
      |> Map.put("guards", guards)
      |> Map.put("tools", %{"allowed_tools" => Enum.map(Catalog.all(), & &1["name"])})
      |> Map.merge(overrides)

    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    version
  end

  def tool_call(context, tool \\ "file.read", arguments \\ %{"path" => "report.txt"}, opts \\ []) do
    AiControl.Tools.execute(
      context.principal,
      %{"tool" => tool, "arguments" => arguments},
      Keyword.put_new(opts, :idempotency_key, Ecto.UUID.generate())
    )
  end
end
