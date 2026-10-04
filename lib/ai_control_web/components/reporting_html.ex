defmodule AiControlWeb.ReportingHTML do
  @moduledoc "Small reporting primitives in the incumbent workspace design."
  use AiControlWeb, :html

  alias AiControl.Audit.Filters

  def ok?({:ok, _}), do: true
  def ok?(_), do: false
  def value({:ok, value}), do: value
  def time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M:%S UTC")
  def time(_), do: "Not recorded"
  def short(nil), do: "Not recorded"
  def short(id), do: String.slice(id, 0, 8)
  def label(value) when is_atom(value), do: label(to_string(value))
  def label("pii"), do: "PII"
  def label("ner"), do: "NER"
  def label(value), do: value |> String.replace("_", " ") |> String.capitalize()
  def latency(us), do: "#{Float.round(us / 1000, 2)} ms"
  def timing_label("request"), do: "Gateway total"
  def timing_label("upstream"), do: "Upstream call"

  def timing_label("guard." <> rest),
    do: rest |> String.split(".") |> Enum.map_join(" · ", &label/1)

  def timing_label(key), do: label(key)
  def cost(nil), do: "Unavailable"
  def cost(value), do: Decimal.to_string(value, :normal)
  def limit(nil), do: "No limit"
  def limit(value), do: to_string(value)
  def filter_params(filters), do: Filters.params(filters)

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :detailed, :boolean, default: false

  def filters(assigns) do
    ~H"""
    <.form for={@form} id={@id} phx-submit="filter" class="report-filters">
      <.input
        field={@form[:range]}
        type="select"
        label="Time range"
        options={[
          {"Last hour", "1h"},
          {"Last 24 hours", "24h"},
          {"Last 7 days", "7d"},
          {"Custom UTC range", "custom"}
        ]}
      />
      <.input field={@form[:from]} type="datetime-local" label="From (UTC, custom only)" />
      <.input field={@form[:to]} type="datetime-local" label="Until (UTC, exclusive)" />
      <%= if @detailed do %>
        <.input
          field={@form[:kind]}
          type="select"
          label="Event kind"
          prompt="All kinds"
          options={[
            {"Decision", "decision"},
            {"Gateway", "gateway"},
            {"Administrative", "administrative"}
          ]}
        />
        <.input
          field={@form[:action]}
          type="select"
          label="Decision action"
          prompt="All actions"
          options={~w(allow redact block)}
        />
        <.input
          field={@form[:stage]}
          type="select"
          label="Stage"
          prompt="All stages"
          options={~w(input output administrative)}
        />
        <.input
          field={@form[:guard]}
          type="select"
          label="Guard"
          prompt="All guards"
          options={AiControl.Policies.Configuration.guards(6)}
        />
        <.input field={@form[:agent_id]} type="text" label="Agent ID" placeholder="Agent UUID" />
        <.input
          field={@form[:reason_code]}
          type="text"
          label="Reason code"
          placeholder="e.g. policy_blocked"
          maxlength="96"
        />
        <.input field={@form[:request_id]} type="text" label="Request ID" placeholder="Request UUID" />
        <.input field={@form[:run_id]} type="text" label="Workflow ID" placeholder="Run UUID" />
      <% end %>
      <button
        id={"#{@id}-apply"}
        type="submit"
        class="button-secondary"
        phx-disable-with="Applying…"
      >Apply filters</button>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :event, :any, required: true
  attr :organization_id, :string, required: true

  def event_row(assigns) do
    ~H"""
    <div id={@id} class="event-row">
      <div class="min-w-0">
        <.link
          navigate={~p"/organizations/#{@organization_id}/events/#{@event.id}"}
          class="text-link"
          id={"open-#{@id}"}
        >{@event.event_type}</.link>
        <p class="muted text-sm">{time(@event.occurred_at)}</p>
        <p class="resource-identifier muted">
          Request {short(@event.request_id)} · {@event.stage} · Agent {short(@event.agent_id)}
        </p>
      </div>
      <div class="event-outcome">
        <span class="decision-state" data-action={@event.action}>{if @event.action,
          do: label(@event.action),
          else: Enum.join(@event.reason_codes, ", ")}</span>
        <p :if={@event.policy_version} class="resource-identifier muted">
          {short(String.replace_prefix(@event.policy_version, "policy-", ""))}
        </p>
      </div>
    </div>
    """
  end

  attr :scope, :any, required: true
  attr :id, :string, required: true

  def related_links(assigns) do
    ~H"""
    <nav id={@id} class="report-links" aria-label="Related reporting">
      <.link
        :if={"events.read" in @scope.grants.permissions}
        navigate={~p"/organizations/#{@scope.organization.id}/events"}
        class="text-link"
      >Events</.link>
      <.link
        :if={"budgets.read" in @scope.grants.permissions}
        navigate={~p"/organizations/#{@scope.organization.id}/budgets"}
        class="text-link"
      >Budget usage</.link>
      <.link
        :if={"signatures.read" in @scope.grants.permissions}
        navigate={~p"/organizations/#{@scope.organization.id}/signatures"}
        class="text-link"
      >Signatures</.link>
      <.link
        :if={"policies.read" in @scope.grants.permissions}
        navigate={~p"/organizations/#{@scope.organization.id}/policies"}
        class="text-link"
      >Policy configuration</.link>
    </nav>
    """
  end
end
