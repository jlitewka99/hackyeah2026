defmodule AiControl.Tools.SandboxTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.{ApiKeys, Policies, Repo, Tools}
  alias AiControl.Policies.Configuration
  alias AiControl.Tools.{Catalog, Sandbox}

  setup do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)

    source =
      Configuration.default(2)
      |> Map.put("tools", %{"allowed_tools" => Enum.map(Catalog.all(), & &1["name"])})

    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)

    server =
      start_supervised!(
        {Sandbox,
         organization_id: scope.organization.id,
         grants: %{
           agent.id => %{
             paths: ["documents/report.txt", "documents/draft.txt", "linked/key", "key"],
             tables: ["reports"],
             recipients: ["reviewer@demo.invalid"],
             commands: ["status", "echo"]
           }
         },
         files: %{
           "documents/report.txt" => "Synthetic report",
           "linked" => {:symlink, "~/.ssh"},
           "key" => {:symlink, "~/.ssh/id_rsa"}
         },
         tables: %{
           "reports" => [%{"id" => 1, "title" => "Example"}, %{"id" => 2, "title" => "Second"}]
         }}
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), server)
    %{scope: scope, agent: agent, principal: principal, server: server}
  end

  test "file read, write and delete stay in the tenant's virtual filesystem", context do
    assert {:ok, %{"content" => "Synthetic report"}} =
             run(context, "file.read", %{"path" => "documents/report.txt"})

    assert {:ok, %{"written" => true}} =
             run(context, "file.write", %{
               "path" => "documents/draft.txt",
               "content" => "Zażółć gęślą jaźń"
             })

    assert {:ok, %{"content" => "Zażółć gęślą jaźń"}} =
             run(context, "file.read", %{"path" => "documents/draft.txt"})

    assert {:ok, %{"deleted" => true}} =
             run(context, "file.delete", %{"path" => "documents/draft.txt"})

    assert {:error, :tool_resource_not_found} =
             run(context, "file.read", %{"path" => "documents/draft.txt"})
  end

  test "indirect injection paths, traversal and symlinks have no effects", context do
    before = Sandbox.inspect_state(context.server)

    for path <- [
          "~/.ssh/id_rsa",
          "../documents/report.txt",
          "/etc/passwd",
          "linked/key",
          "key",
          "documents/report.txt.bak"
        ],
        tool <- ~w(file.read file.write file.delete) do
      args =
        if tool == "file.write",
          do: %{"path" => path, "content" => "Attack"},
          else: %{"path" => path}

      assert {:error, :tool_resource_not_allowed} = run(context, tool, args)
    end

    assert before == Sandbox.inspect_state(context.server)
  end

  test "database supports bounded selection without raw SQL or writes", context do
    assert {:ok, %{"rows" => [%{"id" => 1}]}} =
             run(context, "database.select", %{"table" => "reports", "limit" => 1})

    before = Sandbox.inspect_state(context.server)
    assert {:error, :tool_not_allowed} = run(context, "database.delete", %{"table" => "reports"})

    assert {:error, :tool_resource_not_allowed} =
             run(context, "database.select", %{
               "table" => "reports; DROP TABLE reports",
               "limit" => 1
             })

    assert {:error, :invalid_tool_arguments} =
             run(context, "database.select", %{
               "table" => "reports",
               "limit" => 1,
               "sql" => "DROP TABLE reports"
             })

    assert before == Sandbox.inspect_state(context.server)
  end

  test "email is queued locally and unauthorized recipients do not receive messages", context do
    args = %{
      "recipient" => "reviewer@demo.invalid",
      "subject" => "Review",
      "body" => "Synthetic content"
    }

    assert {:ok, %{"queued_locally" => true}} = run(context, "email.send", args)
    before = Sandbox.inspect_state(context.server)
    assert before.mailbox == [args]

    assert {:error, :tool_resource_not_allowed} =
             run(context, "email.send", %{args | "recipient" => "attacker@demo.invalid"})

    assert before == Sandbox.inspect_state(context.server)
  end

  test "commands are functions and shell syntax remains literal text", context do
    assert {:ok, %{"output" => "sandbox ready"}} =
             run(context, "command.run", %{"command" => "status", "arguments" => []})

    literal = "$(cat ~/.ssh/id_rsa); rm -rf /"

    assert {:ok, %{"output" => ^literal}} =
             run(context, "command.run", %{"command" => "echo", "arguments" => [literal]})

    assert {:error, :tool_resource_not_allowed} =
             run(context, "command.run", %{"command" => "sh", "arguments" => ["-c"]})
  end

  test "tenant and agent isolation deny even valid principals", context do
    other = organization_fixture()
    other_agent = agent_fixture(other)
    other_principal = principal_fixture(other, other_agent)
    source = Configuration.default(2) |> Map.put("tools", %{"allowed_tools" => ["file.read"]})
    {:ok, version} = Policies.create_version(other, source)
    {:ok, policy} = Policies.current(other)
    {:ok, _} = Policies.activate(other, version.id, policy.set.revision)
    before = Sandbox.inspect_state(context.server)

    assert {:error, :forbidden} =
             Sandbox.run(context.server, other_principal, %{
               "tool" => "file.read",
               "arguments" => %{"path" => "documents/report.txt"}
             })

    another_agent = agent_fixture(context.scope)
    another_principal = principal_fixture(context.scope, another_agent)

    assert {:error, :tool_resource_not_allowed} =
             Sandbox.run(context.server, another_principal, %{
               "tool" => "file.read",
               "arguments" => %{"path" => "documents/report.txt"}
             })

    assert before == Sandbox.inspect_state(context.server)
  end

  test "revoked credentials and rejected HTTP do not alter sandbox", context do
    before = Sandbox.inspect_state(context.server)

    assert {:error, :tool_resource_not_allowed} =
             run(context, "http.get", %{"url" => "http://169.254.169.254/latest/meta-data/"})

    assert {:ok, _} = ApiKeys.revoke_key(context.scope, context.principal.api_key_id)
    assert {:error, :forbidden} = run(context, "file.delete", %{"path" => "documents/report.txt"})
    assert before == Sandbox.inspect_state(context.server)
  end

  test "key revoked between preparation and adapter entry stops the effect", context do
    {:ok, request} =
      Tools.prepare(context.principal, %{
        "tool" => "file.delete",
        "arguments" => %{"path" => "documents/report.txt"}
      })

    before = Sandbox.inspect_state(context.server)
    assert {:ok, _} = ApiKeys.revoke_key(context.scope, context.principal.api_key_id)
    assert {:error, :forbidden} = GenServer.call(context.server, {:run, request})
    assert before == Sandbox.inspect_state(context.server)
  end

  test "argument changes are checked against the total JSON limit before effects", context do
    {:ok, request} =
      Tools.prepare(context.principal, %{
        "tool" => "file.write",
        "arguments" => %{"path" => "documents/draft.txt", "content" => "safe"}
      })

    changed = %{
      request
      | arguments: Map.put(request.arguments, "content", String.duplicate("😀", 20_000))
    }

    before = Sandbox.inspect_state(context.server)

    assert {:error, :tool_request_too_large} = Tools.authorize(changed)
    assert {:error, :tool_request_too_large} = GenServer.call(context.server, {:run, changed})
    assert before == Sandbox.inspect_state(context.server)
  end

  test "HTTP executes after policy and exact endpoint grant; other targets never connect",
       context do
    http =
      start_supervised!(
        {Bandit,
         plug: {AiControl.TestToolHTTPPlug, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(http)
    url = "http://demo.invalid:#{port}/ok"

    sandbox =
      start_supervised!(
        Supervisor.child_spec(
          {Sandbox,
           organization_id: context.scope.organization.id,
           grants: %{
             context.agent.id => %{
               endpoints: %{url => %{ip: {127, 0, 0, 1}, allow_private?: true}}
             }
           }},
          id: :http_sandbox
        )
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), sandbox)

    assert {:ok, %{"body" => "Synthetic HTTP report"}} =
             Sandbox.run(sandbox, context.principal, %{
               "tool" => "http.get",
               "arguments" => %{"url" => url}
             })

    assert_received {:tool_http_request, "/ok", _}

    assert {:error, :tool_resource_not_allowed} =
             Sandbox.run(sandbox, context.principal, %{
               "tool" => "http.get",
               "arguments" => %{"url" => url <> "?exfiltrate=secret"}
             })

    refute_received {:tool_http_request, _, _}
  end

  defp run(context, tool, arguments),
    do:
      Sandbox.run(context.server, context.principal, %{"tool" => tool, "arguments" => arguments})
end
