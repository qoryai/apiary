defmodule Apiary.Runs.StuckLogTest do
  # The dictionary is the test process's alone.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Apiary.Runs.StuckLog

  @id "6f2b1a6e-0d6c-4c4e-9a53-2b8f4f0f9a10"
  @other "0a8c9d1e-5b7f-4e2a-8c3d-1f6e9b2a7c45"

  defp log(key, detail, at),
    do:
      capture_log(fn ->
        StuckLog.log(:error, key, detail, fn -> "stuck #{inspect(key)}" end, at)
      end)

  test "writes a run's line once an hour, and again when its detail changes" do
    assert log({:lose, @id}, RuntimeError, 0) =~ "stuck"
    assert log({:lose, @id}, RuntimeError, 15) == ""
    assert log({:lose, @id}, RuntimeError, 3599) == ""
    assert log({:lose, @id}, ArgumentError, 3600) =~ "stuck"
    assert log({:lose, @id}, ArgumentError, 7199) == ""
    assert log({:lose, @id}, ArgumentError, 7200) =~ "stuck"
  end

  test "keeps each kind of line and each run apart" do
    assert log({:lose, @id}, nil, 0) =~ "stuck"
    assert log({:stage, @id}, nil, 0) =~ "stuck"
    assert log({:lose, @other}, nil, 0) =~ "stuck"
    assert log({:settle, @id}, nil, 10) =~ "stuck"
    assert map_size(StuckLog.lines()) == 4
  end

  test "makes no line it does not write" do
    capture_log(fn -> StuckLog.log(:error, {:lose, @id}, nil, fn -> "first" end, 0) end)
    StuckLog.log(:error, {:lose, @id}, nil, fn -> flunk("made a line it did not write") end, 1)
  end

  test "drops a run's entry once it is no longer stuck, and every entry an hour old" do
    log({:lose, @id}, nil, 0)
    log({:stage, @other}, nil, 1800)
    StuckLog.clear({:lose, @id})
    assert Map.keys(StuckLog.lines()) == [{:stage, @other}]
    assert log({:lose, @id}, nil, 1801) =~ "stuck"

    # An hour after the stage line, the next line drops it; the newer line stays.
    log({:settle, @id}, nil, 5400)
    assert Enum.sort(Map.keys(StuckLog.lines())) == [{:lose, @id}, {:settle, @id}]

    StuckLog.clear({:lose, @id})
    StuckLog.clear({:settle, @id})
    assert StuckLog.lines() == %{}
    assert Process.get(StuckLog) == nil
  end
end
