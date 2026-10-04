defmodule AiControl.WorkflowsFixtures do
  @moduledoc false
  import AiControl.ToolsFixtures

  alias AiControl.{Policies, Workflows}
  alias AiControl.Policies.Configuration
  alias AiControl.Tools.Catalog

  def run_reference_fixture(principal) do
    {:ok, {run, participant}} =
      Workflows.create(
        principal,
        %{"goal" => "Synthetic integration execution"},
        Ecto.UUID.generate()
      )

    cleanup_run(run)
    %{run_id: run.id, participant_id: participant.id}
  end

  def activate_workflows(scope, limits \\ %{}, extra \\ %{}) do
    guards = Map.new(Configuration.guards(5), &{&1, %{"enabled" => false, "required" => false}})

    source =
      Configuration.default(5)
      |> Map.put("guards", guards)
      |> Map.put("tools", %{
        "allowed_tools" => Enum.map(Catalog.all(), & &1["name"])
      })
      |> Map.put("budgets", %{"workflow" => limits})
      |> Map.merge(extra)

    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    version
  end

  def workflow_fixture(limits \\ %{}) do
    context = tool_fixture()
    activate_workflows(context.scope, limits)

    {:ok, {run, participant}} =
      Workflows.create(
        context.principal,
        %{"goal" => "Synthetic demonstration: review a quarterly report"},
        Ecto.UUID.generate()
      )

    {:ok, policy, _} = Policies.snapshot_for_models(context.principal, nil)

    {:ok, reference} =
      Workflows.resolve(context.principal, policy, %{
        run_id: run.id,
        participant_id: participant.id
      })

    cleanup_run(run)

    Map.merge(context, %{run: run, participant: participant, reference: reference, policy: policy})
  end

  defp cleanup_run(run) do
    ExUnit.Callbacks.on_exit(fn ->
      case Registry.lookup(AiControl.Workflows.Registry, {run.organization_id, run.id}) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(AiControl.Workflows.DynamicSupervisor, pid)

        _ ->
          :ok
      end

      :sys.get_state(AiControl.Workflows.Manager)
    end)
  end
end
