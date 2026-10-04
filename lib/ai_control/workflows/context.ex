defmodule AiControl.Workflows.Context do
  @moduledoc "Reference only. Every boundary revalidates identity and persisted membership."
  @enforce_keys [:organization_id, :run_id, :participant_id, :agent_id]
  defstruct [:organization_id, :run_id, :participant_id, :agent_id, :operation_id, :api_key_id]
end
