defmodule AiControl.Repo.Migrations.AddGatewayAuditEvents do
  use Ecto.Migration

  def up do
    drop constraint(:audit_events, :audit_event_kind)
    drop constraint(:audit_events, :audit_decision_fields)

    create constraint(:audit_events, :audit_event_kind,
             check: "kind IN ('decision', 'administrative', 'gateway')"
           )

    create constraint(:audit_events, :audit_decision_fields,
             check:
               "(kind = 'decision' AND stage IN ('input', 'output') AND action IN ('allow', 'redact', 'block') AND action IS NOT NULL AND policy_version IS NOT NULL AND policy_checksum IS NOT NULL) OR (kind = 'administrative' AND stage = 'administrative' AND action IS NULL) OR (kind = 'gateway' AND stage IN ('input', 'output') AND action IS NULL AND ((policy_version IS NULL AND policy_checksum IS NULL) OR (policy_version IS NOT NULL AND policy_checksum IS NOT NULL)))"
           )
  end

  def down do
    # Retain evidence: downgrading requires an operator export/removal of gateway events first.
    drop constraint(:audit_events, :audit_event_kind)
    drop constraint(:audit_events, :audit_decision_fields)

    create constraint(:audit_events, :audit_event_kind,
             check: "kind IN ('decision', 'administrative')"
           )

    create constraint(:audit_events, :audit_decision_fields,
             check:
               "(kind = 'decision' AND stage IN ('input', 'output') AND action IS NOT NULL AND action IN ('allow', 'redact', 'block') AND policy_version IS NOT NULL AND policy_checksum IS NOT NULL) OR (kind = 'administrative' AND stage = 'administrative' AND action IS NULL)"
           )
  end
end
