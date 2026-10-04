defmodule AiControl.Approvals.Cipher do
  @moduledoc "AEAD preview storage, separated from audit fingerprint and session keys."

  def encrypt(id, org, payload) do
    with {:ok, key, key_id} <- key(),
         {:ok, plaintext} <- Jason.encode(payload),
         true <- byte_size(plaintext) <= 1_048_576 do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad(id, org), true)

      {:ok, <<nonce::binary, tag::binary, ciphertext::binary>>, key_id}
    else
      _ -> {:error, :approval_unavailable}
    end
  end

  def decrypt(
        %{ciphertext: <<nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>} =
          record
      ) do
    with {:ok, key, key_id} <- key(),
         true <- key_id == record.encryption_key_id,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             aad(record.id, record.organization_id),
             tag,
             false
           ),
         {:ok, payload} <- Jason.decode(plaintext) do
      {:ok, payload}
    else
      _ -> {:error, :approval_unavailable}
    end
  end

  def decrypt(_), do: {:error, :approval_unavailable}

  def key do
    config = Application.get_env(:ai_control, __MODULE__, [])

    case {config[:key], config[:key_id]} do
      {key, id}
      when is_binary(key) and byte_size(key) == 32 and is_binary(id) and byte_size(id) in 1..96 ->
        {:ok, key, id}

      _ ->
        {:error, :approval_unavailable}
    end
  end

  defp aad(id, org), do: :erlang.term_to_binary({"ai-control.approval.v1", id, org})
end
