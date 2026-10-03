defmodule AiControl.Budgets.Cache do
  @moduledoc "A short-lived read cache. Enforcement always locks PostgreSQL rows."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def clear, do: call(:clear, :ok)

  def read(key, callback) do
    case call({:get, key}, :miss) do
      {:ok, value} ->
        value

      :miss ->
        value = callback.()
        call({:put, key, value}, :ok)
        value
    end
  end

  defp call(message, fallback) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(_), do: {:ok, :ets.new(__MODULE__, [:set, :private])}
  @impl true
  def handle_call(:clear, _, table) do
    :ets.delete_all_objects(table)
    {:reply, :ok, table}
  end

  def handle_call({:get, key}, _, table) do
    result =
      case :ets.lookup(table, key) do
        [{^key, deadline, value}] ->
          if deadline > System.monotonic_time(:millisecond), do: {:ok, value}, else: :miss

        [] ->
          :miss
      end

    {:reply, result, table}
  end

  def handle_call({:put, key, value}, _, table) do
    :ets.insert(table, {key, System.monotonic_time(:millisecond) + 1_000, value})
    {:reply, :ok, table}
  end
end
