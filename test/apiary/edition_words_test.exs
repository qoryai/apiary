defmodule Apiary.EditionWordsTest do
  # The vocabulary rule (docs/conventions.md): an organisation is never a team, a
  # tenant or an account, and the core names no edition's module. This holds the core's
  # prose to the words that rule and the editions keep out: its documents and guides, its
  # code, its assets and scripts, and its configuration use the words below only in the
  # rule's own sentence, and name no module of the pro edition.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Third-party code is not the core's prose.
  @not_held ["assets/vendor"]

  # Read whole.
  @files [
    "*.md",
    "docs/**/*.md",
    "guides/**/*.md",
    "lib/**/*",
    "storybook/**/*",
    "assets/**/*",
    "e2e/**/*",
    "rel/**/*",
    "scripts/**/*",
    ".github/**/*",
    "config/*.exs",
    "mix.exs",
    "Dockerfile"
  ]

  # The rule's own sentence, on one line or across two.
  @allowed [~r/never a team,\s+a tenant\s+or\s+an\s+account/]

  # The pro edition's modules are named from their parts, so that this file does not
  # name them.
  @words [
    Regex.compile!("\\b" <> "Apiary" <> "Pro"),
    ~r/\btenan(t|cy|cies)/i
  ]

  defp held?(relative) do
    not Enum.any?(@not_held, &(relative == &1 or String.starts_with?(relative, &1 <> "/")))
  end

  defp files(patterns) do
    for pattern <- patterns,
        path <- Path.wildcard(Path.join(@root, pattern), match_dot: true),
        File.regular?(path),
        relative = Path.relative_to(path, @root),
        held?(relative),
        uniq: true,
        do: relative
  end

  # The rule's sentence is blanked out, its line breaks kept, so that a finding after it
  # keeps its line number.
  defp findings(file, text) do
    text =
      Enum.reduce(@allowed, text, fn allowed, text ->
        Regex.replace(allowed, text, &String.replace(&1, ~r/[^\n]/, ""))
      end)

    for {line, number} <- Enum.with_index(String.split(text, "\n"), 1),
        word <- @words,
        [match | _] <- [Regex.run(word, line)],
        do: "#{file}:#{number}: #{match}"
  end

  defp read(file) do
    text = File.read!(Path.join(@root, file))
    if String.valid?(text), do: text, else: ""
  end

  test "the core's files are held, and third-party code is not" do
    whole = files(@files)

    for file <- ~w(README.md AGENTS.md EDITIONS.md docs/access.md docs/conventions.md
                   guides/install.md lib/apiary/access.ex lib/apiary_web/router.ex
                   lib/mix/tasks/docs.all.ex assets/js/app.js e2e/scenario.exs
                   scripts/changelog-section.sh .github/workflows/ci.yml config/runtime.exs
                   mix.exs Dockerfile),
        do: assert(file in whole, "#{file} is not held")

    refute "assets/vendor/topbar.js" in whole
  end

  test "no file of the core uses a word the vocabulary rule keeps out" do
    found = Enum.flat_map(files(@files), &findings(&1, read(&1)))

    assert found == [],
           "these core files use a word the rule keeps out:\n" <> Enum.join(found, "\n")
  end
end
