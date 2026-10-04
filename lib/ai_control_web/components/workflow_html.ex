defmodule AiControlWeb.WorkflowHTML do
  @moduledoc "Fixed human-readable execution states and units."
  def status("running"), do: "Running"
  def status("completed"), do: "Completed"
  def status("stopped"), do: "Stopped"
  def status("limit_exceeded"), do: "Limit exceeded"
  def status("interrupted"), do: "Interrupted"
  def reason("max_duration_seconds"), do: "The execution deadline was reached."
  def reason("max_calls"), do: "The shared operation limit was exceeded."
  def reason("max_tokens"), do: "The shared token budget was exceeded."
  def reason("tool_calls"), do: "The shared tool-call limit was exceeded."
  def reason("max_delegation_depth"), do: "The maximum delegation depth was exceeded."
  def reason("max_repeated_actions"), do: "The same action was requested too many times."

  def reason("process_interrupted"),
    do: "The execution process was lost. Start a new run to continue."

  def reason(_), do: nil

  def remaining(run),
    do:
      if(run.status == "running",
        do: max(0, DateTime.diff(run.deadline, AiControl.Workflows.now())),
        else: 0
      )
end
