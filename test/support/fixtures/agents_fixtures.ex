defmodule AiControl.AgentsFixtures do
  @moduledoc "Fixtures for organization agents and one-time API credentials."
  alias AiControl.{Agents, ApiKeys}

  def agent_fixture(scope, attrs \\ %{}) do
    {:ok, agent} =
      Agents.create_agent(
        scope,
        Map.merge(%{name: "Agent #{System.unique_integer([:positive])}"}, attrs)
      )

    agent
  end

  def key_fixture(scope, agent, attrs \\ %{}) do
    {:ok, result} =
      ApiKeys.create_key(
        scope,
        agent.id,
        Map.merge(%{label: "Integration #{System.unique_integer([:positive])}"}, attrs)
      )

    result
  end
end
