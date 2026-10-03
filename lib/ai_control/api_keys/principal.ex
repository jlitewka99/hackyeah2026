defmodule AiControl.ApiKeys.Principal do
  @moduledoc "An authenticated agent identity, separate from human account scopes."
  @enforce_keys [:organization_id, :agent_id, :api_key_id]
  defstruct [:organization_id, :agent_id, :api_key_id]
end
