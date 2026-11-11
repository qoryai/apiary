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
  (`Apiary.Runs.SessionChunk`, `Apiary.Runs.Projector`), and refuses a chunk whose path
  is not one a continuation's machine may write at (`resumable_path?/1`).

  **The file.** A run's transcript at a path is its chunks of that path in sequence
  order. It can be restored only when they start at offset 0 and each starts where the
  one before ended, when they are at most #{64 * 1024 * 1024} bytes (64 MiB) in
  all, and when they are fewer than `max_chunks/0`: a gap in `offset`, a larger file, or
  as many chunks, cannot be restored, and is never served. `check/2` checks it from the
  chunks' offsets and lengths alone, and returns the highest sequence it checked, so the
  digest (`digest/3`) and the bytes sent (`stream/3`) are of the chunks it checked. The
  run's last chunk, by sequence, has the session id and the path a continuation resumes.

  **The paused run.** A run of the queue that continues a paused run, which the end of
  the paused run queues, reads the transcript of that run alone, and only while it is the
  paused run this run continues (`paused_run/1`): of the same organisation, workspace,
  work item and stage, registered, and ended with the reason `model_key_limit`
  (`Apiary.Runs.Run.paused?/1`). Its claim stores its `resume` (`resume_at_claim/1`) for
  a path a machine may write at (`resumable_path?/1`), as the contract has it fixed when
  the run starts; every run configuration of the run then has it (`resume/1`), and its
  gateway fetches the file through the run API.

  Nothing here logs or returns a transcript's bytes but `stream/3`, and a log line
  contains the run's id and the cause alone.
  """

  import Ecto.Query, only: [from: 2, subquery: 1]

  require Logger

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Repo
  alias Apiary.Runs.{Run, SessionChunk}

  @max_file 64 * 1024 * 1024
  @max_chunk 32_768
  # The most chunks of one path a run keeps. The session reads the transcript once a
  # second and once more before a session ends, and cuts what it read into chunks of at
  # most 32,768 bytes (the contract, A session's transcript): a file of 64 MiB is at most
  # 2,048 full chunks, plus one shorter chunk per read. A machine lives at most 1,470
  # minutes (`Apiary.Dispatches.DispatchRun`), 88,200 reads: 2,048 + 88,200 = 90,248,
  # rounded up to 100,000 for the last read of each session.
  @max_chunks 100_000
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

  @doc """
  The most bytes of a transcript that is restored: 64 MiB. A test sets a lower one as
  `:max_file` in the application's configuration of this module; a higher one is not
  taken.
  """
  @spec max_file() :: pos_integer
  def max_file, do: limit(:max_file, @max_file)

  @doc """
  The most chunks of one path a run keeps, and fewer than a restored file has: 100,000. A
  test sets a lower one as `:max_chunks`, as for `max_file/0`.
  """
  @spec max_chunks() :: pos_integer
  def max_chunks, do: limit(:max_chunks, @max_chunks)

  defp limit(name, default),
    do: min(Keyword.get(Application.get_env(:apiary, __MODULE__, []), name, default), default)

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

  @doc """
  Whether `path`, a chunk's path, is one a continuation's machine may write the
  transcript at: the contract's template for it, `resume.prefix` followed by the slug of
  the runtime's working directory, `/` and the file's name (the Forager contract, A
  session's transcript). Qory Apiary has no runtime descriptor, so the prefix it checks
  is the widest one the contract's pattern for `resume.prefix` allows, a directory of
  the runtime's home: the path is `~/`, one or more directories, a slug of ASCII
  letters, digits and `-`, `/`, and a file name that ends in `.jsonl`; no segment of it
  is empty, `.` or `..`, and it has no whitespace or control character. An absolute
  path, and one that leaves the home, is none.
  """
  @spec resumable_path?(String.t()) :: boolean
  def resumable_path?("~/" <> rest) do
    segments = String.split(rest, "/")

    with [file, slug | [_ | _]] <- Enum.reverse(segments),
         false <- Enum.any?(segments, &(&1 in ["", ".", ".."])),
         false <- String.match?(rest, ~r/[\s[:cntrl:]]/u),
         true <- Regex.match?(~r/\A[A-Za-z0-9-]+\z/, slug),
         true <- String.ends_with?(file, ".jsonl") and byte_size(file) > 6 do
      true
    else
      _other -> false
    end
  end

  def resumable_path?(_path), do: false

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
  The check of the transcript of the run `run_id` at `path` (the moduledoc), from the
  chunks' offsets and lengths, with no read of their bytes: `{:ok, %{size: bytes,
  max_sequence: sequence}}`, the file's size and the highest sequence of its chunks, or
  `{:error, cause}`: `:none` with no chunk, `:gap` with a gap in `offset`, `:too_large`
  over 64 MiB or with `max_chunks/0` chunks. A gap or a file over the limit is logged in
  one line, with the run's id and the cause.
  """
  @spec check(Ecto.UUID.t(), String.t()) ::
          {:ok, %{size: non_neg_integer, max_sequence: non_neg_integer}}
          | {:error, :none | :gap | :too_large}
  def check(run_id, path) do
    {count, size, max_sequence, contiguous?} =
      Repo.one(
        from(c in subquery(chunk_ends(run_id, [path])),
          select:
            {count(), type(coalesce(sum(c.length), 0), :integer), max(c.sequence),
             fragment("COALESCE(bool_and(? = ?), true)", c.offset, c.start)}
        ),
        log: false
      )

    cond do
      count == 0 ->
        {:error, :none}

      not contiguous? ->
        refused(run_id, :gap)

      size > max_file() or count >= max_chunks() ->
        refused(run_id, :too_large)

      true ->
        {:ok, %{size: size, max_sequence: max_sequence}}
    end
  end

  defp refused(run_id, cause) do
    Logger.warning("transcript not restorable run=#{run_id} reason=#{cause}")
    {:error, cause}
  end

  # chunk_ends/2 is a query of the chunks of the run `run_id` at `paths`: each chunk's
  # path, sequence, offset and length, and `start`, the sum of the lengths of the chunks
  # of its path before it by sequence, where it would start without a gap. It reads the
  # lengths, never the bytes.
  defp chunk_ends(run_id, paths) do
    from(c in SessionChunk,
      where: c.run_id == ^run_id and c.path in ^paths,
      select: %{
        path: c.path,
        sequence: c.sequence,
        offset: c.offset,
        length: fragment("octet_length(?)", c.bytes),
        start:
          fragment(
            """
            COALESCE(sum(octet_length(?)) OVER (PARTITION BY ? ORDER BY ?
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
            """,
            c.bytes,
            c.path,
            c.sequence
          )
      }
    )
  end

  @doc """
  The SHA-256 of the transcript of the run `run_id` at `path`, of its chunks up to the
  sequence `max_sequence` that `check/2` returned, in lower-case hex. It reads the bytes
  (`stream/3`).
  """
  @spec digest(Ecto.UUID.t(), String.t(), non_neg_integer) :: String.t()
  def digest(run_id, path, max_sequence) do
    run_id
    |> stream(path, max_sequence)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  The bytes of the transcript of the run `run_id` at `path`, chunk by chunk in sequence
  order, up to the sequence `max_sequence` that `check/2` returned, read #{@batch} chunks
  at a time. Check the file with `check/2` first.
  """
  @spec stream(Ecto.UUID.t(), String.t(), non_neg_integer) :: Enumerable.t()
  def stream(run_id, path, max_sequence) do
    Stream.resource(
      fn -> -1 end,
      fn
        :done ->
          {:halt, :done}

        after_sequence ->
          rows =
            Repo.all(
              from(c in SessionChunk,
                where: c.run_id == ^run_id and c.path == ^path,
                where: c.sequence > ^after_sequence and c.sequence <= ^max_sequence,
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
         true <- paused.workspace_id == continuation.workspace_id,
         true <-
           is_binary(paused.work_item_id) and paused.work_item_id == continuation.work_item_id,
         true <- paused.stage_id == continuation.stage_id,
         %Run{} = run <-
           Repo.one(
             from(r in Run.registered(),
               where: r.dispatch_run_id == ^paused.id,
               where: r.organisation_id == ^continuation.organisation_id,
               where: r.workspace_id == ^continuation.workspace_id,
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
  The `resume` of the run of the queue `continuation` at its claim, which the claim
  stores with the run (`runs.resume`): the paused run's id, and the session id and the
  path of its last chunk, while that run is the paused run it continues and its
  transcript there passes `check/2`; nil for any other run, so the continuation starts a
  new session.
  """
  @spec resume_at_claim(map) :: map | nil
  def resume_at_claim(%DispatchRun{continues_id: paused_id} = continuation)
      when is_binary(paused_id) do
    with %Run{} = paused <- paused_run(continuation),
         %{session_id: session_id, path: path} <- last(paused.id),
         true <- resumable_path?(path),
         {:ok, _file} <- check(paused.id, path) do
      %{"run_id" => paused.node_run_id, "session_id" => session_id, "path" => path}
    else
      _none -> nil
    end
  end

  def resume_at_claim(%DispatchRun{}), do: nil

  @doc """
  The `resume` member of the run configuration of `run`: the one its claim stored
  (`resume_at_claim/1`), nil for a run with none.
  """
  @spec resume(Run.t() | map) :: map | nil
  def resume(%{resume: %{"run_id" => _, "session_id" => _, "path" => _} = resume}), do: resume
  def resume(_run), do: nil
end
