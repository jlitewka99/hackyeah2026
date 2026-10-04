defmodule AiControl.Testing.Provider do
  @moduledoc "Controlled provider for a closed synthetic suite in an isolated BEAM process."
  @behaviour AiControl.Gateway.Provider

  alias AiControl.Testing.State

  @impl true
  def models(config), do: {:ok, config[:models]}
  @impl true
  def prepare(params, config),
    do: {:ok, Map.put_new(params, "max_tokens", config[:default_max_tokens])}

  @impl true
  def chat(params, _) do
    State.put(:messages, params["messages"])
    if callback = State.get(:before_response), do: callback.()

    {:ok,
     %{
       "choices" => [
         %{
           "message" => %{
             "role" => "assistant",
             "content" => State.get(:content, "Synthetic safe response")
           },
           "finish_reason" => "stop"
         }
       ],
       "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4, "total_tokens" => 16}
     }}
  end
end
