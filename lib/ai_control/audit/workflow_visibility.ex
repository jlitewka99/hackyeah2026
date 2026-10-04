defmodule AiControl.Audit.WorkflowVisibility do
  @moduledoc "Workflow evidence inherits root-owner and participant assignments, including exports."
  import Ecto.Query

  alias AiControl.Accounts.Scope
  alias AiControl.Workflows.{Participant, Run}

  def query(query, %Scope{grants: %{agents: ["*"]}}), do: query

  def query(query, %Scope{} = scope) do
    agents = scope.grants.agents

    from(e in query,
      left_join: r in Run,
      on: r.id == e.run_id and r.organization_id == e.organization_id,
      left_join: p in Participant,
      on:
        p.id == e.participant_id and p.run_id == e.run_id and
          p.organization_id == e.organization_id,
      where:
        is_nil(e.run_id) or
          (r.owner_agent_id in ^agents and
             (is_nil(e.participant_id) or p.agent_id in ^agents) and
             (is_nil(e.agent_id) or e.agent_id in ^agents))
    )
  end
end
