defmodule AiControl.TestOrganizationResourceResolver do
  @moduledoc false
  @behaviour AiControl.Organizations.ResourceResolver

  @impl true
  def owned?(organization_id, kind, key), do: key == "#{organization_id}:#{kind}"
end
