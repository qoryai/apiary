defmodule Apiary.Kinds.SchemaAtomsTest do
  # A settings schema comes from a description, and JSV casts can make atoms of the values
  # it checks or of its property names; atoms are never freed, and a full atom table stops
  # the node. Schemas are built with `atoms: false` and values validated with
  # `cast: false`, so a check makes no atom. The count of atoms is the whole node's, so the
  # module runs alone, and each case runs once first, so that loading its code is not
  # counted.
  use ExUnit.Case, async: false

  import Apiary.DescriptionFixtures
  import ExUnit.CaptureIO

  alias Apiary.Integrations.Description
  alias Apiary.Kinds.Schema

  defp settings_with(url) do
    assert {:ok, description} =
             tracker_description()
             |> put_in(["settings", "properties", "url"], url)
             |> encode()
             |> Description.parse()

    description
  end

  # The atoms `fun` makes, once it has run once: the fewest of three runs. Another process
  # can load code meanwhile, such as the formatter printing an earlier test's failure,
  # which makes a few atoms that `fun` did not; a run that makes atoms makes them every
  # time.
  defp atoms_made(fun) do
    fun.()

    Enum.min(
      for _ <- 1..3 do
        before = :erlang.system_info(:atom_count)
        fun.()
        :erlang.system_info(:atom_count) - before
      end
    )
  end

  test "1000 checks through a string_to_atom cast, in either spelling, make no atom" do
    for cast <- [
          %{"jsv-cast" => ["Elixir.JSV.Cast", "string_to_atom"]},
          %{"x-jsv-cast" => [["Elixir.JSV.Cast", "string_to_atom"]]},
          %{"jsv-cast" => ["Elixir.JSV.Cast", "string_to_atom_or_nil"]}
        ] do
      description = settings_with(Map.put(cast, "type", "string"))
      run = System.unique_integer([:positive])

      checks = fn ->
        for i <- 1..1000 do
          settings = %{"url" => "atom-#{run}-#{i}-#{System.unique_integer([:positive])}"}
          assert Description.check_settings(description, settings) == :ok
        end
      end

      assert atoms_made(checks) == 0
    end
  end

  test "no cast the schema names is called on a value" do
    # Called, the cast would refuse a string that is no integer.
    description =
      settings_with(%{"type" => "string", "jsv-cast" => ["Elixir.JSV.Cast", "string_to_integer"]})

    assert Description.check_settings(description, %{"url" => "not a number"}) == :ok
  end

  test "a list of 1024 strings through the cast makes no atom" do
    description =
      settings_with(%{
        "type" => "array",
        "items" => %{"jsv-cast" => ["Elixir.JSV.Cast", "string_to_atom"]}
      })

    check = fn ->
      run = System.unique_integer([:positive])
      list = for i <- 1..1024, do: "atom-list-#{run}-#{i}"
      assert Description.check_settings(description, %{"url" => list}) == :ok
    end

    assert atoms_made(check) == 0
  end

  test "a build with the aprops cast makes no atom of the property names" do
    build = fn ->
      run = System.unique_integer([:positive])
      properties = Map.new(1..1000, &{"atom_#{run}_p#{&1}", %{"type" => "string"}})

      schema = %{
        "type" => "object",
        "jsv-cast" => ["Elixir.JSV.Cast", "aprops"],
        "properties" => properties
      }

      assert {:ok, _root} = Schema.build(schema)
    end

    assert atoms_made(build) == 0
  end

  test "building a schema with an atom cast writes no warning" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "a" => %{"type" => "string", "jsv-cast" => ["Elixir.JSV.Cast", "string_to_atom"]},
        "b" => %{"x-jsv-cast" => [["Elixir.JSV.Cast", "string_to_atom"]]}
      },
      "jsv-cast" => ["Elixir.JSV.Cast", "aprops"]
    }

    assert capture_io(:stderr, fn -> assert {:ok, _root} = Schema.build(schema) end) == ""
  end
end
