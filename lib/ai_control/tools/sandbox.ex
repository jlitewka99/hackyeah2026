defmodule AiControl.Tools.Sandbox do
  @moduledoc """
  Explicitly started, tenant-bound demo adapters for trusted local callers.

  Files and tables are virtual, email stays in this process, and commands are
  Elixir functions. No host files, SQL, shell, or SMTP are reachable. HTTP alone
  performs I/O to exact operator-pinned endpoints. This is not the production
  executor: step 12B must add budgets, guards, audit, and output filtering.
  """
  use GenServer

  alias AiControl.Tools
  alias AiControl.Tools.{HTTP, Resources}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

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
       files: Keyword.get(opts, :files, %{}),
       tables: Keyword.get(opts, :tables, %{}),
       mailbox: []
     }}
  end

  @impl true
  def handle_call(:inspect_state, _from, state), do: {:reply, state, state}

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
