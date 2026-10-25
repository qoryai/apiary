defmodule Apiary.Kinds.BudgetTest do
  # A function run within a budget of reductions, heap and time in another process: its
  # value within the budget, a refusal when it works too much, grows too large, runs too
  # long or crashes, and in every case no process, monitor or message left behind.
  use ExUnit.Case, async: true

  alias Apiary.Kinds.Budget

  # Its time, 10 s, only stops a test that never ends.
  @budget [reductions: 10_000_000, heap_words: 1_000_000, ms: 10_000]

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
          reductions: 100_000_000,
          heap_words: 10_000_000,
          ms: 10_000
        )

      assert {:ok, table} = result
      refute Process.alive?(pid)
      assert :ets.info(table) == :undefined
    end

    refute_received _any
  end

  test "is :reductions when the work passes the budget, and the process is killed then" do
    before = monitors()

    # The work does not grow the heap: without the reductions it would run until its
    # time, `{:error, :time}`.
    {result, pid} =
      run(fn -> Stream.run(Stream.repeatedly(&make_ref/0)) end,
        reductions: 1_000_000,
        heap_words: 100_000,
        ms: 10_000
      )

    assert result == {:error, :reductions}
    gone(pid)
    assert monitors() == before
  end

  test "reads the reductions every :poll_ms, and refuses a :poll_ms that is not positive" do
    {result, pid} =
      run(fn -> Stream.run(Stream.repeatedly(&make_ref/0)) end,
        reductions: 1_000_000,
        heap_words: 100_000,
        ms: 10_000,
        poll_ms: 50
      )

    assert result == {:error, :reductions}
    gone(pid)
    before = monitors()

    for poll_ms <- [nil, 0, -1, 1.5] do
      assert_raise ArgumentError, ~r/:poll_ms/, fn ->
        Budget.run(fn -> :ok end, Keyword.put(@budget, :poll_ms, poll_ms))
      end
    end

    assert monitors() == before
  end

  test "is the value of a function within its reductions, however long it takes" do
    {result, pid} =
      run(fn -> Process.sleep(300) end, reductions: 10_000, heap_words: 100_000, ms: 10_000)

    assert result == {:ok, :ok}
    gone(pid)
  end

  test "is :time when the time runs out, and the process is killed then" do
    before = monitors()

    {microseconds, {result, pid}} =
      :timer.tc(fn ->
        run(fn -> Process.sleep(:infinity) end,
          reductions: 10_000_000,
          heap_words: 1_000_000,
          ms: 100
        )
      end)

    assert result == {:error, :time}
    # Not before its time, 100 ms; the upper bound only stops a test that never ends.
    assert div(microseconds, 1000) in 100..10_000
    gone(pid)
    assert monitors() == before
  end

  test "is :heap when the heap grows past the budget, long before the time" do
    before = monitors()

    {result, pid} =
      run(fn -> Enum.to_list(1..10_000_000) end,
        reductions: 1_000_000_000,
        heap_words: 100_000,
        ms: 10_000
      )

    assert result == {:error, :heap}
    gone(pid)
    assert monitors() == before
  end

  test "is :heap when the binaries the process refers to outside its heap pass the budget" do
    before = monitors()

    # 1000 binaries of 16 KiB, 16 MiB outside the heap, held in a list on a heap of some
    # ten thousand words (measured: 10958): within the budget were they not counted.
    {result, pid} =
      run(
        fn ->
          binaries = for _ <- 1..1000, do: :binary.copy(<<0>>, 16_384)
          length(binaries)
        end,
        reductions: 1_000_000_000,
        heap_words: 100_000,
        ms: 10_000
      )

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

  test "is :time when the watcher has killed the process before the caller looks" do
    test = self()

    caller =
      spawn(fn ->
        result =
          Budget.run(
            fn ->
              send(test, {:runner, self()})
              Process.sleep(:infinity)
            end,
            reductions: 1_000_000,
            heap_words: 100_000,
            ms: 50
          )

        send(test, {:result, result})
      end)

    assert_receive {:runner, runner}, 10_000
    monitor = Process.monitor(runner)

    # The caller sleeps past the time; the watcher kills the process meanwhile.
    :erlang.suspend_process(caller)
    assert_receive {:DOWN, ^monitor, :process, ^runner, :killed}, 10_000
    :erlang.resume_process(caller)

    assert_receive {:result, {:error, :time}}, 10_000
  end

  test "an answer sent at the deadline is not left in the mailbox" do
    {result, pid} =
      run(fn -> Process.sleep(100) end, reductions: 1_000_000, heap_words: 100_000, ms: 100)

    assert result in [{:ok, :ok}, {:error, :time}]
    gone(pid)
  end

  test "the process is killed at once when the caller dies while it waits" do
    test = self()

    caller =
      spawn(fn ->
        Budget.run(
          fn ->
            send(test, {:runner, self()})
            Process.sleep(:infinity)
          end,
          reductions: 1_000_000_000,
          heap_words: 100_000,
          ms: 600_000
        )
      end)

    assert_receive {:runner, runner}, 10_000
    monitor = Process.monitor(runner)
    Process.exit(caller, :kill)

    # Its time is 10 minutes, so a kill within 10 s is the watcher's answer to the death.
    assert_receive {:DOWN, ^monitor, :process, ^runner, :killed}, 10_000
  end
end
