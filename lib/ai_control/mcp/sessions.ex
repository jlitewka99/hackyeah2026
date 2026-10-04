defmodule AiControl.MCP.Sessions do
  @moduledoc "Bounded, key-bound protocol state for one application instance. No request content is stored."
  use GenServer

  alias AiControl.MCP
  alias AiControl.MCP.Config

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def create(identity, server \\ __MODULE__), do: GenServer.call(server, {:create, identity})

  def fetch(id, identity, server \\ __MODULE__),
    do: GenServer.call(server, {:fetch, id, identity})

  def ready(id, identity, server \\ __MODULE__),
    do: GenServer.call(server, {:ready, id, identity})

  def delete(id, identity, server \\ __MODULE__),
    do: GenServer.call(server, {:delete, id, identity})

  @impl true
  def init(opts) do
    Config.validate!()
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    {:ok, %{sessions: %{}, clock: clock}}
  end

  @impl true
  def handle_call({:create, identity}, _from, state) do
    state = prune(state)
    binding = identity_binding(identity)
    count = Enum.count(state.sessions, fn {_, session} -> session.agent == agent(identity) end)

    if map_size(state.sessions) >= Config.total_sessions() || count >= Config.agent_sessions() do
      {:reply, {:error, :session_capacity}, state}
    else
      id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      session = %{
        binding: binding,
        agent: agent(identity),
        ready?: false,
        protocol_version: MCP.version(),
        touched: state.clock.()
      }

      {:reply, {:ok, id}, %{state | sessions: Map.put(state.sessions, id, session)}}
    end
  end

  def handle_call({operation, id, identity}, _from, state)
      when operation in [:fetch, :ready, :delete] do
    state = prune(state)

    case Map.get(state.sessions, id) do
      %{binding: expected} = session ->
        if expected == identity_binding(identity) do
          update(operation, id, session, state)
        else
          {:reply, {:error, :session_not_found}, state}
        end

      _ ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  defp update(:delete, id, _, state),
    do: {:reply, :ok, %{state | sessions: Map.delete(state.sessions, id)}}

  defp update(operation, id, session, state) do
    session = %{session | touched: state.clock.(), ready?: session.ready? || operation == :ready}

    {:reply, {:ok, %{ready?: session.ready?, protocol_version: session.protocol_version}},
     %{state | sessions: Map.put(state.sessions, id, session)}}
  end

  defp prune(state) do
    now = state.clock.()

    %{
      state
      | sessions:
          Map.reject(state.sessions, fn {_, s} -> now - s.touched >= Config.idle_timeout() end)
    }
  end

  defp identity_binding(identity),
    do: {identity.organization_id, identity.agent_id, identity.api_key_id}

  defp agent(identity), do: {identity.organization_id, identity.agent_id}
end
