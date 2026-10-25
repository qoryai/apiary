defmodule Apiary.Kinds.Budget do
  @moduledoc """
  Budget runs a function in another process under a budget of work, heap and time, for
  work whose cost an untrusted input decides and no limit on the input bounds, such as
  validation against a JSON Schema that the input itself supplies: a schema of a few
  references can make JSV's work, and the errors it keeps, grow exponentially with their
  nesting.

  The work is counted in reductions, the units of work the runtime counts for each
  process: the same function on the same input does the same reductions on any machine
  running the same OTP release, however fast or busy, so whether it fits does not depend
  on the machine. The heap is counted in words, and with it the binaries the process
  refers to that live outside its heap (`include_shared_binaries`), a binary shared with
  other processes counted in full in each, and a part of a large binary possibly counted
  as the whole of it, again for each part the process refers to: a function that makes
  large binaries, such as JSV's error messages that copy a pattern, is held to the budget
  too, and an input of many parts of one large binary is better given as copies. The
  time is only a bound on a process that runs away while it counts few reductions; it is
  set far above what the work allows.

  Memory the runtime keeps outside the heap and the binaries it counts, such as a
  compiled pattern's, is not counted: a function that makes it bounds it before the work
  starts.

  `run/2` starts the process unlinked and monitored, with a `max_heap_size`, and waits for
  its answer, reading the process's reductions every 2 milliseconds, or every `:poll_ms`:

    * `{:ok, value}`, the function's value, when it returns within the budget;
    * `{:error, :reductions}` when its reductions pass the budget, the process then
      killed;
    * `{:error, :heap}` when its heap and the binaries it refers to grow past the
      budget, the process killed by the runtime;
    * `{:error, :time}` when the time runs out, the process then killed;
    * `{:error, :crashed}` when the function raises, throws or exits.

  Either way the process is gone, its monitor removed and its late answer, if any, taken
  from the caller's mailbox before `run/2` returns. A crash in the process never reaches
  the caller. Should the caller die while it waits, a watcher kills the process at once.
  """

  # How often the process's reductions are read, in milliseconds, unless `:poll_ms` is
  # given.
  @poll_ms 2

  @typedoc """
  The budget: `:reductions`, the most reductions the function may do; `:heap_words`, the
  most words its process's heap and the binaries it refers to may hold; `:ms`, the most
  milliseconds it may take; and, optional, `:poll_ms`, how often the reductions are read,
  in milliseconds. The process may pass `:reductions` by the work it does between two
  reads.
  """
  @type budget :: [
          reductions: pos_integer,
          heap_words: pos_integer,
          ms: pos_integer,
          poll_ms: pos_integer
        ]

  @doc "run/2 calls `fun` in another process within `budget` (see the module's documentation)."
  @spec run((-> value), budget) ::
          {:ok, value} | {:error, :reductions | :heap | :time | :crashed}
        when value: term
  def run(fun, budget) when is_function(fun, 0) and is_list(budget) do
    reductions = Keyword.fetch!(budget, :reductions)
    words = Keyword.fetch!(budget, :heap_words)
    ms = Keyword.fetch!(budget, :ms)
    poll_ms = poll_ms(Keyword.get(budget, :poll_ms, @poll_ms))
    caller = self()
    ref = make_ref()
    deadline = now() + ms * 1000

    # The process starts its work once its watcher is there: a caller that dies before
    # leaves a process that waits, and ends at its time.
    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          receive do
            {^ref, :go} -> send(caller, {ref, answer(fun)})
          after
            ms -> :ok
          end
        end,
        [
          :monitor,
          {:max_heap_size,
           %{size: words, kill: true, error_logger: false, include_shared_binaries: true}}
        ]
      )

    {watcher, watcher_monitor} = spawn_monitor(fn -> watch(caller, pid, ms) end)
    send(pid, {ref, :go})

    run = %{pid: pid, monitor: monitor, ref: ref, deadline: deadline, poll_ms: poll_ms}
    result = wait(run, reductions)

    # The watcher ends once the process has.
    receive do
      {:DOWN, ^watcher_monitor, :process, ^watcher, _reason} -> :ok
    end

    result
  end

  # `:poll_ms` is the timeout of a `receive`, so it must be a positive integer: with nil
  # the reductions would never be read, and the run would end at the deadline as
  # `:time`; with 0 they would be read without pause, and a negative value or a float
  # would crash the `receive`.
  defp poll_ms(ms) when is_integer(ms) and ms > 0, do: ms

  defp poll_ms(other),
    do: raise(ArgumentError, "set :poll_ms to a positive integer, not #{inspect(other)}")

  # Kills the process when the caller dies, or at its time should the caller not be there
  # to; ends when the process does.
  defp watch(caller, pid, ms) do
    caller_monitor = Process.monitor(caller)
    pid_monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^pid_monitor, :process, ^pid, _reason} -> :ok
      {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> Process.exit(pid, :kill)
    after
      ms -> Process.exit(pid, :kill)
    end
  end

  defp wait(%{pid: pid, monitor: monitor, ref: ref, deadline: deadline} = run, most) do
    receive do
      {^ref, answer} ->
        gone(pid, monitor, deadline)
        answer

      # Before the time, only the runtime kills the process: its heap is past the budget.
      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        if now() < deadline, do: {:error, :heap}, else: {:error, :time}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :crashed}
    after
      min(run.poll_ms, left(deadline)) ->
        cond do
          now() >= deadline -> stop(run, :time)
          reductions(pid) > most -> stop(run, :reductions)
          true -> wait(run, most)
        end
    end
  end

  # Microseconds, so that a deadline is not passed early by the rounding of milliseconds.
  defp now, do: System.monotonic_time(:microsecond)

  # The milliseconds left until `deadline`, rounded up.
  defp left(deadline), do: max(div(deadline - now() + 999, 1000), 0)

  # The process's reductions, 0 once it is gone: its :DOWN is then in the mailbox.
  defp reductions(pid) do
    case Process.info(pid, :reductions) do
      {:reductions, reductions} -> reductions
      nil -> 0
    end
  end

  # Kills the process, and takes from the mailbox what it left there.
  defp stop(%{pid: pid, monitor: monitor, ref: ref}, reason) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end

    # The process is dead: an answer it sent before it died is in the mailbox now.
    receive do
      {^ref, _answer} -> :ok
    after
      0 -> :ok
    end

    {:error, reason}
  end

  # The process has answered and ends: its :DOWN is waited for until the time runs out,
  # and then it is killed.
  defp gone(pid, monitor, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      left(deadline) ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end
    end
  end

  defp answer(fun) do
    {:ok, fun.()}
  catch
    _kind, _reason -> {:error, :crashed}
  end
end
