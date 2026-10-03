defmodule AiControl.SemanticProviderMock do
  @moduledoc false
  @behaviour AiControl.Guards.Semantic.Provider

  alias AiControl.Guards.Semantic.Local

  @impl true
  def ready?(_config), do: true

  @impl true
  def analyze(fields, task, _config) do
    {:ok,
     %{
       "model_set" => Local.model_set(),
       "revision" => Local.revision(),
       "task" => task,
       "duration_us" => 1,
       "windows" =>
         fields
         |> Enum.with_index()
         |> Enum.map(fn {text, index} ->
           %{
             "field_index" => index,
             "start_byte" => 0,
             "end_byte" => byte_size(text),
             "severity" => "Unsafe",
             "categories" => [if(task == "injection", do: "Jailbreak", else: "Violent")],
             "refusal" => if(task == "moderation", do: "No")
           }
         end)
     }}
  end
end
