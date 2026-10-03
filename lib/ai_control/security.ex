defmodule AiControl.Security do
  @moduledoc "A decision is usable only after its required synchronous audit succeeds."
  alias AiControl.{Audit, Policy.Engine}

  def evaluate_and_audit(context, assessment, policy) do
    with {:ok, decision} <- Engine.evaluate(context, assessment, policy),
         {:ok, _event} <- Audit.record_decision(context, assessment, decision) do
      {:ok, decision}
    end
  end
end
