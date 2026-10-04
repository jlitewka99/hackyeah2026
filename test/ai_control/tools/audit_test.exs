defmodule AiControl.Tools.AuditTest do
  use AiControl.DataCase, async: false

  import AiControl.ToolsFixtures

  alias AiControl.{Audit, Repo}
  alias AiControl.Audit.Event

  test "tool audit rejects inconsistent states and arbitrary content" do
    context = tool_fixture()
    id = Ecto.UUID.generate()

    evidence = %{
      execution_id: Ecto.UUID.generate(),
      workflow_id: context.workflow,
      execution_status: "completed",
      tool: "file.read",
      charged: true
    }

    assert {:ok, event} =
             Audit.record_tool(
               context.principal,
               id,
               "tool.completed",
               "completed",
               1,
               nil,
               evidence
             )

    assert event.target_id == evidence.execution_id

    for bad <- [
          Map.put(evidence, :charged, false),
          Map.put(evidence, :arguments, "private"),
          Map.put(evidence, :tool, "unknown")
        ] do
      assert {:error, :invalid_audit_data} =
               Audit.record_tool(
                 context.principal,
                 id,
                 "tool.completed",
                 "completed",
                 1,
                 nil,
                 bad
               )
    end

    assert {:error, :invalid_audit_data} =
             Audit.record_tool(context.principal, id, "tool.completed", "completed", 1, nil, nil)

    assert {:error, :invalid_audit_data} =
             Audit.record_tool(
               context.principal,
               id,
               "tool.failed",
               "completed",
               1,
               nil,
               evidence
             )

    assert {:error, :invalid_audit_data} =
             Audit.record_tool(
               context.principal,
               id,
               "tool.completed",
               "raw upstream text",
               1,
               nil,
               evidence
             )

    assert Enum.count(Repo.all(Event), &(&1.event_type == "tool.completed")) == 1
  end
end
