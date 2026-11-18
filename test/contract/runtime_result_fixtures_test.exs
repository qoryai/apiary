defmodule Apiary.Contract.RuntimeResultFixturesTest do
  # The Forager contract's `dev.qory.runtime.result`, vendored at the commit in
  # `.forager-contract-ref` (`events/runtime.result.schema.json`): the result records of
  # Forager's Claude Code fixtures, which the contract keeps beside the runtime's
  # descriptor and not under `fixtures/`, are valid under the schema and read as a
  # session's record (`Apiary.Runs.Sessions`); so are the results the tests of this
  # repository build (`Apiary.RunEventsFixtures.result_data/3`); and each invalid one is
  # refused.
  use ExUnit.Case, async: true

  alias Apiary.{ForagerSchemas, RunEventsFixtures, Runs.Sessions}

  @moduletag :contract

  @schema "events/runtime.result.schema.json"
  @runtime_fixtures "runtimes/claude/fixtures"

  # The events of a fixture of the Claude Code descriptor's: `{type, data}` of each line of
  # its `expected/events.jsonl`, as Forager writes them before it numbers them.
  defp expected(name) do
    dir = Apiary.ContractFixtures.contract_dir()

    [dir, @runtime_fixtures, name, "expected", "events.jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp results(events), do: for(%{"type" => "dev.qory.runtime.result"} = e <- events, do: e)

  defp as_events(events) do
    for {%{"type" => type, "data" => data}, sequence} <- Enum.with_index(events, 1),
        do: %{type: type, sequence: sequence, time: nil, data: data}
  end

  test "each result of the descriptor's fixtures passes the schema" do
    for name <- ~w(background-result headless-result) do
      results = results(expected(name))
      assert results != [], name

      for %{"data" => data} <- results do
        assert ForagerSchemas.validate(@schema, data) == :ok, name
      end
    end
  end

  test "a launch with three result lines is one session with the cost of its last line" do
    events = expected("background-result")
    assert length(results(events)) == 3

    assert [session] = events |> as_events() |> Sessions.read()

    assert %{
             session_number: 1,
             input_tokens: 14,
             output_tokens: 656,
             cache_read_tokens: 136_111,
             cache_write_tokens: 68_908,
             # 2, 1 and 0 turns: each line's own.
             turns: 3,
             duration_ms: 3,
             error: false
           } = session

    # The lines' `cost_usd` are one total, 0.012915135: the cost is not three times it.
    assert Decimal.equal?(session.cost_usd, Decimal.new("0.012915135"))
    assert Decimal.equal?(Sessions.cost(as_events(events)), Decimal.new("0.012915135"))
  end

  test "a result with no usage reads the counts as unknown" do
    assert [session] = "headless-result" |> expected() |> as_events() |> Sessions.read()
    assert %{input_tokens: nil, output_tokens: nil, cache_read_tokens: nil} = session
    assert Decimal.equal?(session.cost_usd, Decimal.new("0.0123"))
  end

  test "the results the tests build pass the schema" do
    for data <- [
          RunEventsFixtures.result_data(1, 0.0129),
          RunEventsFixtures.result_data(2, 0, %{
            "is_error" => true,
            "outcome" => "error_max_turns"
          }),
          RunEventsFixtures.result_data(3, 0.5, %{"usage" => %{"output" => 7}}),
          RunEventsFixtures.result_data(1, 1, %{"usage" => nil, "result" => nil, "line" => nil})
          |> Map.reject(fn {_name, value} -> is_nil(value) end)
        ] do
      assert ForagerSchemas.validate(@schema, data) == :ok, inspect(data)
    end
  end

  test "each invalid result is refused by the schema" do
    good = RunEventsFixtures.result_data(1, 0.0129)

    for {name, data} <- [
          {"session 0", %{good | "session" => 0}},
          {"line 0", %{good | "line" => 0}},
          {"a negative cost", %{good | "cost_usd" => -1}},
          {"a negative count", Map.put(good, "usage", %{"input" => -1})},
          {"a member of usage the contract has not", Map.put(good, "usage", %{"total" => 5})},
          {"a count that is a string", Map.put(good, "usage", %{"input" => "10"})},
          {"no outcome", Map.delete(good, "outcome")},
          {"no is_error", Map.delete(good, "is_error")}
        ] do
      assert {:error, _} = ForagerSchemas.validate(@schema, data), name
    end
  end
end
