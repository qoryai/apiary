defmodule Apiary.Runs.TranscriptLimitsTest do
  # The bounds on what a run keeps of a transcript's path (`Apiary.Runs.Projector`) and
  # what its check refuses (`Apiary.Runs.Transcript.check/2`), with lower limits set in
  # the application's configuration: 64 MiB, and a run's chunk bound, would take too long
  # to store through the projection; the chunk bound's own tests store chunks directly.
  # The configuration is the whole node's, so the module is not async.
  use Apiary.DataCase, async: false

  @moduletag needs: [:factory, :secrets]

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Dispatches.Dispatch
  alias Apiary.Runs.{Projector, Run, SessionChunk, Transcript}

  @path "~/.claude/projects/-workspace/5f2c9a1e.jsonl"

  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{run: run} = handed_over_fixture(scope, key)
    %{run: run}
  end

  defp limits!(limits) do
    previous = Application.get_env(:apiary, Transcript)
    Application.put_env(:apiary, Transcript, limits)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:apiary, Transcript, previous),
        else: Application.delete_env(:apiary, Transcript)
    end)
  end

  # The lifetime the run's handed-over dispatch keeps, in minutes.
  defp lifetime!(run, minutes) do
    {1, _rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: d.dispatch_run_id == ^run.dispatch_run_id and not is_nil(d.handed_over_at)
        ),
        set: [machine_lifetime_minutes: minutes]
      )
  end

  # `count` chunks of one byte at the path, stored as the projection stores them, after
  # `from` of them, from the sequence 2 on.
  defp stored!(run, count, from \\ 0) do
    (from + 1)..(from + count)
    |> Enum.map(fn n ->
      %{
        id: Ecto.UUID.generate(),
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        run_id: run.id,
        sequence: n + 1,
        session: 1,
        session_id: "5f2c9a1e",
        path: @path,
        offset: n - 1,
        bytes: "x"
      }
    end)
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Repo.insert_all(SessionChunk, &1))
  end

  defp chunk(offset, bytes),
    do: %{
      "session" => 1,
      "session_id" => "5f2c9a1e",
      "path" => @path,
      "offset" => offset,
      "bytes" => Base.encode64(bytes)
    }

  # Four chunks of 8 bytes, events 2 to 5, which follow the registration's sequence 1.
  defp four!(run) do
    for n <- 0..3,
        do: event_fixture(run, n + 2, "session.transcript", chunk(n * 8, "{\"n\":#{n}}\n"))

    capture_log(fn -> assert {:ok, %Run{}} = Projector.project(run) end)
  end

  defp kept(run),
    do:
      Repo.all(
        from c in SessionChunk,
          where: c.run_id == ^run.id,
          order_by: c.sequence,
          select: c.sequence
      )

  test "chunks past the most bytes are not kept, and the check refuses the file", ctx do
    # 20 bytes: the third chunk passes it and is kept, so the check refuses the file.
    limits!(max_file: 20)
    log = four!(ctx.run)

    assert kept(ctx.run) == [2, 3, 4]
    assert log =~ "transcript chunks not kept run=#{ctx.run.id} count=1 reason=too_large"
    refute log =~ "{\"n\""

    assert capture_log(fn ->
             assert Transcript.check(ctx.run.id, @path) == {:error, :too_large}
           end) =~ "reason=too_large"
  end

  test "chunks past the most chunks are not kept, and the check refuses the file", ctx do
    limits!(max_chunks: 2)
    log = four!(ctx.run)

    assert kept(ctx.run) == [2, 3]
    assert log =~ "transcript chunks not kept run=#{ctx.run.id} count=2 reason=too_many"

    assert capture_log(fn ->
             assert Transcript.check(ctx.run.id, @path) == {:error, :too_large}
           end) =~ "reason=too_large"
  end

  test "a limit above the default is not taken", ctx do
    limits!(max_file: 128 * 1024 * 1024, max_chunks: 10_000_000)
    lifetime!(ctx.run, 1480)

    assert {Transcript.max_file(), Transcript.max_chunks(ctx.run.id)} ==
             {64 * 1024 * 1024, 90_861}
  end

  test "the chunk bound is a full file's chunks, one per second and per 120 minutes of the machine's lifetime, and one" do
    # 2,048 + 1,480 × 60 + 12 + 1, and 2,048 + 10,080 × 60 + 84 + 1.
    assert Transcript.chunk_bound(1480) == 90_861
    assert Transcript.chunk_bound(10_080) == 606_933
    assert Transcript.chunk_bound(15) == 2_949
  end

  test "a run whose machine lives longer than a day keeps a transcript of more than 100,000 chunks",
       ctx do
    # 1,680 minutes: 2,048 + 100,800 + 14 + 1 = 102,863.
    lifetime!(ctx.run, 1680)
    assert Transcript.max_chunks(ctx.run.id) == 102_863

    stored!(ctx.run, 100_001)

    assert {:ok, %{size: 100_001, max_sequence: 100_002}} =
             Transcript.check(ctx.run.id, @path)
  end

  test "a transcript of as many chunks as the run's bound is refused, one fewer passes", ctx do
    # 15 minutes: 2,048 + 900 + 0 + 1 = 2,949.
    lifetime!(ctx.run, 15)
    stored!(ctx.run, 2_948)
    assert {:ok, %{size: 2_948}} = Transcript.check(ctx.run.id, @path)

    stored!(ctx.run, 1, 2_948)

    assert capture_log(fn ->
             assert Transcript.check(ctx.run.id, @path) == {:error, :too_large}
           end) =~ "reason=too_large"
  end

  test "under the limits, every chunk is kept and the file passes its check", ctx do
    limits!(max_file: 64, max_chunks: 10)
    four!(ctx.run)

    assert kept(ctx.run) == [2, 3, 4, 5]
    assert {:ok, %{size: 32, max_sequence: 5}} = Transcript.check(ctx.run.id, @path)
  end
end
