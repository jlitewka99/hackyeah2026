defmodule AiControl.Gateway.SlotsTest do
  use ExUnit.Case, async: false

  alias AiControl.Gateway.Slots

  test "LLM saturation rejects immediately; completion frees its lease" do
    test = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           result =
             Slots.run(:llm, 5_000, fn ->
               send(test, {:running, self()})

               receive do
                 :finish -> {:ok, :done}
               end
             end)

           send(test, {:result, result})
         end}
      )

    assert_receive {:running, worker}

    assert {:error, {:capacity_exceeded, 1}} =
             Slots.run(:llm, 100, fn -> flunk("saturated worker ran") end)

    ref = Process.monitor(owner)
    send(worker, :finish)
    assert_receive {:result, {:ok, :done}}
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    assert {:ok, :next} = Slots.run(:llm, 100, fn -> {:ok, :next} end)
  end

  test "request cancellation kills its supervised worker and frees capacity" do
    test = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           Slots.run(:llm, 5_000, fn ->
             send(test, {:running, self()})

             receive do
               :never -> :ok
             end
           end)
         end}
      )

    assert_receive {:running, worker}
    ref = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    _ = :sys.get_state(Slots)
    assert {:ok, :next} = Slots.run(:llm, 100, fn -> {:ok, :next} end)
  end

  test "timeout, provider exception and provider error each free the lease" do
    assert {:error, :upstream_timeout} =
             Slots.run(:llm, 10, fn ->
               receive do
                 :never -> :ok
               end
             end)

    assert {:error, :upstream_unavailable} =
             Slots.run(:llm, 100, fn -> raise "private payload" end)

    assert {:error, :upstream_rejected} =
             Slots.run(:llm, 100, fn -> {:error, :upstream_rejected} end)

    assert {:ok, :next} = Slots.run(:llm, 100, fn -> {:ok, :next} end)
  end

  test "guards have two slots independently of the LLM" do
    test = self()

    workers =
      for id <- 1..2 do
        start_supervised!(
          Supervisor.child_spec(
            {Task,
             fn ->
               Slots.run(:guard, 5_000, fn ->
                 send(test, {:guard, self()})

                 receive do
                   :finish -> :ok
                 end
               end)
             end},
            id: {:guard, id}
          )
        )

        assert_receive {:guard, worker}
        worker
      end

    assert {:error, {:capacity_exceeded, 1}} =
             Slots.run(:guard, 100, fn -> flunk("saturated guard ran") end)

    assert :ok = Slots.run(:llm, 100, fn -> :ok end)
    Enum.each(workers, &send(&1, :finish))
  end
end
