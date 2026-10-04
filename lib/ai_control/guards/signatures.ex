defmodule AiControl.Guards.Signatures do
  @moduledoc "Versioned invocation signatures; findings indicate patterns, never proof of execution."
  @behaviour AiControl.Gateway.Guard

  alias AiControl.Guards.Feeds
  alias AiControl.Guards.{Finding, Registry}

  @impl true
  def assess(fields, context, snapshot, _config) do
    set =
      if snapshot,
        do: get_in(snapshot.settings || %{}, ["detector_sets", "signatures"]) || "builtin.v1",
        else: "builtin.v1"

    org = if context, do: context.organization_id

    with {:ok, detectors} <- Feeds.detectors(org, set) do
      if set == "builtin.v1",
        do: Finding.scan(fields, "signatures", "exploit", detectors),
        else: Finding.scan_bounded(fields, "signatures", "exploit", detectors)
    end
  end

  def builtin_detectors do
    always = fn _, _, _ -> true end

    [
      {"exploit.pickle.v1", ~r/\bpickle\s*\.\s*loads?\s*\([^\n]{0,1024}/, always},
      {"exploit.yaml.v1", ~r/\byaml\s*\.\s*load\s*\([^\n)]{0,1024}\)?/,
       fn value, _, _ -> !Regex.match?(~r/Loader\s*=\s*(?:yaml\.)?(?:C?SafeLoader)\b/, value) end},
      {"exploit.eval.v1", ~r/(?<![\w.])(?:eval|exec)\s*\([^\n]{0,1024}/, always},
      {"exploit.shell.v1",
       ~r/\b(?:os\s*\.\s*system\s*\([^\n]{0,1024}|subprocess\s*\.\s*(?:run|call|Popen|check_output|check_call)\s*\([^\n]{0,1024}?\bshell\s*=\s*True\b)/,
       always}
    ]
  end

  @impl true
  def ready?(_), do: Registry.valid?()
end
