defmodule ApiaryWeb.TranscriptStub do
  @moduledoc """
  The module that reads a paused run's chunks for the transcript answer in tests
  (`ApiaryWeb.Contract.TranscriptController`), set in `config/test.exs`: the chunks of
  `Apiary.Runs.Transcript.stream/3`, unless the test process set `fail_at/1`. Then the
  chunk at that index, counted from 0, raises, and each chunk before it is sent to the
  test process as `{:transcript_pulled, bytes}` when the answer takes it. A request
  through `Phoenix.ConnTest` runs in the test process, so the setting is the test's alone.
  """

  alias Apiary.Runs.Transcript

  @doc "Makes the chunk at `index` of the test's next transcript answer raise."
  def fail_at(index) when is_integer(index) and index >= 0,
    do: Process.put({__MODULE__, :fail_at}, index)

  @doc false
  def stream(run_id, path, max_sequence) do
    chunks = Transcript.stream(run_id, path, max_sequence)

    case Process.get({__MODULE__, :fail_at}) do
      nil ->
        chunks

      fail_at ->
        chunks
        |> Stream.with_index()
        |> Stream.map(fn
          {_bytes, ^fail_at} ->
            raise "chunk read failed"

          {bytes, _index} ->
            send(self(), {:transcript_pulled, bytes})
            bytes
        end)
    end
  end
end
