defmodule Apiary.Kinds.Budget do
  @moduledoc """
  Budget runs a function in another process under a time and a memory budget, for work
  whose cost an untrusted input decides and no limit on the input bounds, such as
  validation against a JSON Schema that the input itself supplies: a schema of a few
  references can make JSV's work, and the errors it keeps, grow exponentially with their
  nesting.

  `run/2` starts the process unlinked and monitored, with a `max_heap_size`, and waits for
  its answer:

    * `{:ok, value}`, the function's value, when it returns in time;
    * `{:error, :time}` when the time runs out, the process then killed;
    * `{:error, :heap}` when its heap grows past the budget, the process killed by the
      runtime;
    * `{:error, :crashed}` when the function raises, throws or exits.

  Either way the process is gone, its monitor removed and its late answer, if any, taken
  from the caller's mailbox before `run/2` returns. A crash in the process never reaches
  the caller. Should the caller die while it waits, a timer kills the process when its
  time runs out.
  """

  @typedoc """
  The budget: `:ms`, the most milliseconds the function may take, and `:heap_words`, the
  most words its process's heap may hold.
  """
  @type budget :: [ms: pos_integer, heap_words: pos_integer]

  @doc "run/2 calls `fun` in another process within `budget` (see the module's documentation)."
  @spec run((-> value), budget) :: {:ok, value} | {:error, :time | :heap | :crashed}
        when value: term
  def run(fun, budget) when is_function(fun, 0) and is_list(budget) do
    ms = Keyword.fetch!(budget, :ms)
    words = Keyword.fetch!(budget, :heap_words)
    caller = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + ms

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(caller, {ref, answer(fun)}) end,
        [:monitor, {:max_heap_size, %{size: words, kill: true, error_logger: false}}]
      )

    # Kills the process at its time should the caller no longer be there to.
    {:ok, timer} = :timer.kill_after(ms, pid)

    result =
      receive do
        {^ref, answer} ->
          Process.demonitor(monitor, [:flush])
          answer

        # Before the time, only the runtime kills the process: its heap is past the budget.
        {:DOWN, ^monitor, :process, ^pid, :killed} ->
          if System.monotonic_time(:millisecond) < deadline,
            do: {:error, :heap},
            else: {:error, :time}

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          {:error, :crashed}
      after
        ms ->
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

          {:error, :time}
      end

    :timer.cancel(timer)
    result
  end

  defp answer(fun) do
    {:ok, fun.()}
  catch
    _kind, _reason -> {:error, :crashed}
  end
end
