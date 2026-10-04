defmodule AiControl.Testing.Protocol do
  @moduledoc "Closed IPC projection; child output is untrusted until validated."
  alias AiControl.Security.Validation

  @evidence ~w(http_status audit_count settled_tokens reserved_tokens request_count expected_block observed_block provider dataset_checksum)
  def case_result(row) do
    with true <-
           is_map(row) &&
             Enum.sort(Map.keys(row)) == Enum.sort(~w(case_id status duration_us evidence)),
         true <-
           is_binary(row["case_id"]) && Regex.match?(~r/\A[a-z0-9_.-]{1,96}\z/, row["case_id"]),
         true <- row["status"] in ~w(passed failed error),
         true <- is_integer(row["duration_us"]) && row["duration_us"] >= 0,
         evidence when is_map(evidence) <- row["evidence"],
         true <- Enum.all?(evidence, &safe?/1) do
      {:ok, row}
    else
      _ -> {:error, :invalid_result}
    end
  end

  defp safe?({key, value}) when key in @evidence do
    cond do
      key in ~w(expected_block observed_block) -> is_boolean(value) || is_nil(value)
      key == "provider" -> value in ~w(qwen prompt_guard controlled)
      key == "dataset_checksum" -> Validation.checksum?(value)
      true -> is_integer(value) && value >= 0
    end
  end

  defp safe?(_), do: false
end
