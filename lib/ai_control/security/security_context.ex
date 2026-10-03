defmodule AiControl.Security.SecurityContext do
  @moduledoc "Verified identity and safe request metadata. new/1 is for trusted identity adapters."
  alias AiControl.Organizations
  alias AiControl.Security.{Fingerprint, Validation}

  @fields [
    :organization_id,
    :user_id,
    :agent_id,
    :api_key_id,
    :actor_type,
    :request_id,
    :assessment_id,
    :stage,
    :policy_version,
    :policy_checksum,
    :occurred_at,
    :fingerprint
  ]
  @request_fields [:stage, :policy_version, :policy_checksum, :fingerprint]
  @derive {Inspect, only: [:organization_id, :assessment_id, :stage]}
  defstruct @fields

  @type t :: %__MODULE__{
          organization_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t() | nil,
          agent_id: Ecto.UUID.t() | nil,
          api_key_id: Ecto.UUID.t() | nil,
          actor_type: :user | :agent,
          request_id: Ecto.UUID.t(),
          assessment_id: Ecto.UUID.t(),
          stage: :input | :output,
          policy_version: String.t(),
          policy_checksum: String.t(),
          occurred_at: DateTime.t(),
          fingerprint: Fingerprint.t() | nil
        }

  def from_scope(scope, attrs) when is_map(attrs) and not is_struct(attrs) do
    with true <- Enum.all?(Map.keys(attrs), &(&1 in @request_fields)),
         {:ok, current} <- Organizations.refresh_scope(scope),
         true <- current.organization.status == :active do
      attrs
      |> Map.merge(%{
        organization_id: current.organization.id,
        user_id: current.user.id,
        actor_type: :user
      })
      |> new()
    else
      _ -> {:error, :forbidden}
    end
  end

  def from_scope(_, _), do: {:error, :forbidden}

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs =
      attrs
      |> Map.put_new_lazy(:request_id, &Ecto.UUID.generate/0)
      |> Map.put_new_lazy(:assessment_id, &Ecto.UUID.generate/0)
      |> Map.put_new_lazy(:occurred_at, &DateTime.utc_now/0)

    Validation.build(__MODULE__, attrs, @fields, &valid?/1)
  end

  def new(_), do: {:error, :invalid_security_data}

  def valid?(%__MODULE__{} = context) do
    identifiers?(context) && identity?(context) && context.stage in [:input, :output] &&
      Validation.code?(context.policy_version) && Validation.checksum?(context.policy_checksum) &&
      Validation.utc?(context.occurred_at) && fingerprint?(context)
  end

  def valid?(_), do: false

  defp identifiers?(context),
    do:
      Enum.all?(
        [context.organization_id, context.request_id, context.assessment_id],
        &Validation.uuid?/1
      )

  defp fingerprint?(%{fingerprint: nil}), do: true

  defp fingerprint?(context),
    do:
      Fingerprint.valid?(context.fingerprint) &&
        context.fingerprint.organization_id == context.organization_id &&
        context.fingerprint.stage == context.stage

  defp identity?(%{actor_type: :user, user_id: user_id, agent_id: nil, api_key_id: nil}),
    do: Validation.uuid?(user_id)

  defp identity?(%{actor_type: :agent, user_id: nil, agent_id: agent_id, api_key_id: key_id}),
    do: Validation.uuid?(agent_id) && Validation.uuid?(key_id)

  defp identity?(_), do: false
end
