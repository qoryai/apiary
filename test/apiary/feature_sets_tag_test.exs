defmodule Apiary.FeatureSetsTagTest do
  # CI runs every test once with every feature on, and the tests tagged :feature_sets again
  # under each other feature set. This guard fails for a test of the core's suite that
  # reads the features without the tag (`Apiary.FeatureSetsScan`), and checks the scan's
  # rules on files written here.
  use ExUnit.Case, async: true

  alias Apiary.FeatureSetsScan

  # The helpers of test/support that read the features. The refusal rows build fewer people
  # and places where a feature is off; their answers depend on the person's level, so the
  # refusals tests stay untagged. The others set the features for a test, a module or the
  # suite, and put them back.
  @helpers ~w(access_case.ex data_case.ex refusals_rows.ex test_setup.ex)

  test "every test file that reads the features is tagged :feature_sets or sets them first" do
    dir = Path.relative_to_cwd(Path.expand("..", __DIR__))

    assert Enum.map(
             FeatureSetsScan.violations([dir], helpers: @helpers),
             &FeatureSetsScan.format/1
           ) ==
             []
  end

  describe "the scan" do
    @describetag :tmp_dir

    # Writes `files`, paths under `dir` to their text, and scans `dir`.
    defp scan(dir, files, opts \\ []) do
      for {path, text} <- files do
        File.mkdir_p!(Path.dirname(Path.join(dir, path)))
        File.write!(Path.join(dir, path), text)
      end

      dir |> List.wrap() |> FeatureSetsScan.violations(opts) |> Enum.map(&relative(&1, dir))
    end

    defp relative(violation, dir),
      do: put_elem(violation, 1, Path.relative_to(elem(violation, 1), dir))

    defp module(body),
      do: "defmodule ScanFixtureTest do\n  use ExUnit.Case\n" <> body <> "\nend\n"

    @reads ~s|test "reads" do\n    assert Apiary.Features.on?(:security)\n  end\n|

    test "fails for a test that reads the features, untagged", %{tmp_dir: dir} do
      assert scan(dir, %{"a_test.exs" => module(@reads)}) ==
               [{:untagged, "a_test.exs", "reads"}]
    end

    test "fails for a test that reads them in a setup or a helper of its file",
         %{tmp_dir: dir} do
      helper = """
      defp total, do: count() + 1
        defp count, do: length(Application.get_env(:apiary, :features))
        test "a", do: assert(total() > 0)
        test "b", do: :ok
      """

      setup = """
      describe "c" do
          setup do
            %{off: Apiary.TestSetup.off()}
          end

          test "c", do: :ok
        end

        test "d", do: :ok
      """

      named =
        ~s|setup :off\n  defp off(_), do: %{off: Apiary.TestSetup.off()}\n  test "e", do: :ok|

      assert scan(dir, %{
               "a_test.exs" => module(helper),
               "b_test.exs" => module(setup),
               "c_test.exs" => module(named)
             }) ==
               [
                 {:untagged, "a_test.exs", "a"},
                 {:untagged, "b_test.exs", "c"},
                 {:untagged, "c_test.exs", "e"}
               ]
    end

    test "decides for each test, not for its file", %{tmp_dir: dir} do
      # Tests that set their features beside tests that read them through a helper, with
      # neither with_features: nor :feature_sets.
      body = """
      defp total, do: if(Apiary.Features.on?(:factory), do: 2, else: 1)

        @tag with_features: [:observability]
        test "set", do: assert(total() == 1)

        describe "set by the describe" do
          @describetag with_features: [:observability, :security]
          test "inherits", do: assert(total() == 1)
        end

        @tag :feature_sets
        test "tagged", do: assert(total() > 0)

        test "untagged", do: assert(total() > 0)
      """

      assert scan(dir, %{"a_test.exs" => module(body)}) ==
               [{:untagged, "a_test.exs", "untagged"}]
    end

    test "passes a file with a test tagged :feature_sets, by @tag or @moduletag",
         %{tmp_dir: dir} do
      assert scan(dir, %{
               "a_test.exs" => module("@tag :feature_sets\n  " <> @reads),
               "b_test.exs" => module("@moduletag :feature_sets\n  " <> @reads)
             }) == []
    end

    test "passes a test under with_features: of the test, its describe or its module",
         %{tmp_dir: dir} do
      describe = """
      describe "d" do
          @describetag with_features: [:observability]
          #{@reads}
        end
      """

      assert scan(dir, %{
               "a_test.exs" => module("@tag with_features: [:observability]\n  " <> @reads),
               "b_test.exs" => module(describe),
               "c_test.exs" => module("@moduletag with_features: [:security]\n  " <> @reads)
             }) == []
    end

    test "fails for a test that reads after without_registry or a put_env", %{tmp_dir: dir} do
      # Both change the suite's features, which still vary with the set.
      restore = """
      setup do
          setting = Application.get_env(:apiary, :features_setting)
          on_exit(fn -> Application.put_env(:apiary, :features, setting) end)
        end
      """

      put_env = """
      setup do
          Application.put_env(:apiary, :features, Apiary.Features.all() -- [:registry])
          on_exit(fn -> Application.put_env(:apiary, :features, []) end)
        end
      """

      assert scan(dir, %{
               "a_test.exs" => module("setup {Apiary.DataCase, :without_registry}\n  " <> @reads),
               "b_test.exs" => module(restore <> ~s|  test "b", do: :ok|),
               "c_test.exs" => module(put_env <> @reads)
             }) == [
               {:untagged, "a_test.exs", "reads"},
               {:untagged, "b_test.exs", "b"},
               {:untagged, "c_test.exs", "reads"}
             ]
    end

    test "reads fetch_env and fetch_env! of the features", %{tmp_dir: dir} do
      assert scan(dir, %{
               "a_test.exs" =>
                 module(~s|test "a", do: Application.fetch_env!(:apiary, :features)|),
               "b_test.exs" => module(~s|test "b", do: Application.fetch_env(:apiary, :features)|)
             }) == [{:untagged, "a_test.exs", "a"}, {:untagged, "b_test.exs", "b"}]
    end

    test "passes a file whose reading tests need a feature that runs under one set",
         %{tmp_dir: dir} do
      assert scan(dir, %{"a_test.exs" => module("@tag needs: :factory\n  " <> @reads)}) == []

      assert scan(dir, %{"b_test.exs" => module("@tag needs: :security\n  " <> @reads)}) ==
               [{:untagged, "b_test.exs", "reads"}]
    end

    test "fails for a file tagged :feature_sets that reads nothing", %{tmp_dir: dir} do
      body = "@moduletag :feature_sets\n  test \"a\", do: :ok"
      assert scan(dir, %{"a_test.exs" => module(body)}) == [{:reads_nothing, "a_test.exs"}]
    end

    test "fails for a test tagged both with_features: and :feature_sets", %{tmp_dir: dir} do
      body = "@moduletag :feature_sets\n  @tag with_features: [:observability]\n  " <> @reads

      assert scan(dir, %{"a_test.exs" => module(body)}) == [
               {:both_tags, "a_test.exs", "reads"}
             ]
    end

    test "reads no comment, string, @moduledoc or @doc", %{tmp_dir: dir} do
      body = """
      @moduledoc "Apiary.Features.on?/1"
        # Apiary.Features.enabled()
        test "a", do: assert("Apiary.Features.on?(:security)")
      """

      assert scan(dir, %{"a_test.exs" => module(body)}) == []
    end

    test "skips the tests of a module of register: false", %{tmp_dir: dir} do
      text = """
      defmodule ScanFixtureTest do
        use ExUnit.Case, register: false
        @moduletag :feature_sets
        @tag with_features: [:observability]
        test "a", do: Apiary.Features.on?(:security)
      end
      """

      assert scan(dir, %{"a_test.exs" => text}) == []
    end

    test "fails for a helper of support/ that reads the features and is not listed",
         %{tmp_dir: dir} do
      helper = "defmodule ScanHelper do\n  def on?, do: Apiary.Features.on?(:security)\nend\n"

      assert scan(dir, %{"support/scan_helper.ex" => helper}) ==
               [{:unknown_helper, "support/scan_helper.ex"}]

      assert scan(dir, %{}, helpers: ["scan_helper.ex"]) == []
    end

    test "takes an edition's reads", %{tmp_dir: dir} do
      text = module(~s|test "a", do: Edition.Features.of(:x)|)

      assert scan(dir, %{"a_test.exs" => text}) == []

      assert scan(dir, %{}, reads: [~r/Edition\.Features\.of\b/]) ==
               [{:untagged, "a_test.exs", "a"}]
    end
  end
end
