defmodule Apiary.Stacks.DocumentTest do
  # `Apiary.Stacks.Document.harness_sources/1`: the harness sources a document refers to.
  # Pure, so async.
  use ExUnit.Case, async: true

  alias Apiary.Stacks.Document

  @git "https://code.example.com/team/harness"
  @sha String.duplicate("a", 40)

  describe "harness_sources/1" do
    test "lists a base with a path" do
      text = """
      extends:
        git: #{@git}
        ref: main
        path: stacks/web
      """

      assert Document.harness_sources(text) == [
               %{"git" => @git, "ref" => "main", "path" => "stacks/web"}
             ]
    end

    test "lists a base with a stack" do
      text = """
      extends:
        git: #{@git}
        ref: main
        stack: web
      """

      assert Document.harness_sources(text) == [
               %{"git" => @git, "ref" => "main", "stack" => "web"}
             ]
    end

    test "lists a bare git and ref base" do
      text = "extends: {git: #{@git}, ref: #{@sha}}"

      assert Document.harness_sources(text) == [%{"git" => @git, "ref" => @sha}]
    end

    test "lists the sources of modules with a path, a stack and a module" do
      text = """
      modules:
        - source: {git: #{@git}, ref: v1, path: modules/a}
        - source: {git: #{@git}, ref: v2, stack: web}
        - source: {git: #{@git}, ref: v3, module: lint}
      """

      assert Document.harness_sources(text) == [
               %{"git" => @git, "ref" => "v1", "path" => "modules/a"},
               %{"git" => @git, "ref" => "v2", "stack" => "web"},
               %{"git" => @git, "ref" => "v3", "module" => "lint"}
             ]
    end

    test "lists the base first, then the modules in document order" do
      text = """
      modules:
        - source: {git: https://code.example.com/team/two, ref: b}
        - source: {git: https://code.example.com/team/one, ref: a}
      extends: {git: #{@git}, ref: main}
      """

      assert Enum.map(Document.harness_sources(text), & &1["git"]) == [
               @git,
               "https://code.example.com/team/two",
               "https://code.example.com/team/one"
             ]
    end

    test "leaves out an entry without ref" do
      text = """
      extends: {git: #{@git}, path: stacks/web}
      modules:
        - source: {git: #{@git}}
        - source: {git: #{@git}, ref: kept}
      """

      assert Document.harness_sources(text) == [%{"git" => @git, "ref" => "kept"}]
    end

    test "leaves out an entry without git" do
      text = """
      extends: {stack: web}
      modules:
        - source: {ref: main}
        - name: no source
      """

      assert Document.harness_sources(text) == []
    end

    test "leaves out an entry with two narrowing keys" do
      text = """
      extends: {git: #{@git}, ref: main, path: a, stack: web}
      modules:
        - source: {git: #{@git}, ref: main, path: a, module: lint}
        - source: {git: #{@git}, ref: kept, path: a}
      """

      assert Document.harness_sources(text) == [
               %{"git" => @git, "ref" => "kept", "path" => "a"}
             ]
    end

    test "leaves out an entry whose values are not text" do
      text = """
      extends: {git: #{@git}, ref: 12}
      modules:
        - source: {git: #{@git}, ref: main, path: 7}
      """

      assert Document.harness_sources(text) == []
    end

    test "gives [] for text that does not read" do
      assert Document.harness_sources("extends: [unclosed") == []
      assert Document.harness_sources("a: &x 1\nb: *x") == []
      assert Document.harness_sources("a: 1\n---\nb: 2") == []
      assert Document.harness_sources(String.duplicate("x", 70_000)) == []
    end

    test "gives [] for a document that is not a mapping" do
      assert Document.harness_sources("- a\n- b") == []
      assert Document.harness_sources("just text") == []
      assert Document.harness_sources("") == []
    end

    test "gives [] when extends or modules have another shape" do
      assert Document.harness_sources("extends: main\nmodules: web") == []
      assert Document.harness_sources("modules: [a, {source: b}]") == []
    end

    test "gives [] for nil" do
      assert Document.harness_sources(nil) == []
    end

    test "keeps the strings as written" do
      git = "HTTPS://Code.Example.com/Team/Harness.git/"
      text = "extends: {git: '#{git}', ref: Main, path: Stacks/Web/}"

      assert Document.harness_sources(text) == [
               %{"git" => git, "ref" => "Main", "path" => "Stacks/Web/"}
             ]
    end

    test "leaves out keys that are not part of a source" do
      text = "extends: {git: #{@git}, ref: main, link: x, name: y}"

      assert Document.harness_sources(text) == [%{"git" => @git, "ref" => "main"}]
    end
  end
end
