defmodule AiControl.Workflows.LiveWorkflowTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.Budgets.Reservation
  alias AiControl.Gateway.Config
  alias AiControl.{Policies, Repo}
  alias AiControl.Policies.Configuration
  alias AiControl.Tools.{Execution, Sandbox}

  @moduletag :live_models
  @moduletag timeout: 240_000

  test "real providers settle a shared v5 run across HTTP tools and own-key delegation" do
    old = Application.fetch_env!(:ai_control, Config)

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.drop([:http_plug, :ner_http_plug, :tokenizer_http_plug, :semantic_http_plug])
      |> Keyword.put(:models, Jason.decode!(File.read!("priv/models/ollama-demo.json")))
      |> Keyword.put(:guards, Config.guard_modules())
      |> Keyword.put(:tokenizer, AiControl.Budgets.Tokenizer)
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)

    scope = organization_fixture()
    owner = agent_fixture(scope)
    target = agent_fixture(scope)
    {_, owner_token} = key_fixture(scope, owner)
    {_, target_token} = key_fixture(scope, target)

    source =
      Configuration.default(5)
      |> Map.put("tools", %{"allowed_tools" => ["file.read"]})
      |> Map.put(
        "guards",
        Map.new(Configuration.guards(5), &{&1, %{"enabled" => true, "required" => true}})
      )

    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)

    start_supervised!(
      {Sandbox,
       name: AiControl.Tools.Config.via(scope.organization.id),
       organization_id: scope.organization.id,
       grants: %{
         owner.id => %{paths: ["report.txt"]},
         target.id => %{paths: ["delegate.txt"]}
       },
       files: %{
         "report.txt" => "Raport: wynik wynosi cztery.",
         "delegate.txt" => "Sprawdzenie: wynik wynosi sześć."
       }}
    )

    server =
      start_supervised!(
        {Bandit, plug: AiControlWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"
    create_key = Ecto.UUID.generate()
    goal = "Synthetic actual-provider workflow acceptance"

    created =
      post_json(base, "/v1/runs", owner_token, %{goal: goal}, 201, [
        {"idempotency-key", create_key}
      ])

    on_exit(fn ->
      case Registry.lookup(
             AiControl.Workflows.Registry,
             {scope.organization.id, created["run_id"]}
           ) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(AiControl.Workflows.DynamicSupervisor, pid)

        _ ->
          :ok
      end

      :sys.get_state(AiControl.Workflows.Manager)
    end)

    assert post_json(base, "/v1/runs", owner_token, %{goal: goal}, 201, [
             {"idempotency-key", create_key}
           ])["run_id"] == created["run_id"]

    path = "/v1/runs/#{created["run_id"]}"
    root_headers = run_headers(created["run_id"], created["participant_id"])

    post_json(base, "/v1/chat/completions", owner_token, chat("Oblicz dwa plus dwa."), 400)

    root_chat =
      post_json(
        base,
        "/v1/chat/completions",
        owner_token,
        chat("Oblicz dwa plus dwa. Odpowiedz krótko po polsku."),
        200,
        root_headers
      )

    assert root_chat["usage"]["total_tokens"] > 0
    read_file(base, owner_token, "report.txt", root_headers, 200)

    child =
      post_json(
        base,
        path <> "/delegations",
        owner_token,
        %{target_agent_id: target.id},
        200,
        root_headers ++ [{"idempotency-key", Ecto.UUID.generate()}]
      )

    assert child["depth"] == 1
    child_headers = run_headers(created["run_id"], child["participant_id"])

    post_json(
      base,
      "/v1/chat/completions",
      target_token,
      chat("Oblicz trzy plus trzy."),
      403,
      root_headers
    )

    child_chat =
      post_json(
        base,
        "/v1/chat/completions",
        target_token,
        chat("Oblicz trzy plus trzy. Odpowiedz krótko po polsku."),
        200,
        child_headers
      )

    read_file(base, target_token, "report.txt", child_headers, 403)
    read_file(base, target_token, "delegate.txt", child_headers, 200)

    run = get_json(base, path, owner_token)

    assert run["tokens"] ==
             root_chat["usage"]["total_tokens"] + child_chat["usage"]["total_tokens"]

    assert run["reserved_tokens"] == 0
    assert run["tool_calls"] == 2
    assert length(run["participants"]) == 2

    delegated = get_json(base, path, target_token)
    assert Enum.map(delegated["participants"], & &1["id"]) == [child["participant_id"]]
    post_json(base, path <> "/complete", target_token, %{}, 403)
    assert post_json(base, path <> "/complete", owner_token, %{}, 200)["status"] == "completed"

    post_json(
      base,
      "/v1/chat/completions",
      target_token,
      chat("Oblicz cztery plus cztery."),
      409,
      child_headers
    )

    reservations = Repo.all(from r in Reservation, where: r.run_id == ^created["run_id"])
    assert length(reservations) == 2
    assert Enum.all?(reservations, &(&1.status == "settled" && &1.input_tokens > 0))

    assert MapSet.new(reservations, & &1.participant_id) ==
             MapSet.new([created["participant_id"], child["participant_id"]])

    executions = Repo.all(from e in Execution, where: e.run_id == ^created["run_id"])
    assert length(executions) == 2
    assert Enum.all?(executions, & &1.charged)
  end

  defp chat(content),
    do: %{model: "qwen3.5:4b", max_tokens: 64, messages: [%{role: "user", content: content}]}

  defp run_headers(run_id, participant_id),
    do: [{"x-run-id", run_id}, {"x-run-participant-id", participant_id}]

  defp read_file(base, token, path, headers, status),
    do:
      post_json(
        base,
        "/v1/tool_calls",
        token,
        %{tool: "file.read", arguments: %{path: path}},
        status,
        headers ++ [{"idempotency-key", Ecto.UUID.generate()}]
      )

  defp post_json(base, path, token, body, status, headers \\ []) do
    response =
      Req.post!(base <> path,
        headers: [{"authorization", "Bearer " <> token} | headers],
        json: body,
        retry: false,
        receive_timeout: 150_000
      )

    assert response.status == status
    response.body
  end

  defp get_json(base, path, token) do
    response =
      Req.get!(base <> path, headers: [{"authorization", "Bearer " <> token}], retry: false)

    assert response.status == 200
    response.body
  end
end
