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
    result = Budget.run(fn -> send(test, {:runner, self()}) && fun.() end, budget)
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

  test "is :exceeded when the time runs out, and the process is killed then" do
    before = monitors()
    {microseconds, {result, pid}} = :timer.tc(fn -> run(fn -> Process.sleep(:infinity) end) end)
    assert result == {:error, :exceeded}
    assert div(microseconds, 1000) in 100..1000
    gone(pid)
    assert monitors() == before
  end

  test "is :exceeded when the heap grows past the budget" do
    before = monitors()
    {result, pid} = run(fn -> Enum.to_list(1..10_000_000) end, ms: 10_000, heap_words: 100_000)
    assert result == {:error, :exceeded}
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

  test "an answer sent at the deadline is not left in the mailbox" do
    {result, pid} = run(fn -> Process.sleep(100) end, ms: 100, heap_words: 100_000)
    assert result in [{:ok, :ok}, {:error, :exceeded}]
    gone(pid)
  end

  test "the process is killed after its time when the caller dies while it waits" do
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
    Process.exit(caller, :kill)

    # The time, 50 ms, and the timer that kills it a second after.
    assert_receive {:DOWN, ^monitor, :process, ^runner, :killed}, 3000
  end
end
