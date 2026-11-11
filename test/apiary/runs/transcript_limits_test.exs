defmodule Apiary.Runs.TranscriptLimitsTest do
  # The bounds on what a run keeps of a transcript's path (`Apiary.Runs.Projector`) and
  # what its check refuses (`Apiary.Runs.Transcript.check/2`), with lower limits set in
  # the application's configuration: 64 MiB and 100,000 chunks would take too long to
  # store. The configuration is the whole node's, so the module is not async.
  use Apiary.DataCase, async: false

  @moduletag needs: [:factory, :secrets]

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

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

  test "a limit above the default is not taken" do
    limits!(max_file: 128 * 1024 * 1024, max_chunks: 200_000)
    assert {Transcript.max_file(), Transcript.max_chunks()} == {64 * 1024 * 1024, 100_000}
  end

  test "under the limits, every chunk is kept and the file passes its check", ctx do
    limits!(max_file: 64, max_chunks: 10)
    four!(ctx.run)

    assert kept(ctx.run) == [2, 3, 4, 5]
    assert {:ok, %{size: 32, max_sequence: 5}} = Transcript.check(ctx.run.id, @path)
  end
end
