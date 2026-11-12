defmodule Apiary.EditionWordsTest do
  # The vocabulary rule (docs/conventions.md): an organisation is never a team, a
  # tenant or an account, and the core's files contain no module name of an edition. This
  # holds the core's prose to the words that rule and the editions keep out: its documents
  # and guides, its code, its assets and scripts, and its configuration use the words below
  # only in the rule's sentence, and contain no module name of the edition. The edition's
  # files are the edition's prose and are not held: its code, the configuration and
  # mix.exs, which call its modules to run them, and the parts of a document or the
  # stylesheet from the line that starts the edition's (`@edition_parts`). The edition's
  # guides are served at /docs with the core's and are held as theirs are, but for the
  # release commands in them (`@allowed`).
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Third-party code is not the core's prose, nor are the edition's files.
  @not_held [
    "assets/vendor",
    "lib/" <> "apiary" <> "_pro",
    "lib/" <> "apiary" <> "_pro_web",
    "lib/" <> "apiary" <> "_pro_web.ex",
    "config/config.exs",
    "config/runtime.exs",
    "config/test.exs",
    "mix.exs"
  ]

  # The line that starts the edition's part of a file: the file is held up to it.
  @edition_parts [
    {~r{^docs/access\.md$}, "## Who may do what: operators, clients and the instance"},
    {~r{^docs/architecture\.md$}, "## Tenants, operators and the organisation's level"},
    {~r{^docs/conventions\.md$}, "## Conventions of the edition"},
    {~r{^assets/css/app\.css$}, "/* ======== The edition's rules"}
  ]

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

  # The rule's sentence, on one line or across two, and the calls of the edition's release
  # functions that the admin guide shows as commands to run.
  @allowed [
    ~r/never a team,\s+a tenant\s+or\s+an\s+account/,
    Regex.compile!(
      "\\b" <> "Apiary" <> "Pro" <> "\\.Release\\.(render_organisation_policies|purge_now)\\("
    )
  ]

  # The edition's modules are named from their parts, so that this file does not
  # name them.
  @words [
    Regex.compile!("\\b" <> "Apiary" <> "Pro"),
    ~r/\btenan(t|cy|cies)/i
  ]

  defp held?(relative) do
    not Enum.any?(@not_held, &(relative == &1 or String.starts_with?(relative, &1 <> "/"))) and
      not String.starts_with?(relative, "lib/mix/tasks/" <> "apiary" <> "_pro.")
  end

  defp core_part(file, text) do
    case Enum.find(@edition_parts, fn {pattern, _start} -> file =~ pattern end) do
      {_pattern, start} -> text |> String.split(start, parts: 2) |> hd()
      nil -> text
    end
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

  # Each allowed match is blanked out, its line breaks kept, so that a finding after it
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
    if String.valid?(text), do: core_part(file, text), else: ""
  end

  test "the core's files are held, and third-party code is not" do
    whole = files(@files)

    for file <- ~w(README.md AGENTS.md TRADEMARKS.md docs/access.md docs/conventions.md
                   guides/install.md lib/apiary/access.ex lib/apiary_web/router.ex
                   lib/mix/tasks/docs.all.ex assets/js/app.js e2e/scenario.exs
                   scripts/changelog-section.sh .github/workflows/ci.yml config/dev.exs
                   Dockerfile guides/admin.md guides/operators.md guides/organisations.md
                   guides/organisation-policy.md guides/organisation-secrets.md
                   guides/organisation-variables.md guides/policy-requests.md),
        do: assert(file in whole, "#{file} is not held")

    refute "assets/vendor/topbar.js" in whole
    refute "mix.exs" in whole
  end

  test "no file of the core uses a word the vocabulary rule keeps out" do
    found = Enum.flat_map(files(@files), &findings(&1, read(&1)))

    assert found == [],
           "these core files use a word the rule keeps out:\n" <> Enum.join(found, "\n")
  end
end
