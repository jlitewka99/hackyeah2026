defmodule AiControl.ApprovalsFixtures do
  @moduledoc false
  import AiControl.WorkflowsFixtures

  alias AiControl.{Approvals, Gateway, Policies, Repo, Tools}
  alias AiControl.Approvals.Approval
  alias AiControl.Gateway.Config

  def review_policy(scope, overrides \\ %{}, limits \\ %{}) do
    activate_workflows(
      scope,
      limits,
      Map.merge(
        %{
          "schema_version" => 6,
          "review" => %{
            "enabled" => true,
            "tools" => ["file.write", "file.read", "email.send"],
            "llm_models" => ["deepseek-flash"],
            "delegation_agents" => ["*"]
          }
        },
        overrides
      )
    )
  end

  def approval_fixture do
    c = workflow_fixture(%{"max_duration_seconds" => 3600})
    review_policy(c.scope, %{}, %{"max_duration_seconds" => 3600})
    {:ok, policy, _} = Policies.snapshot_for_models(c.principal, nil)
    Map.merge(c, %{policy: policy, key: Ecto.UUID.generate()})
  end

  def write_payload(content \\ "Synthetic private approval payload <script>alert(1)</script>"),
    do: %{"tool" => "file.write", "arguments" => %{"path" => "copy.txt", "content" => content}}

  def review_call(c, params \\ write_payload(), extra \\ []),
    do:
      Tools.execute(
        c.principal,
        params,
        Keyword.merge([run_context: c.reference, idempotency_key: c.key], extra)
      )

  def pending(c, params \\ write_payload()) do
    {:error, {:approval_required, %{approval_id: id}}} = review_call(c, params)
    Repo.get!(Approval, id)
  end

  def approve(c, record) do
    {:ok, result} = Approvals.decide(c.scope, record.id, :approve, record.revision)
    result
  end

  def stub_model do
    old = Application.fetch_env!(:ai_control, Config)

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.put(:http_plug, {Req.Test, __MODULE__})
      |> Keyword.put(:tokenizer, AiControl.TestBudgetTokenizer)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    parent = self()

    Req.Test.stub(__MODULE__, &model_response(&1, parent))
  end

  defp model_response(%{request_path: "/models"} = conn, _),
    do: Req.Test.json(conn, %{data: [%{id: "deepseek-flash"}]})

  defp model_response(conn, parent) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = Jason.decode!(body)

    send(parent, {:generated, params})
    Req.Test.json(conn, AiControl.GatewayFixtures.response())
  end

  def chat(c, extra \\ [], params \\ AiControl.GatewayFixtures.request()),
    do:
      Gateway.chat(
        c.principal,
        params,
        Keyword.merge([run_context: c.reference, idempotency_key: c.key], extra)
      )
end
