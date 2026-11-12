defmodule Apiary.Integrations.DescriptionRecheckTest do
  # A recheck of saved settings (`Description.recheck_settings/2`) returns
  # `{:error, :unchecked}` for a check stopped at its time or by a crash, which the
  # settings do not decide, and the error of `check_settings/2` for a stop at the pattern
  # bound, which they do. Each stop runs through `Apiary.Kinds.Budget.run/2`, with a
  # budget of 1 ms or a check that raises, set for every process
  # (`Description.put_test_budget_run/1`), so the test is not async.
  use ExUnit.Case, async: false

  import Apiary.DescriptionFixtures
  import ExUnit.CaptureLog

  alias Apiary.Integrations.Description
  alias Apiary.Kinds.Budget

  setup do
    on_exit(fn -> Description.put_test_budget_run(nil) end)
  end

  defp described(schema) do
    assert {:ok, description} =
             tracker_description(%{"settings" => schema}) |> encode() |> Description.parse()

    description
  end

  # A schema whose every level refers twice to the next: 2^20 checks of one value, more
  # than a second of work.
  defp doubling do
    chain =
      Map.new(1..20, fn i ->
        next = %{"$ref" => "#/$defs/d#{i + 1}"}
        {"d#{i}", %{"allOf" => [next, next]}}
      end)

    described(%{
      "type" => "object",
      "properties" => %{"a" => %{"$ref" => "#/$defs/d1"}},
      "$defs" => Map.put(chain, "d21", %{"type" => "string"})
    })
  end

  defp stopped(description, settings) do
    with_log(fn ->
      {Description.recheck_settings(description, settings),
       Description.check_settings(description, settings)}
    end)
  end

  test "a check stopped at its time is unchecked" do
    Description.put_test_budget_run(fn check, budget ->
      Budget.run(
        check,
        Keyword.merge(budget, ms: 1, reductions: 1_000_000_000, heap_words: 1_000_000_000)
      )
    end)

    {{recheck, check}, log} = stopped(doubling(), %{"a" => "s"})
    assert recheck == {:error, :unchecked}
    assert check == {:error, {:integration_settings_invalid, %{valid: false, budget: :exceeded}}}
    assert log =~ "reason=time"
  end

  test "a check that crashed is unchecked" do
    Description.put_test_budget_run(fn _check, budget ->
      Budget.run(fn -> raise "the check crashed" end, budget)
    end)

    {{recheck, check}, log} = stopped(doubling(), %{"a" => "s"})
    assert recheck == {:error, :unchecked}
    assert check == {:error, {:integration_settings_invalid, %{valid: false, crashed: true}}}
    assert log =~ "reason=crashed"
  end

  # 1950 patterns of about 64 KB each once compiled, past the 16 MiB the check's patterns
  # may hold.
  test "a check stopped at the pattern bound keeps the error of a check" do
    heavy = fn i -> %{"pattern" => "(?:a){7900}b#{i}"} end

    description =
      described(%{
        "type" => "object",
        "properties" => %{
          "a" => %{
            "allOf" =>
              for(c <- Enum.chunk_every(1..1950, 1000), do: %{"allOf" => Enum.map(c, heavy)})
          }
        }
      })

    {{recheck, check}, log} = stopped(description, %{"a" => "s"})

    assert recheck ==
             {:error, {:integration_settings_invalid, %{valid: false, budget: :exceeded}}}

    assert recheck == check
    assert log =~ "reason=patterns"
  end
end
