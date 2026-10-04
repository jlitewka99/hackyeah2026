defmodule AiControl.Tools.Sandbox do
  @moduledoc """
  Explicitly started, tenant-bound demo adapters for trusted local callers.

  Files and tables are virtual, email stays in this process, and commands are
  Elixir functions. No host files, SQL, shell, or SMTP are reachable. HTTP alone
  performs I/O to exact operator-pinned endpoints. The API uses prepared execution
  through the full firewall. run/3 remains a trusted local adapter aid.
  """
  use GenServer

  alias AiControl.Tools
  alias AiControl.Tools.{Discovery, Executions, HTTP, Resources}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def preflight(server, request), do: GenServer.call(server, {:preflight, request})

  def catalog(server, identity, policy), do: GenServer.call(server, {:catalog, identity, policy})

  def run_prepared(server, request, receipt, owner, deadline) do
    GenServer.call(server, {:run_prepared, request, receipt, owner, deadline}, 15_000)
  end

  def run(server, identity, params) do
    with {:ok, request} <- Tools.prepare(identity, params) do
      GenServer.call(server, {:run, request}, 10_000)
    end
  end

  @doc "Local demo inspection only. Contains synthetic sandbox content."
  def inspect_state(server), do: GenServer.call(server, :inspect_state)

  @impl true
  def init(opts) do
    {:ok,
     %{
       organization_id: Keyword.fetch!(opts, :organization_id),
       grants: Keyword.get(opts, :grants, %{}),
       contexts: Keyword.get(opts, :contexts, %{}),
       files: Keyword.get(opts, :files, %{}),
       tables: Keyword.get(opts, :tables, %{}),
       mailbox: []
     }}
  end

  @impl true
  def handle_call(:inspect_state, _from, state), do: {:reply, state, state}

  def handle_call({:catalog, identity, policy}, _from, state),
    do: {:reply, Discovery.catalog(identity, policy, state), state}

  def handle_call({:preflight, request}, _from, state) do
    result =
      with {:ok, _} <- target(request, state),
           {:ok, workflow} <- Ecto.UUID.cast(Map.get(state.contexts, request.agent_id)) do
        {:ok,
         %{
           workflow_id: workflow,
           grant: Map.get(state.grants, request.agent_id, %{}),
           files: state.files
         }}
      else
        :error -> {:error, :tool_not_allowed}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:run_prepared, request, receipt, owner, deadline}, _from, state) do
    ref = Process.monitor(owner)

    result =
      with :ok <- owner_ready(ref, owner, deadline),
           true <- Map.get(state.contexts, request.agent_id) == receipt.workflow_id,
           {:ok, target} <- target(request, state),
           :ok <- owner_ready(ref, owner, deadline),
           {:ok, _} <- Executions.dispatch(receipt, request),
           :ok <- owner_ready(ref, owner, deadline) do
        execute(request.tool, request.arguments, target, state)
      else
        false -> {{:error, :tool_not_allowed}, state}
        error -> {error, state}
      end

    Process.demonitor(ref, [:flush])
    {reply, updated} = result
    {:reply, reply, updated}
  end

  def handle_call({:run, request}, _from, state) do
    with true <- request.organization_id == state.organization_id,
         :ok <- Tools.authorize(request),
         grant = Map.get(state.grants, request.agent_id, %{}),
         {:ok, target} <- Resources.authorize(request, grant, state.files) do
      {result, updated} = execute(request.tool, request.arguments, target, state)
      {:reply, result, updated}
    else
      false -> {:reply, {:error, :forbidden}, state}
      error -> {:reply, error, state}
    end
  end

  defp owner_ready(ref, owner, deadline) do
    receive do
      {:DOWN, ^ref, :process, _, _} -> {:error, :tool_cancelled}
    after
      0 ->
        cond do
          !Process.alive?(owner) -> {:error, :tool_cancelled}
          System.monotonic_time(:millisecond) >= deadline -> {:error, :tool_timeout}
          true -> :ok
        end
    end
  end

  defp target(request, state) do
    with true <- request.organization_id == state.organization_id,
         :ok <- Tools.authorize(request),
         grant = Map.get(state.grants, request.agent_id, %{}),
         {:ok, target} <- Resources.authorize(request, grant, state.files) do
      {:ok, target}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp execute("file.read", _, path, state) do
    result =
      case Map.fetch(state.files, path) do
        {:ok, content} when is_binary(content) -> {:ok, %{"content" => content}}
        _ -> {:error, :tool_resource_not_found}
      end

    {result, state}
  end

  defp execute("file.write", args, path, state),
    do:
      {{:ok, %{"written" => true}}, %{state | files: Map.put(state.files, path, args["content"])}}

  defp execute("file.delete", _, path, state) do
    if Map.has_key?(state.files, path),
      do: {{:ok, %{"deleted" => true}}, %{state | files: Map.delete(state.files, path)}},
      else: {{:error, :tool_resource_not_found}, state}
  end

  defp execute("http.get", _, endpoint, state), do: {HTTP.get(endpoint), state}

  defp execute("database.select", args, table, state) do
    case Map.fetch(state.tables, table) do
      {:ok, rows} -> {{:ok, %{"rows" => Enum.take(rows, args["limit"])}}, state}
      _ -> {{:error, :tool_resource_not_found}, state}
    end
  end

  defp execute("email.send", args, recipient, state) do
    message = %{"recipient" => recipient, "subject" => args["subject"], "body" => args["body"]}
    {{:ok, %{"queued_locally" => true}}, %{state | mailbox: [message | state.mailbox]}}
  end

  defp execute("command.run", _, "status", state),
    do: {{:ok, %{"output" => "sandbox ready"}}, state}

  defp execute("command.run", args, "echo", state),
    do: {{:ok, %{"output" => hd(args["arguments"])}}, state}
end
