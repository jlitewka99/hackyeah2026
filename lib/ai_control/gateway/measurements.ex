defmodule AiControl.Gateway.Measurements do
  @moduledoc "Bounded, content-free timings shared explicitly with request workers."
  alias AiControl.Policies.Configuration

  @stages ~w(request input output budget_admission budget_reservation budget_settlement upstream stream_delivery)
  @keys @stages ++
          for(
            stage <- ~w(input output),
            guard <- Configuration.guards(6),
            do: "guard.#{stage}.#{guard}"
          )
  def keys, do: @keys

  def run(callback) do
    {:ok, pid} = Agent.start_link(fn -> %{} end)

    try do
      callback.(pid)
    after
      Agent.stop(pid)
    end
  end

  def record(nil, _, _), do: :ok

  def record(pid, key, duration) when key in @keys do
    Agent.update(pid, &Map.update(&1, key, duration, fn previous -> previous + duration end))
  end

  def record(_, _, _), do: :ok
  def snapshot(pid), do: Agent.get(pid, & &1)

  def valid?(timings) when is_map(timings) and not is_struct(timings),
    do: Enum.all?(timings, fn {key, value} -> key in @keys && is_integer(value) && value >= 0 end)

  def valid?(_), do: false
end
