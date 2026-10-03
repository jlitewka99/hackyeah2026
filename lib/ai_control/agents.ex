defmodule AiControl.Agents do
  @moduledoc "Organization-owned agents with current capability and resource checks."
  import Ecto.Query

  alias AiControl.Agents.Agent
  alias AiControl.Organizations
  alias AiControl.Organizations.Access
  alias AiControl.Repo

  def change_agent(agent \\ %Agent{}, attrs \\ %{}), do: Agent.changeset(agent, attrs)
  def list_agents(scope), do: list_for_permission(scope, "agents.read")

  @doc "Agent choices for a permitted key workflow, without requiring agents.read."
  def list_for_permission(scope, permission)
      when permission in ["agents.read", "api_keys.read", "api_keys.manage"] do
    with {:ok, current} <- Access.authorize(scope, permission) do
      {:ok, Repo.all(scoped_query(current))}
    end
  end

  @doc "Resource choices a member manager is allowed to delegate."
  def list_assignable_agents(scope) do
    with {:ok, current} <- Organizations.refresh_scope(scope),
         :ok <- Organizations.require_manager(current) do
      {:ok, Repo.all(scoped_query(current))}
    end
  end

  def create_agent(scope, attrs) do
    Organizations.locked(scope, fn current ->
      with {:ok, current} <- Access.authorize(current, "agents.manage"),
           true <- "*" in current.grants.agents do
        Repo.insert(Agent.changeset(%Agent{organization_id: current.organization.id}, attrs))
      else
        _ -> {:error, :forbidden}
      end
    end)
  end

  def update_agent(scope, id, attrs) do
    Organizations.locked(scope, fn current ->
      with {:ok, agent} <- fetch_agent(current, id, "agents.manage") do
        Repo.update(Agent.changeset(agent, attrs))
      end
    end)
  end

  def set_status(scope, id, status) when status in [:active, :suspended] do
    Organizations.locked(scope, fn current ->
      with {:ok, agent} <- fetch_agent(current, id, "agents.manage") do
        Repo.update(Ecto.Changeset.change(agent, status: status))
      end
    end)
  end

  def set_status(_, _, _), do: {:error, :forbidden}

  def fetch_agent(scope, id, permission \\ "agents.read") do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, current} <- Access.authorize(scope, permission, %{agent: id}),
         %Agent{} = agent <- Repo.get_by(Agent, id: id, organization_id: current.organization.id) do
      {:ok, agent}
    else
      _ -> {:error, :forbidden}
    end
  end

  def owned?(organization_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Repo.exists?(
          from(a in Agent, where: a.id == ^id and a.organization_id == ^organization_id)
        )

      _ ->
        false
    end
  end

  defp scoped_query(scope) do
    query =
      from(a in Agent,
        where: a.organization_id == ^scope.organization.id,
        order_by: [asc: a.name, asc: a.id]
      )

    if "*" in scope.grants.agents,
      do: query,
      else: from(a in query, where: a.id in ^scope.grants.agents)
  end
end
