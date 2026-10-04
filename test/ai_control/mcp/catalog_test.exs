defmodule AiControl.MCP.CatalogTest do
  use AiControl.DataCase, async: false

  import AiControl.MCPFixtures
  import AiControl.ToolsFixtures
  import Phoenix.ConnTest, only: [json_response: 2]

  alias AiControl.Tools
  alias AiControl.Tools.{Discovery, Sandbox}

  setup do
    tool_fixture(
      files: %{
        "report.txt" => "private-content",
        "hidden.txt" => "hidden-content",
        "link" => {:symlink, "report.txt"},
        "link/child" => "symlink-content"
      }
    )
  end

  test "discovery intersects policy, grants, context and existing resources without content", c do
    assert {:ok, catalog} = Tools.catalog(c.principal)

    assert Enum.map(catalog.tools, & &1["name"]) ==
             ~w(command.run database.select email.send file.delete file.read file.write)

    assert catalog.resources == [%{path: "report.txt", uri: Discovery.uri("report.txt")}]
    refute inspect(catalog) =~ "private-content"
    refute inspect(catalog) =~ "hidden.txt"
    refute inspect(catalog) =~ "hidden-content"

    activate_tools(c.scope, %{"tools" => %{"allowed_tools" => ["command.run"]}})

    assert {:ok, %{tools: [%{"name" => "command.run"}], resources: []}} =
             Tools.catalog(c.principal)

    :sys.replace_state(c.sandbox, &%{&1 | contexts: %{}})
    assert {:ok, %{tools: [], resources: []}} = Tools.catalog(c.principal)
  end

  test "invalid grants and symlinks never become discoverable", c do
    :sys.replace_state(c.sandbox, fn state ->
      %{
        state
        | grants: %{
            c.agent.id => %{
              paths: ["link", "link/child", "../secret"],
              commands: ["sh"],
              tables: ["users;DELETE"],
              recipients: ["a@example.com\nBcc:x"]
            }
          }
      }
    end)

    assert {:ok, %{tools: [], resources: []}} = Tools.catalog(c.principal)
    assert Sandbox.inspect_state(c.sandbox).files["hidden.txt"] == "hidden-content"
  end

  test "file writes appear in a fresh resource listing without revealing file text", c do
    session = initialize(c)

    assert request(
             c,
             session,
             tool_message("file.write", %{"path" => "copy.txt", "content" => "new-private"})
           )
           |> json_response(200)
           |> get_in(["result", "isError"]) == false

    result = request(c, session, message("resources/list", %{}, 3)) |> json_response(200)
    assert Enum.any?(result["result"]["resources"], &(&1["uri"] == Discovery.uri("copy.txt")))
    refute Jason.encode!(result) =~ "new-private"
  end

  test "resource pagination cursors bind session and policy and reject tampering", c do
    files = Map.new(1..105, &{"docs/file-#{&1}.txt", "synthetic"})

    :sys.replace_state(c.sandbox, fn state ->
      %{state | files: files, grants: %{c.agent.id => %{paths: Map.keys(files)}}}
    end)

    session = initialize(c)
    first = request(c, session, message("resources/list")) |> json_response(200)
    assert length(first["result"]["resources"]) == 100
    cursor = first["result"]["nextCursor"]

    second =
      request(c, session, message("resources/list", %{"cursor" => cursor}, 2))
      |> json_response(200)

    assert length(second["result"]["resources"]) == 5
    refute Map.has_key?(second["result"], "nextCursor")
    all = first["result"]["resources"] ++ second["result"]["resources"]
    assert length(Enum.uniq_by(all, & &1["uri"])) == 105

    other_session = initialize(c)

    for {session, cursor} <- [{other_session, cursor}, {session, cursor <> "tampered"}] do
      response =
        request(c, session, message("resources/list", %{"cursor" => cursor}, 3))
        |> json_response(200)

      assert response["error"]["data"]["code"] == "invalid_cursor"
    end

    activate_tools(c.scope, %{"tools" => %{"allowed_tools" => []}})

    response =
      request(c, session, message("resources/list", %{"cursor" => cursor}, 4))
      |> json_response(200)

    assert response["error"]["data"]["code"] == "invalid_cursor"
  end
end
