defmodule AiControlWeb.OrganizationUI do
  @moduledoc "Shared organization labels and individual access controls."
  use AiControlWeb, :html

  alias AiControl.Organizations.{Grants, Invitation}

  def role_name(:superadmin), do: "Superadmin"
  def role_name(:admin), do: "Admin"
  def role_name(:user), do: "User"
  def role_name(_), do: "Organizer"
  def invitation_status(%Invitation{accepted_at: at}) when not is_nil(at), do: "Accepted"
  def invitation_status(%Invitation{revoked_at: at}) when not is_nil(at), do: "Revoked"

  def invitation_status(invitation),
    do: if(Invitation.pending?(invitation), do: "Pending", else: "Expired")

  def permission_name("ai.use"), do: "AI: use"
  def permission_name("api_keys." <> action), do: "API keys: #{action}"

  def permission_name(permission),
    do: permission |> String.replace("_", " ") |> String.replace(".", ": ") |> String.capitalize()

  def error_message(:delivery_failed),
    do: "The email could not be delivered. Please resend the invitation."

  def error_message(:already_member), do: "This account is already a member of the organization."
  def error_message(:pending_superadmin), do: "A superadmin invitation is already pending."

  def error_message(:unknown_resource),
    do: "The selected resource is unavailable in this organization."

  def error_message(_), do: "This change is not allowed. Refresh the page and check your access."

  def grant_params(params) do
    permissions =
      case Map.get(params, "permissions", []) do
        values when is_list(values) -> Enum.reject(values, &(&1 == "false"))
        invalid -> invalid
      end

    %{
      "permissions" => permissions,
      "agents" => if(params["all_agents"] == "true", do: ["*"], else: []),
      "models" => if(params["all_models"] == "true", do: ["*"], else: [])
    }
  end

  def access_form(grants, role \\ :user) do
    grants = grants || %Grants{}

    grants
    |> Ecto.Changeset.change(
      role: to_string(role),
      all_agents: "*" in grants.agents,
      all_models: "*" in grants.models
    )
    |> to_form(as: :access)
  end

  attr :form, :any, required: true
  attr :allowed, :any, required: true
  attr :id, :string, required: true

  def grant_fields(assigns) do
    assigns = assign(assigns, :permissions, Grants.permissions())

    ~H"""
    <fieldset class="access-fieldset">
      <legend>Function permissions</legend>
      <p class="muted text-sm mb-4">
        Choose each capability separately. AI and reporting features become available as they are enabled.
      </p>
      <div class="permission-grid">
        <.input
          :for={permission <- @permissions}
          type="checkbox"
          name="access[permissions][]"
          id={"#{@id}-#{String.replace(permission, ".", "-")}"}
          checkbox_value={permission}
          checked={permission in (@form[:permissions].value || [])}
          disabled={permission not in @allowed.permissions}
          label={permission_name(permission)}
        />
      </div>
    </fieldset>
    <fieldset class="access-fieldset">
      <legend>Resource access</legend>
      <p class="muted text-sm mb-4">
        No resources are allowed by default. All-resource access also covers resources added later. Specific agents and models can be assigned when their registries are available.
      </p>
      <div class="permission-grid">
        <.input
          field={@form[:all_agents]}
          type="checkbox"
          id={"#{@id}-all-agents"}
          disabled={"*" not in @allowed.agents}
          label="Allow all organization agents"
        />
        <.input
          field={@form[:all_models]}
          type="checkbox"
          id={"#{@id}-all-models"}
          disabled={"*" not in @allowed.models}
          label="Allow all organization models"
        />
      </div>
    </fieldset>
    """
  end
end
