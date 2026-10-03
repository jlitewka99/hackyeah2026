defmodule AiControl.Tools.Resources do
  @moduledoc "Exact operator resource grants intersect with policy operation grants; deny by default."
  import Bitwise, only: [bsl: 2, bsr: 2]

  alias AiControl.Tools.ToolRequest

  # Conservative IANA special-purpose ranges, pinned 2026-10-04. Anycast exceptions
  # inside these blocks are intentionally denied. See docs/tools.md for sources.
  @blocked_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 3}
  ]
  @blocked_v6 [
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    {{0x3FFF, 0, 0, 0, 0, 0, 0, 0}, 20}
  ]

  def authorize(%ToolRequest{tool: tool, arguments: args}, grant, files) do
    case tool do
      file when file in ~w(file.read file.write file.delete) ->
        path(args["path"], grant, files)

      "http.get" ->
        endpoint(args["url"], grant)

      "database.select" ->
        select(args["table"], grant)

      "email.send" ->
        email(args, grant)

      "command.run" ->
        command(args, grant)
    end
  end

  @doc "Canonical relative virtual paths only; never expand home or host filesystem paths."
  def canonical_path?(path) when is_binary(path) do
    String.valid?(path) && byte_size(path) in 1..1_024 &&
      !Regex.match?(~r/[\\\x00-\x1f\x7f%:~]/u, path) &&
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  def canonical_path?(_), do: false

  defp path(path, grant, files) do
    if canonical_path?(path) && path in Map.get(grant, :paths, []) &&
         !symlink?(path, files),
       do: {:ok, path},
       else: denied()
  end

  defp symlink?(path, files) do
    path
    |> String.split("/")
    |> Enum.scan(fn segment, prefix -> prefix <> "/" <> segment end)
    |> Enum.any?(&match?({:symlink, _}, Map.get(files, &1)))
  end

  defp select(table, grant) do
    if Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, table) &&
         table in Map.get(grant, :tables, []),
       do: {:ok, table},
       else: denied()
  end

  defp email(args, grant) do
    recipient = args["recipient"]

    if Regex.match?(
         ~r/\A[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9]+(?:[.-][a-zA-Z0-9]+)*\z/,
         recipient
       ) &&
         !Regex.match?(~r/[\x00-\x1f\x7f]/, args["subject"]) &&
         recipient in Map.get(grant, :recipients, []),
       do: {:ok, recipient},
       else: denied()
  end

  defp command(args, grant) do
    command = args["command"]
    arguments = args["arguments"]

    valid? =
      case {command, arguments} do
        {"status", []} -> true
        {"echo", [text]} -> !Regex.match?(~r/[\x00-\x1f\x7f]/, text)
        _ -> false
      end

    if valid? && command in Map.get(grant, :commands, []),
      do: {:ok, command},
      else: denied()
  end

  defp endpoint(url, grant) do
    with %{ip: ip} = endpoint <- Map.get(Map.get(grant, :endpoints, %{}), url),
         %URI{} = uri <- URI.parse(url),
         true <- valid_uri?(uri),
         true <- public_ip?(ip) || (valid_ip?(ip) && endpoint[:allow_private?] == true),
         true <- literal_matches?(uri.host, ip) do
      {:ok, %{uri: uri, ip: ip}}
    else
      _ -> denied()
    end
  rescue
    _ -> denied()
  end

  defp valid_uri?(uri) do
    uri.scheme in ["http", "https"] && is_binary(uri.host) &&
      uri.port in 1..65_535 && is_nil(uri.userinfo) && is_nil(uri.fragment) &&
      is_nil(uri.query) && valid_host?(uri.host) && canonical_authority?(uri) &&
      canonical_url_path?(uri.path)
  end

  defp canonical_authority?(uri) do
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
    uri.authority in [host, "#{host}:#{uri.port}"]
  end

  defp valid_host?(host),
    do:
      Regex.match?(~r/\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z/, host) ||
        match?({:ok, _}, :inet.parse_ipv6strict_address(String.to_charlist(host)))

  defp canonical_url_path?(nil), do: true

  defp canonical_url_path?("/" <> path), do: path == "" || canonical_path?(path)

  defp canonical_url_path?(_), do: false

  defp literal_matches?(host, ip) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, literal} -> literal == ip
      _ -> !Regex.match?(~r/\A[0-9.]+\z/, host)
    end
  end

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 4,
    do: ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) && &1 in 0..255))

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) && &1 in 0..65_535))

  defp valid_ip?(_), do: false

  @doc "Only globally routable unicast ranges; IPv4-mapped IPv6 uses IPv4 rules."
  def public_ip?({0, 0, 0, 0, 0, 65_535, high, low}) when high in 0..65_535 and low in 0..65_535,
    do: public_ip?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})

  def public_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 4,
    do: valid_ip?(ip) && !Enum.any?(@blocked_v4, &prefix?(ip, &1, 8))

  def public_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 8,
    do:
      valid_ip?(ip) && prefix?(ip, {{0x2000, 0, 0, 0, 0, 0, 0, 0}, 3}, 16) &&
        !Enum.any?(@blocked_v6, &prefix?(ip, &1, 16))

  def public_ip?(_), do: false

  defp prefix?(ip, {network, prefix_bits}, segment_bits) do
    shift = tuple_size(ip) * segment_bits - prefix_bits
    bsr(ip_integer(ip, segment_bits), shift) == bsr(ip_integer(network, segment_bits), shift)
  end

  defp ip_integer(ip, segment_bits),
    do:
      ip
      |> Tuple.to_list()
      |> Enum.reduce(0, fn segment, acc -> bsl(acc, segment_bits) + segment end)

  defp denied, do: {:error, :tool_resource_not_allowed}
end
