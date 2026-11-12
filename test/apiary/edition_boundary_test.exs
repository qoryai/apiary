defmodule Apiary.EditionBoundaryTest do
  # The core names no edition: it asks `Apiary.Edition` and `ApiaryWeb.Edition`, which the
  # configuration points at one. This holds the core's code to that. The edition's modules
  # (the edition's, which moved into this repository), the configuration that names them, and the
  # tests, which check the product as it runs with them, are not held.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # The edition's modules and application, each name built from its parts, so that
  # this file does not name them.
  @edition [
    Regex.compile!("\\b" <> "Apiary" <> "Pro" <> "(Web)?\\b"),
    Regex.compile!("\\b" <> "apiary" <> "_pro" <> "(_web)?\\b")
  ]

  @patterns [
    "lib/**/*.{ex,exs,heex}",
    "storybook/**/*.{ex,exs}"
  ]

  # The edition's code, its files' names built as the modules' are.
  @edition_code [
    "lib/" <> "apiary" <> "_pro/",
    "lib/" <> "apiary" <> "_pro_web/",
    "lib/" <> "apiary" <> "_pro_web.ex",
    "lib/mix/tasks/" <> "apiary" <> "_pro."
  ]

  defp core_files do
    for pattern <- @patterns,
        path <- Path.wildcard(Path.join(@root, pattern), match_dot: true),
        relative = Path.relative_to(path, @root),
        not Enum.any?(@edition_code, &String.starts_with?(relative, &1)),
        do: relative
  end

  test "the core's code is found, and the edition's is not" do
    files = core_files()

    for file <- ~w(lib/apiary/edition.ex lib/apiary_web/router.ex lib/mix/tasks/docs.all.ex
                   storybook/storybook.ex),
        do: assert(file in files, "#{file} is not found")

    refute Enum.any?(files, &String.starts_with?(&1, @edition_code))
  end

  test "no file of the core names the edition" do
    naming =
      for file <- core_files(),
          text = File.read!(Path.join(@root, file)),
          Enum.any?(@edition, &(text =~ &1)),
          do: file

    assert naming == [], "these core files name the edition: #{Enum.join(naming, ", ")}"
  end
end
