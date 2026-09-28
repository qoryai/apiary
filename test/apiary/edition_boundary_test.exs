defmodule Apiary.EditionBoundaryTest do
  # The core names no edition: it asks `Apiary.Edition` and `ApiaryWeb.Edition`, which the
  # configuration points at one, and compiles and runs without any. This holds its code,
  # its tests and its configuration to that.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # The pro edition's modules and application, each name built from its parts, so that
  # this file does not name them.
  @edition [
    Regex.compile!("\\b" <> "Apiary" <> "Pro" <> "(Web)?\\b"),
    Regex.compile!("\\b" <> "apiary" <> "_pro" <> "(_web)?\\b")
  ]

  @patterns ["lib/**/*.{ex,exs,heex}", "test/**/*.{ex,exs,heex}", "config/*.exs", "*.exs"]

  defp core_files do
    for pattern <- @patterns,
        path <- Path.wildcard(Path.join(@root, pattern), match_dot: true),
        do: Path.relative_to(path, @root)
  end

  test "the core's code, tests and configuration are found" do
    files = core_files()

    for file <- ~w(lib/apiary/edition.ex lib/mix/tasks/docs.all.ex config/config.exs
                   test/apiary/edition_boundary_test.exs mix.exs .formatter.exs),
        do: assert(file in files, "#{file} is not found")
  end

  test "no file of the core names the pro edition" do
    naming =
      for file <- core_files(),
          text = File.read!(Path.join(@root, file)),
          Enum.any?(@edition, &(text =~ &1)),
          do: file

    assert naming == [], "these core files name the pro edition: #{Enum.join(naming, ", ")}"
  end
end
