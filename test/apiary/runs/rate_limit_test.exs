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
    assert [{^key, tokens, _at, _drop_after}] = :ets.lookup(RateLimit, key)
    assert is_integer(tokens)
  end

  # Moves the bucket's last spending `ms` into the past, as if that much time went by,
  # then lets the table's owner sweep.
  defp rewind_and_sweep(key, ms) do
    [{^key, _tokens, at, drop_after}] = :ets.lookup(RateLimit, key)
    true = :ets.update_element(RateLimit, key, [{3, at - ms}, {4, drop_after - ms}])
    send(RateLimit, :sweep)
    :sys.get_state(RateLimit)
  end

  test "an idle bucket is dropped after 10 minutes once full again, and a slower one only once full" do
    fast = key()
    for _ <- 1..2, do: assert(RateLimit.check(fast, rate: 1, burst: 2) == :ok)
    rewind_and_sweep(fast, 599_000)
    assert [_] = :ets.lookup(RateLimit, fast)
    rewind_and_sweep(fast, 2_000)
    assert :ets.lookup(RateLimit, fast) == []

    # 3 at once, then 1 every 5 minutes: full again 15 minutes after its last token.
    slow = key()
    for _ <- 1..3, do: assert(RateLimit.check(slow, rate: 1 / 300, burst: 3) == :ok)
    rewind_and_sweep(slow, 601_000)
    assert [_] = :ets.lookup(RateLimit, slow)
    assert RateLimit.check(slow, rate: 1 / 300, burst: 3) == :ok
    assert RateLimit.check(slow, rate: 1 / 300, burst: 3) == :ok
    assert {:error, _} = RateLimit.check(slow, rate: 1 / 300, burst: 3)

    still = key()
    for _ <- 1..3, do: assert(RateLimit.check(still, rate: 1 / 300, burst: 3) == :ok)
    rewind_and_sweep(still, 899_000)
    assert [_] = :ets.lookup(RateLimit, still)
    rewind_and_sweep(still, 2_000)
    assert :ets.lookup(RateLimit, still) == []
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
