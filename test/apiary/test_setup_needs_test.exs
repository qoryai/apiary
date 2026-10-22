defmodule Apiary.TestSetupNeedsTest.Rows do
  @moduledoc false
  # Rows as `ApiaryWeb.RefusalsCase` reads them: one with a list in `needs:`, one with a
  # single feature, one with no `needs:`.
  def rows do
    [
      {:"secret.write", :member, "/:org/:workspace/settings/secrets", "create_secret", %{},
       needs: [:security, :secrets]},
      {:"secret.write", :member, "/:org/:workspace/settings/secrets", "delete_secret", %{},
       needs: :secrets},
      {:"member.change_level", :member, "/:org/settings/people", "set_level", %{}}
    ]
  end
end

defmodule Apiary.TestSetupNeedsTest.Cases do
  @moduledoc false
  # Tests tagged with `needs:` in each way, in a module with the hook `Apiary.DataCase`
  # and `ApiaryWeb.ConnCase` set. Not registered with ExUnit: the tests of
  # `Apiary.TestSetupNeedsTest` read their tags and do not run them.
  use ExUnit.Case, register: false

  @before_compile Apiary.TestSetup

  test "no tag", do: :ok

  @tag needs: :factory
  test "single feature", do: :ok

  @tag needs: [:security, :factory]
  test "two features", do: :ok

  @tag needs: [:factory]
  test "list of one", do: :ok

  @tag needs: []
  test "empty list", do: :ok

  describe "a described group" do
    @describetag needs: [:secrets, :path_rules]

    test "tagged by the describe", do: :ok
  end

  # What the refusals template does for each row: the row's `needs` is the test's tag.
  for {row, n} <- Enum.with_index(ApiaryWeb.RefusalsCase.rows([Apiary.TestSetupNeedsTest.Rows])) do
    @tag refusal: row, needs: row.needs
    test "row #{n}", do: :ok
  end
end

defmodule Apiary.TestSetupNeedsTest.ModuleList do
  @moduledoc false
  use ExUnit.Case, register: false

  @before_compile Apiary.TestSetup
  @moduletag needs: [:observability, :security]

  test "takes the module's list", do: :ok

  @tag needs: :factory
  test "replaces the module's list", do: :ok

  @tag needs: [:secrets, :factory]
  test "replaces the module's list with another", do: :ok
end

defmodule Apiary.TestSetupNeedsTest.NoHook do
  @moduledoc false
  use ExUnit.Case, register: false

  @tag needs: [:security, :factory]
  test "two features", do: :ok
end

