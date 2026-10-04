defmodule AiControl.Testing.State do
  @moduledoc "Process-local fixtures, started only by the isolated runner."
  use Agent

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def get(key, default \\ nil), do: Agent.get(__MODULE__, &Map.get(&1, key, default))
  def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)
end
