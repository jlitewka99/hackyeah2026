defmodule AiControl.Knowledge.Evidence do
  @moduledoc "Strict content-free resource evidence shared by audit and exports."
  alias AiControl.Security.Validation

  def resource(resource),
    do: %{
      "resource_id" => resource.id,
      "revision" => resource.revision,
      "kind" => resource.kind,
      "trust_level" => resource.trust_level,
      "owner_agent_id" => resource.owner_agent_id
    }

  def valid?(items) when is_list(items), do: length(items) <= 50 and Enum.all?(items, &item?/1)
  def valid?(_), do: false

  defp item?(
         %{
           "resource_id" => id,
           "revision" => revision,
           "kind" => kind,
           "trust_level" => trust,
           "owner_agent_id" => owner
         } = item
       ),
       do:
         map_size(item) == 5 and Validation.uuid?(id) and Validation.uuid?(owner) and
           is_integer(revision) and revision > 0 and kind in ~w(document memory) and
           trust in ~w(untrusted internal)

  defp item?(_), do: false
end
