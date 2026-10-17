defmodule Apiary.Kinds.RegexFormatTest do
  use ExUnit.Case, async: true

  alias Apiary.Kinds.{RegexFormat, Schema}

  @valid [
    "",
    "a",
    "^[a-z][a-z0-9_-]*$",
    "[0-9]{4}-[0-9]{2}-[0-9]{2}",
    "(foo|bar|baz)+",
    "https?://[^/]+/.*",
    "[A-Za-z]+@example\\.com",
    "(?i)abc",
    "\\p{L}+",
    "a{2,}"
  ]

  @invalid ["(", ")", "[a-", "a{2,1}", "*a", "(?<n>a)(?<n>b)", "\\", "(?P<1>a)", "[z-a]"]

  # Runs `fun` in a new process, as the settings check does: the compiled values
  # are kept in the process dictionary.
  defp fresh(fun), do: fun |> Task.async() |> Task.await()

  defp verdict({:ok, %Regex{source: source}}), do: {:ok, source}
  defp verdict({:error, _} = error), do: error

  defp reductions do
    {:reductions, reductions} = Process.info(self(), :reductions)
    reductions
  end

  # The reductions now, once the process's heap is collected, so that a collection of
  # what came before falls outside the window measured from here.
  defp collected_reductions do
    :erlang.garbage_collect()
    reductions()
  end

  test "each pattern gets the verdict JSV's default gives, the first time and after" do
    for pattern <- @valid ++ @invalid do
      default = verdict(JSV.FormatValidator.Default.validate_cast("regex", pattern))

      assert fresh(fn ->
               for _ <- 1..2, do: verdict(RegexFormat.validate_cast("regex", pattern))
             end) == [default, default]
    end

    assert Enum.all?(@valid, &match?({:ok, _}, Regex.compile(&1)))
    assert Enum.all?(@invalid, &match?({:error, _}, Regex.compile(&1)))
  end

  test "a schema built with it accepts and refuses each value as one built with the default" do
    schema = %{"type" => "string", "format" => "regex"}
    {:ok, default} = Schema.build(schema)

    for pattern <- @valid ++ @invalid do
      expected = match?(:ok, Schema.validate(pattern, default))

      assert fresh(fn ->
               {:ok, root} = Schema.build(schema, formats: RegexFormat.formats())
               match?(:ok, Schema.validate(pattern, root))
             end) == expected
    end
  end

  test "other formats go to JSV's default modules" do
    {:ok, root} =
      Schema.build(%{"type" => "string", "format" => "email"}, formats: RegexFormat.formats())

    assert Schema.validate("someone@example.com", root) == :ok
    assert {:error, _} = Schema.validate("not an address", root)
  end

  test "a compile is charged in reductions, in proportion to the value's bytes" do
    value = String.duplicate("a", 15_000)

    {first, again} =
      fresh(fn ->
        before = collected_reductions()
        {:ok, _} = RegexFormat.validate_cast("regex", value)
        first = reductions() - before
        before = collected_reductions()
        {:ok, _} = RegexFormat.validate_cast("regex", value)
        {first, reductions() - before}
      end)

    # 10 reductions a byte, counting 8 more bytes. Measured: 9 the second time; the bound
    # leaves room for a garbage collection, and is below the charge of a compile.
    assert first >= 10 * (15_000 + 8)
    assert again < 100_000
  end

  test "a value is compiled once however many times the format applies to it" do
    value = String.duplicate("a", 15_000)

    work = fn leaves ->
      fresh(fn ->
        schema = %{"allOf" => List.duplicate(%{"format" => "regex"}, leaves)}
        {:ok, root} = Schema.build(schema, formats: RegexFormat.formats())
        before = collected_reductions()
        :ok = Schema.validate(value, root)
        reductions() - before
      end)
    end

    one = work.(1)
    many = work.(200)

    # The one compile is charged 150080 reductions; 199 more leaves add less than that.
    # Measured: 6524 more.
    assert one >= 150_080
    assert many - one < 150_080
  end

  test "after pattern_bytes/2, a value past the bytes allowed throws before its compile" do
    alias Apiary.Kinds.PatternMemory

    small = PatternMemory.estimate("^a$", [])
    large = PatternMemory.estimate("(?:a){7900}b", [])

    fresh(fn ->
      assert RegexFormat.pattern_bytes(large, large + small) == :ok
      assert {:ok, _} = RegexFormat.validate_cast("regex", "^a$")
      # A value checked before is not counted again.
      assert {:ok, _} = RegexFormat.validate_cast("regex", "^a$")

      assert catch_throw(RegexFormat.validate_cast("regex", "^b$")) ==
               {RegexFormat, :pattern_bytes}
    end)

    # Without pattern_bytes/2, values are not counted.
    fresh(fn -> assert {:ok, _} = RegexFormat.validate_cast("regex", "(?:a){7900}b") end)
  end
end
