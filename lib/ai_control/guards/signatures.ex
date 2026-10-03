defmodule AiControl.Guards.Signatures do
  @moduledoc "Versioned invocation signatures; findings indicate patterns, never proof of execution."
  @behaviour AiControl.Gateway.Guard

  alias AiControl.Guards.{Finding, Registry}

  @impl true
  def assess(fields, _context, _snapshot, _config) do
    always = fn _, _, _ -> true end

    Finding.scan(fields, "signatures", "exploit", [
      {"exploit.pickle.v1", ~r/\bpickle\s*\.\s*loads?\s*\([^\n]{0,1024}/, always},
      {"exploit.yaml.v1", ~r/\byaml\s*\.\s*load\s*\([^\n)]{0,1024}\)?/,
       fn value, _, _ -> !Regex.match?(~r/Loader\s*=\s*(?:yaml\.)?(?:C?SafeLoader)\b/, value) end},
      {"exploit.eval.v1", ~r/(?<![\w.])(?:eval|exec)\s*\([^\n]{0,1024}/, always},
      {"exploit.shell.v1",
       ~r/\b(?:os\s*\.\s*system\s*\([^\n]{0,1024}|subprocess\s*\.\s*(?:run|call|Popen|check_output|check_call)\s*\([^\n]{0,1024}?\bshell\s*=\s*True\b)/,
       always}
    ])
  end

  @impl true
  def ready?(_), do: Registry.valid?()
end
