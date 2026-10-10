defmodule Apiary.Runs.RateLimitTest do
  use ExUnit.Case, async: true

  alias Apiary.Runs.RateLimit

  defp key, do: "key-#{System.unique_integer([:positive])}"

  test "a bucket holds the burst and then refuses with the seconds to wait" do
    key = key()
    for _ <- 1..3, do: assert(RateLimit.check(key, rate: 1, burst: 3) == :ok)
    assert RateLimit.check(key, rate: 1, burst: 3) == {:error, 1}
  end

  test "a bucket refills with time" do
    key = key()
    assert RateLimit.check(key, rate: 5, burst: 1) == :ok
    assert {:error, 1} = RateLimit.check(key, rate: 5, burst: 1)
    Process.sleep(250)
    assert RateLimit.check(key, rate: 5, burst: 1) == :ok
  end

  test "a rate below one a second is a fraction, and the bucket still counts whole thousandths" do
    key = key()
    assert RateLimit.check(key, rate: 1 / 60, burst: 2) == :ok
    Process.sleep(5)
    assert RateLimit.check(key, rate: 1 / 60, burst: 2) == :ok
    assert {:error, 60} = RateLimit.check(key, rate: 1 / 60, burst: 2)
    assert [{^key, tokens, _at}] = :ets.lookup(RateLimit, key)
    assert is_integer(tokens)
  end

  test "one key's bucket is not another's" do
    {one, other} = {key(), key()}
    assert RateLimit.check(one, rate: 1, burst: 1) == :ok
    assert {:error, _} = RateLimit.check(one, rate: 1, burst: 1)
    assert RateLimit.check(other, rate: 1, burst: 1) == :ok
  end

  test "requests at once never spend the same token" do
    key = key()

    granted =
      1..200
      |> Task.async_stream(fn _ -> RateLimit.check(key, rate: 0, burst: 50) end,
        max_concurrency: 50
      )
      |> Enum.count(&(&1 == {:ok, :ok}))

    assert granted == 50
  end
end
