defmodule AiControl.KnowledgeFixtures do
  @moduledoc "Explicit test-only Knowledge policies; expensive guards are opted out by fixtures."
  alias AiControl.{Knowledge, Policies}
  alias AiControl.Policies.Configuration

  def activate_knowledge_policy(scope, overrides \\ %{}) do
    guards = Map.new(Configuration.guards(5), &{&1, %{"enabled" => false, "required" => false}})

    source =
      Configuration.default(5)
      |> Map.put("guards", guards)
      |> Map.put("knowledge", %{"enabled" => true, "memory_write_enabled" => true})
      |> Map.merge(overrides)
      |> Map.put("guards", Map.merge(guards, Map.get(overrides, "guards", %{})))

    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    version
  end

  def document_attrs(agent, overrides \\ %{}),
    do:
      Map.merge(
        %{
          "kind" => "document",
          "owner_agent_id" => agent.id,
          "title" => "Support handbook",
          "content" =>
            "Support is available on weekdays. Contact the support team for assistance."
        },
        overrides
      )

  def document_fixture(scope, agent, overrides \\ %{}) do
    {:ok, resource} = Knowledge.create(scope, document_attrs(agent, overrides))
    resource
  end
end
