defmodule AiControl.Policies.Cache do
  @moduledoc "Protected ETS of immutable versions. Active pointers always come from PostgreSQL."
  use GenServer

  alias AiControl.Policy.Snapshot

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def fetch(id) do
    case :ets.lookup(__MODULE__, id) do
      [{^id, snapshot}] -> {:ok, snapshot}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def put(id, snapshot) do
    if Snapshot.valid?(snapshot) && snapshot.version == "policy-#{id}",
      do: GenServer.call(__MODULE__, {:put, id, snapshot}),
      else: {:error, :invalid_security_data}
  catch
    :exit, _ -> :ok
  end

  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, id, snapshot}, _, state) do
    if :ets.info(__MODULE__, :size) >= 1_000, do: :ets.delete_all_objects(__MODULE__)
    :ets.insert_new(__MODULE__, {id, snapshot})
    {:reply, :ok, state}
  end

  def handle_call(:clear, _, state) do
    :ets.delete_all_objects(__MODULE__)
    {:reply, :ok, state}
  end
end
