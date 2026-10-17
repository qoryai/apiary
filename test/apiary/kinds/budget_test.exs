defmodule Apiary.Kinds.BudgetTest do
  # A function run within a time and a memory budget in another process: its value in
  # time, a refusal when it takes too long, grows too large or crashes, and in every case
  # no process, monitor or message left behind.
  use ExUnit.Case, async: true

  alias Apiary.Kinds.Budget

  @budget [ms: 100, heap_words: 1_000_000]

  # Runs `fun` within `budget`, and hands the test the pid of the process that ran it.
  defp run(fun, budget \\ @budget) do
    test = self()

    result =
      Budget.run(
        fn ->
          send(test, {:runner, self()})
          fun.()
        end,
        budget
      )

    assert_received {:runner, pid}
    {result, pid}
  end

  defp monitors, do: Process.info(self(), :monitors)

  # Nothing of the run is left: its process is dead, and no message from it waits.
  defp gone(pid) do
    refute Process.alive?(pid)
    refute_received _any
  end

  test "is the function's value when it returns in time" do
    before = monitors()
    {result, pid} = run(fn -> 1 + 1 end)
    assert result == {:ok, 2}
    gone(pid)
    assert monitors() == before
  end

  test "its process has ended when run/2 returns the value, slow as its end may be" do
    # The process owns a large table, which the runtime deletes as the process ends, after
    # its answer.
    for _ <- 1..5 do
      {result, pid} =
        run(
          fn ->
            table = :ets.new(:budget_test, [:public])
            :ets.insert(table, for(i <- 1..200_000, do: {i, i}))
            table
          end,
          ms: 5000,
          heap_words: 10_000_000
        )

      assert {:ok, table} = result
      refute Process.alive?(pid)
      assert :ets.info(table) == :undefined
    end

    refute_received _any
  end

  test "is :time when the time runs out, and the process is killed then" do
    before = monitors()
    {microseconds, {result, pid}} = :timer.tc(fn -> run(fn -> Process.sleep(:infinity) end) end)
    assert result == {:error, :time}
    assert div(microseconds, 1000) in 100..1000
    gone(pid)
    assert monitors() == before
  end

  test "is :heap when the heap grows past the budget, long before the time" do
    before = monitors()
    {result, pid} = run(fn -> Enum.to_list(1..10_000_000) end, ms: 10_000, heap_words: 100_000)
    assert result == {:error, :heap}
    gone(pid)
    assert monitors() == before
  end

  test "is :crashed when the function raises, throws or exits, and the caller lives on" do
    before = monitors()

    for fun <- [fn -> raise "boom" end, fn -> throw(:boom) end, fn -> exit(:boom) end] do
      {result, pid} = run(fun)
      assert result == {:error, :crashed}
      gone(pid)
    end

    assert monitors() == before
  end

  test "is :time when the timer has killed the process before the caller looks" do
    test = self()

    caller =
      spawn(fn ->
        result =
          Budget.run(
            fn ->
              send(test, {:runner, self()})
              Process.sleep(:infinity)
            end,
            ms: 50,
            heap_words: 100_000
          )

        send(test, {:result, result})
      end)

    assert_receive {:runner, runner}
    monitor = Process.monitor(runner)

    # The caller sleeps past the time; the timer kills the process meanwhile.
    :erlang.suspend_process(caller)
    assert_receive {:DOWN, ^monitor, :process, ^runner, :killed}, 1000
    :erlang.resume_process(caller)

    assert_receive {:result, {:error, :time}}, 1000
  end

  test "an answer sent at the deadline is not left in the mailbox" do
    {result, pid} = run(fn -> Process.sleep(100) end, ms: 100, heap_words: 100_000)
    assert result in [{:ok, :ok}, {:error, :time}]
    gone(pid)
  end

  test "the process is killed at its time when the caller dies while it waits" do
    test = self()

    caller =
      spawn(fn ->
        Budget.run(
          fn ->
            send(test, {:runner, self()})
            Process.sleep(:infinity)
          end,
          ms: 50,
          heap_words: 100_000
        )
      end)

    assert_receive {:runner, runner}
    monitor = Process.monitor(runner)
    started = System.monotonic_time(:millisecond)
    Process.exit(caller, :kill)

    # The time, 50 ms, and room for a slow machine.
    assert_receive {:DOWN, ^monitor, :process, ^runner, :killed}, 1000
    assert System.monotonic_time(:millisecond) - started < 500
  end
end