defmodule Apiary.TestSetupNeedsTest do
  # `Apiary.TestSetup` leaves out a test whose `needs:` lists a feature that is off.
  # Not async: the tests set the features the suite runs without, which the modules read
  # when the runner asks them for their tests.
  use Apiary.DataCase, async: false

  alias Apiary.TestSetupNeedsTest.{Cases, ModuleList, NoHook}

  # Without the hook of `Apiary.DataCase`, `unhooked/0` lists this module in a run with
  # every feature on.
  @tag needs: [:security, :factory]
  test "a module under Apiary.DataCase takes a list in needs:" do
    assert Enum.all?([:security, :factory], &Apiary.Features.on?/1)
  end

  # What the runner does with a module's tests: the filter for each feature that is off
  # (`Apiary.TestSetup.start!/1` builds the same), applied to each test's tags. A map of
  # the tests' names to `:run` or `:left_out`.
  defp outcomes(module, off) do
    :persistent_term.put({Apiary.TestSetup, :off}, off)

    exclude = for feature <- off, do: {:needs, feature}

    Map.new(module.__ex_unit__().tests, fn test ->
      outcome =
        case ExUnit.Filters.eval([], exclude, test.tags, []) do
          :ok -> :run
          {:excluded, _} -> :left_out
        end

      {to_string(test.name), outcome}
    end)
  end

  setup do
    previous = :persistent_term.get({Apiary.TestSetup, :off}, nil)

    on_exit(fn ->
      if previous,
        do: :persistent_term.put({Apiary.TestSetup, :off}, previous),
        else: :persistent_term.erase({Apiary.TestSetup, :off})
    end)
  end

  defp outcome(outcomes, name) do
    case Enum.filter(outcomes, fn {key, _} -> String.ends_with?(key, name) end) do
      [{_, outcome}] -> outcome
      other -> flunk("expected one test ending in #{inspect(name)}, got #{inspect(other)}")
    end
  end

  describe "a list in needs:" do
    test "is left out when one of its features is off" do
      assert outcome(outcomes(Cases, [:factory]), "two features") == :left_out
      assert outcome(outcomes(Cases, [:security]), "two features") == :left_out
      assert outcome(outcomes(Cases, [:security, :factory]), "two features") == :left_out
    end

    test "runs when every feature of it is on" do
      assert outcome(outcomes(Cases, []), "two features") == :run
      assert outcome(outcomes(Cases, [:secrets, :path_rules]), "two features") == :run
    end

    test "of one feature is left out when that feature is off" do
      assert outcome(outcomes(Cases, [:factory]), "list of one") == :left_out
      assert outcome(outcomes(Cases, [:security]), "list of one") == :run
    end

    test "that is empty needs no feature" do
      assert outcome(outcomes(Cases, [:factory, :security]), "empty list") == :run
    end

    test "of a describe is left out when one of its features is off" do
      assert outcome(outcomes(Cases, [:path_rules]), "tagged by the describe") == :left_out
      assert outcome(outcomes(Cases, [:factory]), "tagged by the describe") == :run
    end

    test "of a module is left out when one of its features is off" do
      assert outcome(outcomes(ModuleList, [:security]), "takes the module's list") ==
               :left_out

      assert outcome(outcomes(ModuleList, [:observability]), "takes the module's list") ==
               :left_out

      assert outcome(outcomes(ModuleList, [:factory]), "takes the module's list") == :run
    end

    test "of a test replaces the list of the module" do
      off = [:observability, :security]

      assert outcome(outcomes(ModuleList, off), "replaces the module's list") == :run

      assert outcome(outcomes(ModuleList, [:secrets]), "replaces the module's list with another") ==
               :left_out
    end

    test "raises in ExUnit's filter in a module without the hook" do
      [test] = NoHook.__ex_unit__().tests

      assert_raise ArgumentError, ~r/cannot convert the given list to a string/, fn ->
        ExUnit.Filters.eval([], [needs: :factory], test.tags, [])
      end
    end

    test "with an element that is no feature raises" do
      assert_raise ArgumentError, ~r/needs: is a feature or a list of features/, fn ->
        Apiary.TestSetup.needs_tag(["factory"], [])
      end
    end
  end

  describe "a single feature in needs:" do
    test "is left out when it is off" do
      assert outcome(outcomes(Cases, [:factory]), "single feature") == :left_out
    end

    test "runs when it is on" do
      assert outcome(outcomes(Cases, []), "single feature") == :run
      assert outcome(outcomes(Cases, [:security]), "single feature") == :run
    end

    test "of a test replaces the feature of the module" do
      assert outcome(outcomes(ModuleList, [:factory]), "replaces the module's list") ==
               :left_out

      assert outcome(outcomes(ModuleList, [:security]), "replaces the module's list") == :run
    end

    test "is the tag as it was written" do
      assert Apiary.TestSetup.needs_tag(:factory, [:factory]) == :factory
      assert Apiary.TestSetup.needs_tag(:factory, []) == :factory
      assert Apiary.TestSetup.needs_tag(nil, [:factory]) == nil
    end
  end

  test "a test with no needs: runs whatever is off" do
    assert outcome(outcomes(Cases, [:factory, :security, :secrets]), "no tag") == :run
  end

  describe "a row of the refusals template" do
    test "keeps the list its rows module gives" do
      needs =
        ApiaryWeb.RefusalsCase.rows([Apiary.TestSetupNeedsTest.Rows]) |> Enum.map(& &1.needs)

      assert needs == [[:security, :secrets], :secrets, nil]
    end

    test "with a list is left out when one of its features is off" do
      assert outcome(outcomes(Cases, [:secrets]), "row 0") == :left_out
      assert outcome(outcomes(Cases, [:security]), "row 0") == :left_out
      assert outcome(outcomes(Cases, [:factory]), "row 0") == :run
    end

    test "with a single feature or none keeps its tag" do
      assert outcome(outcomes(Cases, [:secrets]), "row 1") == :left_out
      assert outcome(outcomes(Cases, [:security]), "row 1") == :run
      assert outcome(outcomes(Cases, [:secrets, :security]), "row 2") == :run
    end
  end

  test "every module of the suite that tags needs: with a list has the hook" do
    assert Enum.reject(Apiary.TestSetup.unhooked(), fn {module, _} -> module == NoHook end) ==
             []

    assert [{NoHook, _}] =
             Enum.filter(Apiary.TestSetup.unhooked(), fn {module, _} -> module == NoHook end)
  end

  test "off/0 is the features the suite runs without" do
    :persistent_term.erase({Apiary.TestSetup, :off})

    assert Apiary.TestSetup.off() == Apiary.Features.all() -- Apiary.Features.enabled()
  end
end

defmodule ApiaryWeb.TestSetupNeedsConnTest do
  # The same for a module under `ApiaryWeb.ConnCase`.
  use ApiaryWeb.ConnCase, async: false

  @tag needs: [:security, :factory]
  test "a module under ApiaryWeb.ConnCase takes a list in needs:" do
    assert Enum.all?([:security, :factory], &Apiary.Features.on?/1)
  end
end
