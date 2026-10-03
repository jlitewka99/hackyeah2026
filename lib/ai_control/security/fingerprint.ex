defmodule AiControl.Security.Fingerprint do
  @moduledoc "Tenant- and stage-separated HMAC fingerprints. Content is never retained."
  alias AiControl.Security.Validation

  @derive {Inspect, only: [:key_id, :digest]}
  @enforce_keys [:key_id, :digest, :organization_id, :stage]
  defstruct [:key_id, :digest, :organization_id, :stage]

  @type t :: %__MODULE__{
          key_id: String.t(),
          digest: String.t(),
          organization_id: Ecto.UUID.t(),
          stage: :input | :output | :administrative
        }

  def content(organization_id, stage, content)
      when stage in [:input, :output, :administrative] and is_binary(content) do
    if Validation.uuid?(organization_id) do
      config = Application.fetch_env!(:ai_control, __MODULE__)
      key = Keyword.fetch!(config, :key)
      key_id = Keyword.fetch!(config, :key_id)

      if is_binary(key) && byte_size(key) >= 32 && Validation.code?(key_id) do
        data = :erlang.term_to_binary({"ai_control.audit.v1", organization_id, stage, content})
        digest = :crypto.mac(:hmac, :sha256, key, data) |> Base.encode16(case: :lower)

        {:ok,
         %__MODULE__{
           key_id: key_id,
           digest: digest,
           organization_id: organization_id,
           stage: stage
         }}
      else
        {:error, :fingerprint_unavailable}
      end
    else
      {:error, :invalid_security_data}
    end
  end

  def content(_, _, _), do: {:error, :invalid_security_data}

  def valid?(%__MODULE__{} = fingerprint),
    do:
      Validation.code?(fingerprint.key_id) && Validation.checksum?(fingerprint.digest) &&
        Validation.uuid?(fingerprint.organization_id) &&
        fingerprint.stage in [:input, :output, :administrative]

  def valid?(_), do: false
end
