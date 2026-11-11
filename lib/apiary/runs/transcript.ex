defmodule Apiary.Runs.Transcript do
  @moduledoc """
  The transcript of a run's runtime session, as its gateway sends it in
  `dev.qory.session.transcript` events, and how the run that continues a paused run reads
  it back (the Forager contract, A session's transcript; the run API, The transcript of a
  paused run).

  **A chunk.** `parse/1` reads an event's data by the contract's schema,
  `events/session.transcript.schema.json`: exactly `session`, an integer from 1;
  `session_id`, 1 to 128 characters; `path`, 1 to 1024 characters; `offset`, an integer
  from 0; and `bytes`, 4 to 43,692 characters of base64 that decode to 1 to 32,768 bytes.
  Any other data is no chunk. The projection keeps each chunk by its event's sequence
  (`Apiary.Runs.SessionChunk`, `Apiary.Runs.Projector`).

  **The file.** A run's transcript at a path is its chunks of that path in sequence
  order. It can be restored only when they start at offset 0 and each starts where the
  one before ended, and when they are at most #{64 * 1024 * 1024} bytes (64 MiB) in
  all: a gap in `offset`, or a larger file, cannot be restored, and is never served. The run's last
  chunk, by sequence, has the session id and the path a continuation resumes.

  **The paused run.** A run of the queue that continues a paused run, which the end of
  the paused run queues, reads the transcript of that run alone, and
  only while it is the paused run this run continues (`paused_run/1`): of the same
  organisation, work item and stage, registered, and ended with the reason
  `model_key_limit` (`Apiary.Runs.Run.paused?/1`). Its run configuration then has
  `resume` (`resume/1`), and its gateway fetches the file through the run API.

  Nothing here logs or returns a transcript's bytes but `stream/2`, and a log line
  contains the run's id and the cause alone.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Repo
  alias Apiary.Runs.{Run, SessionChunk}

  @max_file 64 * 1024 * 1024
  @max_chunk 32_768
  @max_encoded 43_692
  @int4 2_147_483_647
  @int8 9_223_372_036_854_775_807
  @members ~w(bytes offset path session session_id)
  # The chunks one read of the file takes.
  @batch 64

  @typedoc "A chunk as `parse/1` reads it, its bytes decoded."
  @type chunk :: %{
          session: pos_integer,
          session_id: String.t(),
          path: String.t(),
          offset: non_neg_integer,
          bytes: binary
        }

  @doc "The most bytes of a transcript that is restored: 64 MiB."
  @spec max_file() :: pos_integer
  def max_file, do: @max_file

  @doc "The chunk `data` is, an event's data (the moduledoc), or `:error`."
  @spec parse(term) :: {:ok, chunk} | :error
  def parse(%{} = data) do
    with true <- data |> Map.keys() |> Enum.sort() == @members,
         %{
           "session" => session,
           "session_id" => session_id,
           "path" => path,
           "offset" => offset,
           "bytes" => encoded
         } = data,
         true <- is_integer(session) and session in 1..@int4,
         true <- text?(session_id, 128) and text?(path, 1024),
         true <- is_integer(offset) and offset in 0..@int8,
         true <- is_binary(encoded) and byte_size(encoded) in 4..@max_encoded,
         {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) in 1..@max_chunk do
      {:ok, %{session: session, session_id: session_id, path: path, offset: offset, bytes: bytes}}
    else
      _other -> :error
    end
  end

  def parse(_data), do: :error

  # A string of 1 to `max` characters, as JSON Schema counts them: code points.
  defp text?(value, max) when is_binary(value) do
    String.valid?(value) and value != "" and
      (byte_size(value) <= max or String.length(value) <= max)
  end

  defp text?(_value, _max), do: false

  @doc """
  The session id and the path of the last chunk of the run `run_id`, by sequence:
  `%{session_id: id, path: path}`, or nil for a run with none.
  """
  @spec last(Ecto.UUID.t()) :: %{session_id: String.t(), path: String.t()} | nil
  def last(run_id) do
    Repo.one(
      from(c in SessionChunk,
        where: c.run_id == ^run_id,
        order_by: [desc: c.sequence],
        limit: 1,
        select: %{session_id: c.session_id, path: c.path}
      ),
      log: false
    )
  end

  @doc """
  The transcript of the run `run_id` at `path` (the moduledoc): `{:ok, %{size: bytes,
  sha256: lower-case hex}}`, or `{:error, cause}`: `:none` with no chunk, `:gap` with a
  gap in `offset`, `:too_large` over 64 MiB. A gap or a size over the limit is logged in
  one line, with the run's id and the cause.
  """
  @spec file(Ecto.UUID.t(), String.t()) ::
          {:ok, %{size: non_neg_integer, sha256: String.t()}}
          | {:error, :none | :gap | :too_large}
  def file(run_id, path) do
    parts =
      Repo.all(
        from(c in SessionChunk,
          where: c.run_id == ^run_id and c.path == ^path,
          order_by: c.sequence,
          select: {c.offset, fragment("octet_length(?)", c.bytes)}
        ),
        log: false
      )

    case whole(parts, 0) do
      {:ok, 0} ->
        {:error, :none}

      {:ok, size} ->
        {:ok, %{size: size, sha256: digest(run_id, path)}}

      {:error, cause} = error ->
        Logger.warning("transcript not restorable run=#{run_id} reason=#{cause}")
        error
    end
  end

  defp whole([], size), do: {:ok, size}
  defp whole([{offset, _length} | _rest], size) when offset != size, do: {:error, :gap}

  defp whole([{_offset, length} | rest], size) do
    if size + length > @max_file, do: {:error, :too_large}, else: whole(rest, size + length)
  end

  defp digest(run_id, path) do
    run_id
    |> stream(path)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  The bytes of the transcript of the run `run_id` at `path`, chunk by chunk in sequence
  order, read #{@batch} chunks at a time. Check the file with `file/2` first.
  """
  @spec stream(Ecto.UUID.t(), String.t()) :: Enumerable.t()
  def stream(run_id, path) do
    Stream.resource(
      fn -> -1 end,
      fn
        :done ->
          {:halt, :done}

        after_sequence ->
          rows =
            Repo.all(
              from(c in SessionChunk,
                where: c.run_id == ^run_id and c.path == ^path and c.sequence > ^after_sequence,
                order_by: c.sequence,
                limit: @batch,
                select: {c.sequence, c.bytes}
              ),
              log: false
            )

          case rows do
            [] -> {:halt, :done}
            rows -> {Enum.map(rows, &elem(&1, 1)), rows |> List.last() |> elem(0)}
          end
      end,
      fn _cursor -> :ok end
    )
  end

  # paused_run/1 is the registered run that the run of the queue `dispatch_run`
  # continues, while it is the paused run (the moduledoc); nil for any other run of the
  # queue.
  @doc false
  @spec paused_run(DispatchRun.t()) :: Run.t() | nil
  def paused_run(%DispatchRun{continues_id: paused_id} = continuation)
      when is_binary(paused_id) do
    with %DispatchRun{} = paused <- Repo.get(DispatchRun, paused_id),
         true <- paused.organisation_id == continuation.organisation_id,
         true <-
           is_binary(paused.work_item_id) and paused.work_item_id == continuation.work_item_id,
         true <- paused.stage_id == continuation.stage_id,
         %Run{} = run <-
           Repo.one(
             from(r in Run.registered(),
               where: r.dispatch_run_id == ^paused.id,
               where: r.organisation_id == ^continuation.organisation_id,
               limit: 1
             )
           ),
         true <- Run.paused?(run) and run.exit_reason == "model_key_limit" do
      run
    else
      _other -> nil
    end
  end

  def paused_run(%DispatchRun{}), do: nil

  @doc """
  The `resume` member of the run configuration of `run`, a registered run of the queue
  that continues a paused run (the moduledoc): the paused run's id, and the session id
  and the path of its last chunk, while its transcript there can be restored; nil for
  any other run, so the continuation starts a new session.
  """
  @spec resume(Run.t() | map) :: map | nil
  def resume(%{dispatch_run_id: id}) when is_binary(id) do
    with %DispatchRun{continues_id: paused_id} = continuation when is_binary(paused_id) <-
           Repo.get(DispatchRun, id),
         %Run{} = paused <- paused_run(continuation),
         %{session_id: session_id, path: path} <- last(paused.id),
         {:ok, _file} <- file(paused.id, path) do
      %{"run_id" => paused.node_run_id, "session_id" => session_id, "path" => path}
    else
      _none -> nil
    end
  end

  def resume(_run), do: nil
end
