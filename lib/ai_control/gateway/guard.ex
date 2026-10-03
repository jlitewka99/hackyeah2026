defmodule AiControl.Gateway.Guard do
  @moduledoc "Future guards receive the current fields and return typed, content-free findings."
  @callback assess(
              [String.t()],
              AiControl.Security.SecurityContext.t(),
              AiControl.Policy.Snapshot.t(),
              keyword()
            ) ::
              {:ok, AiControl.Security.GuardResult.t()} | {:error, atom()}
  @callback ready?(keyword()) :: boolean()
end
