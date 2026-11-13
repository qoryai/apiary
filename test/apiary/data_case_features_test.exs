defmodule Apiary.DataCaseFeaturesTest do
  @moduledoc """
  The guard in `Apiary.DataCase.setup_features/1`, called with a test's tags: an async
  test may list only the suite's features, and a test of either kind with a
  `with_features:` list that is not valid raises with the fix first.
  """
  use Apiary.DataCase, async: false

  describe "an async test tagged with_features:" do
    @tag :feature_sets
    test "with the suite's features leaves the application environment as it is" do
      previous = Application.get_env(:apiary, :features)
      listed = Enum.reverse(Apiary.Features.enabled())

      assert Apiary.DataCase.setup_features(%{async: true, with_features: listed}) == :ok
      assert Application.get_env(:apiary, :features) == previous
    end

    @tag :feature_sets
    test "with other features raises" do
      other =
        if Apiary.Features.enabled() == [:observability],
          do: Apiary.Features.all(),
          else: [:observability]

      assert_raise ArgumentError, ~r/^Make the test sync/, fn ->
        Apiary.DataCase.setup_features(%{async: true, with_features: other})
      end

      assert_raise ArgumentError, ~r/^Correct the test's/, fn ->
        Apiary.DataCase.setup_features(%{async: true, with_features: [:no_such_feature]})
      end
    end
  end

  describe "a sync test tagged with_features:" do
    @tag :feature_sets
    test "with a list that is not valid raises with the fix, the cause, then the list" do
      previous = Application.get_env(:apiary, :features)

      error =
        assert_raise ArgumentError, fn ->
          Apiary.DataCase.setup_features(%{async: false, with_features: [:secrets]})
        end

      assert error.message ==
               "Correct the test's with_features: list.\n" <>
                 "QORY_FEATURES list is not valid: " <>
                 "secrets needs security, which is left out ([:secrets])"

      assert Application.get_env(:apiary, :features) == previous
    end
  end
end
