defmodule AiControl.Policies.YAML do
  @moduledoc "Bounded YAML subset: one document, scalar string keys, no aliases or custom tags."
  alias AiControl.Policies.Configuration

  def decode(text) when is_binary(text) and byte_size(text) <= 65_536 do
    with true <- String.valid?(text),
         :ok <- scan(text),
         [{:yamerl_doc, tree}] <-
           :yamerl_constr.string(text,
             detailed_constr: true,
             str_node_as_binary: true,
             keep_duplicate_keys: true
           ),
         :ok <- unique_keys(tree),
         {:ok, [source]} <- YamlElixir.read_all_from_string(text, atoms: false),
         {:ok, %{source: source}} <- Configuration.validate(source) do
      {:ok, source}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      _ -> {:error, [{"yaml", "use one valid policy document with unique string keys"}]}
    end
  rescue
    _ -> {:error, [{"yaml", "use one valid policy document"}]}
  catch
    :throw, :unsupported_yaml ->
      {:error, [{"yaml", "aliases, anchors and explicit tags are not supported"}]}

    :throw, :duplicate_key ->
      {:error, [{"yaml", "keys must be unique within each mapping"}]}

    :throw, :invalid_key ->
      {:error, [{"yaml", "mapping keys must be strings"}]}

    _, _ ->
      {:error, [{"yaml", "use one valid policy document"}]}
  end

  def decode(_), do: {:error, [{"yaml", "must be valid UTF-8 and at most 64 KiB"}]}

  # JSON is a YAML 1.2 subset, preserving every scalar and avoiding ambiguous quoting.
  def encode(source), do: Jason.encode!(source, pretty: true) <> "\n"

  defp scan(text) do
    :yamerl_parser.string(String.to_charlist(text), token_fun: &token/1)
    :ok
  end

  defp token(token) do
    if elem(token, 0) in [:yamerl_alias, :yamerl_anchor, :yamerl_tag, :yamerl_tag_directive],
      do: throw(:unsupported_yaml)

    :ok
  end

  defp unique_keys({:yamerl_map, _, _, _, entries}) do
    keys = Enum.map(entries, fn {key, _} -> key end)

    names =
      Enum.map(keys, fn
        {:yamerl_str, _, _, _, name} -> name
        _ -> throw(:invalid_key)
      end)

    if length(Enum.uniq(names)) != length(names), do: throw(:duplicate_key)
    Enum.each(entries, fn {_, entry} -> unique_keys(entry) end)
    :ok
  end

  defp unique_keys({:yamerl_seq, _, _, _, entries, _}) do
    Enum.each(entries, &unique_keys/1)
    :ok
  end

  defp unique_keys(_), do: :ok
end
