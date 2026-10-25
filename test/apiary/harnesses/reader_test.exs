defmodule Apiary.Harnesses.ReaderTest do
  # The reader of qory's harness files, against the fixture set under
  # test/fixtures/harness/v1/sources/ and against hand-written refusals of each limit.
  use ExUnit.Case, async: true

  alias Apiary.Harnesses.Reader

  @sources Path.expand("../../fixtures/harness/v1/sources", __DIR__)

  defp source(path), do: File.read!(Path.join(@sources, path))

  @harness "https://code.example.com/example-org/harness"
  @modules "https://code.example.com/example-org/modules"

  describe "harness/1" do
    test "reads a base by export" do
      assert {:ok, %{"extends" => base, "target" => %{"runtime" => "claude"}}} =
               Reader.harness(source("extends-export/qory.yaml"))

      assert base == %{"git" => @harness, "ref" => "v2.4.0", "stack" => "web"}
    end

    test "reads a base by a folder of a remote source" do
      assert {:ok, %{"extends" => base}} = Reader.harness(source("extends-git-path/qory.yaml"))

      assert base == %{
               "git" => @harness,
               "ref" => "0123456789abcdef0123456789abcdef01234567",
               "path" => "stacks/web"
             }
    end

    test "reads a base at the root of a remote source" do
      assert {:ok, %{"extends" => %{"git" => @harness, "ref" => "main"} = base}} =
               Reader.harness(source("extends-root/qory.yaml"))

      assert map_size(base) == 2
    end

    test "reads a base by path" do
      assert {:ok, %{"extends" => %{"path" => "./harness/stacks/web"}}} =
               Reader.harness(source("extends-path/qory.yaml"))
    end

    test "reads modules by name, by path, by git and by export" do
      assert {:ok, %{"modules" => [%{"name" => "app"}]}} =
               Reader.harness(source("modules-by-name/qory.yaml"))

      assert {:ok, %{"modules" => [%{"name" => "team", "source" => %{"path" => "./harness"}}]}} =
               Reader.harness(source("modules-by-path/qory.yaml"))

      assert {:ok, %{"modules" => [%{"source" => git, "variant" => "claude"}]}} =
               Reader.harness(source("modules-by-git/qory.yaml"))

      assert git == %{"git" => @modules, "ref" => "v1.0.0", "path" => "modules/review"}

      assert {:ok, %{"modules" => [module]}} =
               Reader.harness(source("modules-by-export/qory.yaml"))

      assert module == %{
               "name" => "marketing",
               "source" => %{"git" => @harness, "ref" => "v2.4.0", "module" => "marketing"},
               "only" => %{"skills" => ["campaign"]}
             }
    end

    test "reads the second name of the file as the first" do
      assert {:ok, %{"extends" => %{"stack" => "web"}}} =
               Reader.harness(source("harness-name/harness.yaml"))
    end

    test "a section with the machine's keys alone, no section and an empty file are :none" do
      assert Reader.harness(source("machine-keys-only/qory.yaml")) == :none
      assert Reader.harness(source("no-harness/qory.yaml")) == :none
      assert Reader.harness("") == :none
      assert Reader.harness("# a comment only\n") == :none
      assert Reader.harness("harness:\n") == :none
      assert Reader.harness("harness: {}\n") == :none
    end

    test "a section with any key beside the machine's keys is returned as written" do
      assert {:ok, %{"runtime" => "claude", "target" => %{"runtime" => "claude"}}} =
               Reader.harness("harness:\n  runtime: claude\n  target: {runtime: claude}\n")
    end

    test "refuses a harness section that is not a mapping, and a file that is not one" do
      assert Reader.harness("harness: [a]\n") == {:error, :invalid_harness}
      assert Reader.harness("harness: text\n") == {:error, :invalid_harness}
      assert Reader.harness("- a\n") == {:error, :not_a_mapping}
    end
  end

  describe "stack_modules/1" do
    test "reads the modules of a qory-stack.yaml" do
      assert {:ok, [core, review, lint]} = Reader.stack_modules(source("stack/qory-stack.yaml"))
      assert core == %{"name" => "core"}

      assert review["source"] == %{
               "git" => @modules,
               "ref" => "v1.0.0",
               "path" => "modules/review"
             }

      assert lint["source"] == %{"git" => @modules, "ref" => "v1.0.0", "module" => "lint"}
    end

    test "refuses a stack without modules, or with a module that is not a mapping" do
      assert Reader.stack_modules("name: web\n") == {:error, :invalid_stack}
      assert Reader.stack_modules("modules: []\n") == {:error, :invalid_stack}
      assert Reader.stack_modules("modules: [core]\n") == {:error, :invalid_stack}
      assert Reader.stack_modules("") == {:error, :invalid_stack}
    end
  end

  describe "exports/1" do
    test "reads the stacks a root file exports, and where they are" do
      assert {:ok, %{dir: nil, stacks: ["web", "api"]} = root} =
               Reader.exports(source("exports-root/qory.yaml"))

      assert Reader.stack_file(root, "web") == "stacks/web/qory-stack.yaml"

      assert {:ok, %{dir: "./harness", stacks: ["web"]} = dir} =
               Reader.exports(source("exports-dir/qory.yaml"))

      assert Reader.stack_file(dir, "web") == "./harness/stacks/web/qory-stack.yaml"

      assert {:ok, %{dir: %{"stacks" => "delivered/stacks"}, stacks: ["web"]} = map} =
               Reader.exports(source("exports-dir-map/harness.yaml"))

      assert Reader.stack_file(map, "web") == "delivered/stacks/web/qory-stack.yaml"
    end

    test "a file without exports is :none" do
      assert Reader.exports(source("extends-export/qory.yaml")) == :none
      assert Reader.exports("") == :none
    end

    test "refuses exports of the wrong shape" do
      assert Reader.exports("exports: [web]\n") == {:error, :invalid_exports}
      assert Reader.exports("exports: {stacks: web}\n") == {:error, :invalid_exports}
      assert Reader.exports("exports: {stacks: [1]}\n") == {:error, :invalid_exports}
      assert Reader.exports("exports: {dir: {stacks: a}}\n") == {:error, :invalid_exports}
      assert Reader.exports("exports: {dir: ''}\n") == {:error, :invalid_exports}
    end
  end

  describe "document/1" do
    test "reads a settings row's document, the contents of a harness section" do
      assert {:ok, %{"extends" => %{"git" => @harness, "ref" => "main"}}} =
               Reader.document("extends: {git: #{@harness}, ref: main}\n")
    end

    test "refuses a document that is not a mapping" do
      assert Reader.document("") == {:error, :not_a_mapping}
      assert Reader.document("- a\n") == {:error, :not_a_mapping}
      assert Reader.document("text\n") == {:error, :not_a_mapping}
    end
  end

  describe "limits" do
    test "refuses an anchor and an alias" do
      assert Reader.harness(source("refused/alias.yaml")) == {:error, :alias}
      assert Reader.harness(source("refused/anchor.yaml")) == {:error, :alias}
      assert Reader.parse("a: &x 1\n") == {:error, :alias}
      assert Reader.parse("a: *x\n") == {:error, :alias}
    end

    test "refuses an alias bomb before anything expands it" do
      bomb =
        Enum.map_join(1..9, "", fn level ->
          refs = Enum.map_join(1..9, ", ", fn _ -> "*l#{level - 1}" end)
          "l#{level}: &l#{level} [#{refs}]\n"
        end)

      bomb = "l0: &l0 [lol]\n" <> bomb
      {time, result} = :timer.tc(fn -> Reader.parse(bomb) end)
      assert result == {:error, :alias}
      assert time < 1_000_000
    end

    test "takes 64 KiB and refuses a byte more" do
      line = "# " <> String.duplicate("x", 61) <> "\n"
      fits = String.duplicate(line, 1024)
      assert byte_size(fits) == Reader.max_bytes()
      assert Reader.parse(fits) == {:ok, nil}
      assert Reader.parse(fits <> "\n") == {:error, :too_large}
    end

    test "takes 16 nested collections and refuses 17" do
      nested = fn depth -> String.duplicate("[", depth) <> String.duplicate("]", depth) end
      assert {:ok, _value} = Reader.parse(nested.(Reader.max_depth()))
      assert Reader.parse(nested.(Reader.max_depth() + 1)) == {:error, :too_deep}

      block =
        Enum.map_join(0..16, "", fn depth -> String.duplicate("  ", depth) <> "k#{depth}:\n" end)

      assert Reader.parse(block) == {:error, :too_deep}
    end

    test "refuses two documents, a repeated key and a key that is not text" do
      assert Reader.harness(source("refused/two-documents.yaml")) ==
               {:error, :several_documents}

      assert Reader.harness(source("refused/repeated-key.yaml")) ==
               {:error, {:repeated_key, "extends"}}

      assert Reader.parse("1: a\n") == {:error, :key_not_text}
      assert Reader.parse("? [a]\n: b\n") == {:error, :key_not_text}
      assert Reader.parse("null: a\n") == {:error, :key_not_text}
    end

    test "refuses an infinite or not-a-number float, an unknown tag, and broken YAML" do
      assert Reader.parse("a: .inf\n") == {:error, :not_a_number}
      assert Reader.parse("a: .nan\n") == {:error, :not_a_number}
      assert Reader.parse("a: !custom x\n") == {:error, :invalid_yaml}
      assert Reader.parse("a: [b\n") == {:error, :invalid_yaml}
      assert Reader.parse(<<0xFF, 0xFE, 0>>) == {:error, :invalid_yaml}
    end

    test "reads the core schema's scalars" do
      assert Reader.parse("a: 1\nb: 1.5\nc: true\nd: null\ne: yes\nf: '1'\n") ==
               {:ok, %{"a" => 1, "b" => 1.5, "c" => true, "d" => nil, "e" => "yes", "f" => "1"}}
    end
  end
end
