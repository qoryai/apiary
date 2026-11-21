defmodule Apiary.DebugLog do
  @moduledoc """
  The log lines a function writes at every level, for a test that checks no secret value
  reaches one. The test environment logs from `:warning` up, so `with_debug_log/1` lowers
  the level for the call and restores it. The level is the node's: use it only in a test
  that is not async.
  """

  import ExUnit.CaptureLog, only: [with_log: 2]

  @doc "Runs `fun`: `{result, log}`, the log of every level."
  @spec with_debug_log((-> result)) :: {result, String.t()} when result: term
  def with_debug_log(fun) do
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      with_log([level: :debug], fun)
    after
      Logger.configure(level: level)
    end
  end

  @doc """
  Fails the test when `text` has any of `secrets`, a list of strings, and says which of
  them by position, never by value.
  """
  @spec refute_secrets(String.t(), [String.t()]) :: :ok
  def refute_secrets(text, secrets) do
    for {secret, position} <- Enum.with_index(secrets, 1) do
      if String.contains?(text, secret) do
        raise ExUnit.AssertionError, message: "the text has the secret number #{position}"
      end
    end

    :ok
  end
end
