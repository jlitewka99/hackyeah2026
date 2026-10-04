defmodule AiControlWeb.BackgroundHTML do
  use AiControlWeb, :html

  alias AiControl.Background
  alias AiControlWeb.ReportingHTML

  def label("gateway_tests"), do: "Gateway tests"
  def label("benchmark"), do: "Polish semantic benchmark"
  def label("audit_export"), do: "Audit export · JSONL"
  def label("metrics_report"), do: "Metrics report · JSON"
  def label("audit_enrichment"), do: "Audit summary · JSON"
  def label("guard_refresh"), do: "Signature refresh"
  def label(value), do: String.capitalize(value)

  def evidence_label("http_status"), do: "HTTP status"
  def evidence_label(value), do: ReportingHTML.label(value)

  def case_label("snapshot"), do: "Policy snapshot during request"
  def case_label("required_guard"), do: "Required guard unavailable"
  def case_label(value), do: ReportingHTML.label(value)

  def empty_results(run) do
    cond do
      Background.results_expired?(run) ->
        "Scenario results have expired. Run history is retained for 30 days."

      Background.active?(run) ->
        "No scenarios have finished yet."

      run.status == "cancelled" ->
        "This run was cancelled before any scenario results were recorded."

      true ->
        "No scenario results were recorded. Check the run status before starting a new run."
    end
  end

  def downloadable?(run),
    do:
      run.status == "completed" && run.kind != "guard_refresh" && run.expires_at &&
        DateTime.before?(DateTime.utc_now(), run.expires_at)

  def status(run),
    do:
      if(
        run.status == "completed" && run.expires_at &&
          !DateTime.before?(DateTime.utc_now(), run.expires_at),
        do: "Expired",
        else: label(run.status)
      )

  def error("runner_unavailable"),
    do:
      "The runner or required local models are unavailable. Ask an operator to check configuration before running again."

  def error("access_revoked"), do: "Work stopped because access was revoked."

  def error("invalid_feed"),
    do: "The package could not be verified. Ask an operator to check its checksum and rules."

  def error("runner_timeout"),
    do: "The runner reached its time limit. Start a new run after checking the local services."

  def error("cancelled"), do: "This run was cancelled."
  def error(nil), do: nil
  def error(_), do: "Work could not finish. Check availability and submit a new run."

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :scope, :map, required: true

  def row(assigns) do
    ~H"""
    <article id={@id} class="background-row">
      <div class="min-w-0">
        <.link
          :if={@run.kind in ~w(gateway_tests benchmark)}
          navigate={~p"/organizations/#{@scope.organization.id}/tests/#{@run.id}"}
          id={"run-details-#{@run.id}"}
          class="text-link font-medium"
        >{label(@run.kind)}</.link>
        <p :if={@run.kind not in ~w(gateway_tests benchmark)} class="font-medium">
          {label(@run.kind)}
        </p>
        <p class="muted text-sm mt-1">
          {ReportingHTML.time(@run.inserted_at)}
          <span :if={@run.spec["mode"]}>· {label(@run.spec["mode"])}</span>
        </p>
        <p :if={@run.spec["filters"]} class="muted text-sm mt-1">
          {time(@run.spec["filters"]["from"])} — {time(@run.spec["filters"]["to"])}
        </p>
        <p :if={@run.error_code} class="field-error text-sm mt-2">{error(@run.error_code)}</p>
        <dl :if={@run.result["counts"]} class="report-facts mt-2">
          <div :for={{outcome, count} <- Enum.sort(@run.result["counts"])}>
            <dt>{ReportingHTML.label(outcome)}</dt><dd>{count}</dd>
          </div>
        </dl>
        <p :if={@run.result["set_id"]} class="resource-identifier mt-2 break-all">
          Candidate: {@run.result["set_id"]}
        </p>
      </div>
      <div class="background-actions">
        <span id={"run-status-#{@run.id}"} class="status-tag">{status(@run)}</span>
        <span :if={@run.progress > 0 || @run.total > 0} class="muted text-sm tabular-nums">{@run.progress}{if @run.total >
                                                                                                                0,
                                                                                                              do:
                                                                                                                " / #{@run.total}"}</span>
        <.link
          :if={downloadable?(@run)}
          id={"run-download-#{@run.id}"}
          href={~p"/organizations/#{@scope.organization.id}/background/#{@run.id}/download"}
          class="button-secondary"
        ><.icon name="hero-arrow-down-tray" class="size-4" /> Download</.link>
        <button
          :if={
            Background.active?(@run) &&
              Enum.all?(@run.permissions, &(&1 in @scope.grants.permissions))
          }
          id={"run-cancel-#{@run.id}"}
          type="button"
          phx-click="cancel_run"
          phx-value-id={@run.id}
          class="button-secondary"
          phx-disable-with="Cancelling…"
        >Cancel</button>
      </div>
    </article>
    """
  end

  defp time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> ReportingHTML.time(date)
      _ -> "Not recorded"
    end
  end
end
