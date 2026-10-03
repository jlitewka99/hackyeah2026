defmodule AiControl.Tools.ResourcesTest do
  use ExUnit.Case, async: true

  alias AiControl.Tools.{Catalog, Resources, ToolRequest}

  test "paths are canonical relative names with exact grants" do
    grant = %{paths: ["documents/report.txt", "documents/report.txt.bak"]}

    assert {:ok, "documents/report.txt"} =
             authorize("file.read", %{"path" => "documents/report.txt"}, grant)

    for path <- [
          "~/.ssh/id_rsa",
          "/etc/passwd",
          "../report.txt",
          "documents/../report.txt",
          "documents//report.txt",
          "documents/./report.txt",
          "documents/report.txt/",
          "documents\\report.txt",
          "documents/%2e%2e/report.txt",
          "C:/report.txt",
          "documents/report.txt\0",
          "documents/report.txt\n",
          "other/report.txt"
        ] do
      assert {:error, :tool_resource_not_allowed} =
               authorize("file.read", %{"path" => path}, grant)
    end

    assert {:error, :tool_resource_not_allowed} =
             authorize("file.read", %{"path" => "documents/report.txt"}, %{})

    refute Resources.canonical_path?(<<255>>)
  end

  test "symlinks on leaf and any ancestor never resolve" do
    files = %{"link" => {:symlink, "/etc"}, "documents/key" => {:symlink, "~/.ssh/id_rsa"}}
    grant = %{paths: ["link/passwd", "documents/key"]}

    for operation <- ~w(file.read file.write file.delete), path <- grant.paths do
      assert {:error, :tool_resource_not_allowed} =
               authorize(operation, %{"path" => path}, grant, files)
    end
  end

  test "database validates exact table and bounded structured operation" do
    assert {:ok, "reports"} =
             authorize("database.select", %{"table" => "reports"}, %{tables: ["reports"]})

    for table <- ["users", "reports; DROP TABLE users", "public.reports", "REPORTS"] do
      assert {:error, :tool_resource_not_allowed} =
               authorize("database.select", %{"table" => table}, %{tables: ["reports"]})
    end

    for limit <- [0, 101, 1.0, "1"] do
      assert {:error, :invalid_tool_arguments} =
               Catalog.validate("database.select", %{"table" => "reports", "limit" => limit})
    end
  end

  test "email accepts only a single exact recipient and rejects header injection" do
    grant = %{recipients: ["reviewer@demo.invalid"]}
    args = %{"recipient" => "reviewer@demo.invalid", "subject" => "Review", "body" => "Example"}
    assert {:ok, _} = authorize("email.send", args, grant)

    for recipient <- [
          "attacker@demo.invalid",
          "Name <reviewer@demo.invalid>",
          "reviewer@demo.invalid,attacker@demo.invalid",
          "reviewer@demo.invalid\r\nBcc:attacker@demo.invalid"
        ] do
      assert {:error, :tool_resource_not_allowed} =
               authorize("email.send", %{args | "recipient" => recipient}, grant)
    end

    assert {:error, :tool_resource_not_allowed} =
             authorize("email.send", %{args | "subject" => "Review\r\nBcc: attacker"}, grant)
  end

  test "commands use a closed function set and validated arguments" do
    grant = %{commands: ["status", "echo", "sh"]}

    assert {:ok, "status"} =
             authorize("command.run", %{"command" => "status", "arguments" => []}, grant)

    assert {:ok, "echo"} =
             authorize(
               "command.run",
               %{"command" => "echo", "arguments" => ["$(rm -rf /)"]},
               grant
             )

    for {command, arguments} <- [
          {"sh", ["-c"]},
          {"status; rm", []},
          {"status", ["extra"]},
          {"echo", []},
          {"echo", ["a\n"]}
        ] do
      assert {:error, :tool_resource_not_allowed} =
               authorize("command.run", %{"command" => command, "arguments" => arguments}, grant)
    end
  end

  test "HTTP accepts exact URL and pinned public IP; private demo requires exception" do
    url = "https://example.com/report"
    grant = %{endpoints: %{url => %{ip: {93, 184, 216, 34}}}}
    assert {:ok, %{ip: {93, 184, 216, 34}}} = authorize("http.get", %{"url" => url}, grant)

    for changed <- [
          "https://example.com.evil/report",
          url <> "?secret=value",
          url <> "/extra",
          "http://example.com/report"
        ] do
      assert {:error, :tool_resource_not_allowed} =
               authorize("http.get", %{"url" => changed}, grant)
    end

    private = %{endpoints: %{url => %{ip: {127, 0, 0, 1}}}}
    assert {:error, :tool_resource_not_allowed} = authorize("http.get", %{"url" => url}, private)

    assert {:ok, _} =
             authorize("http.get", %{"url" => url}, %{
               endpoints: %{url => %{ip: {127, 0, 0, 1}, allow_private?: true}}
             })
  end

  test "even operator entries reject ambiguous URLs, credentials and IP mismatches" do
    for url <- [
          "file:///etc/passwd",
          "http://user:pass@example.com/",
          "http://example.com/#secret",
          "http://example.com/a/../b",
          "http://example.com/%2e%2e",
          "http://2130706433/",
          "http://127.1/",
          "http://example.com/?token=secret",
          "http://[fe80::1%25en0]/"
        ] do
      grant = %{endpoints: %{url => %{ip: {93, 184, 216, 34}}}}
      assert {:error, :tool_resource_not_allowed} = authorize("http.get", %{"url" => url}, grant)
    end

    url = "http://127.0.0.1/report"
    grant = %{endpoints: %{url => %{ip: {93, 184, 216, 34}}}}
    assert {:error, :tool_resource_not_allowed} = authorize("http.get", %{"url" => url}, grant)
  end

  test "SSRF address ranges cover IPv4, IPv6 and mapped IPv4" do
    for ip <- [
          {0, 0, 0, 0},
          {10, 1, 2, 3},
          {100, 64, 0, 1},
          {127, 0, 0, 1},
          {169, 254, 169, 254},
          {172, 31, 0, 1},
          {192, 168, 1, 1},
          {192, 0, 2, 1},
          {198, 18, 0, 1},
          {198, 51, 100, 1},
          {203, 0, 113, 1},
          {224, 0, 0, 1},
          {255, 255, 255, 255},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1},
          {0xFF00, 0, 0, 0, 0, 0, 0, 1},
          {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
          {0x2002, 0x7F00, 1, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 65_535, 0x7F00, 1},
          {256, 0, 0, 1},
          {0x2000, 0, 0, 0, 0, 0, 0, 65_536},
          nil
        ] do
      refute Resources.public_ip?(ip)
    end

    assert Resources.public_ip?({8, 8, 8, 8})
    assert Resources.public_ip?({0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111})
  end

  defp authorize(tool, arguments, grant, files \\ %{}) do
    request = %ToolRequest{
      request_id: nil,
      organization_id: nil,
      agent_id: nil,
      api_key_id: nil,
      tool: tool,
      arguments: arguments,
      policy: nil
    }

    Resources.authorize(request, grant, files)
  end
end
