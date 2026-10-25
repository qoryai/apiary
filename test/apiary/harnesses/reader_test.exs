defmodule Apiary.Harnesses.ReaderTest do
  # The reader of qory's harness files, against the fixture set under
  # test/fixtures/harness/v1/sources/ and against hand-written refusals of each limit.
  use ExUnit.Case, async: true

  alias Apiary.Harnesses.Reader
  alias Apiary.Kinds.Budget

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

  describe "stack/1 and workflow_access/2" do
    @modules "modules:\n  - source: {path: core}\n"

    test "reads the workflows as written, an empty map for none or for another value" do
      assert {:ok, %{modules: [%{"source" => %{"path" => "core"}}], workflows: workflows}} =
               Reader.stack(@modules <> "workflows:\n  explore: {access: write}\n")

      assert workflows == %{"explore" => %{"access" => "write"}}

      for rest <- ["", "workflows:\n", "workflows: [explore]\n", "workflows: explore\n"] do
        assert {:ok, %{workflows: %{}}} = Reader.stack(@modules <> rest), rest
      end

      assert Reader.stack("workflows: {}\n") == {:error, :invalid_stack}
    end

    test "a workflow declares write only with access: write, and read otherwise" do
      workflows = %{
        "explore" => %{"access" => "write"},
        "review" => %{"access" => "read"},
        "fix" => %{"time_limit" => "45m"},
        "plan" => %{"access" => "admin"},
        "test" => "write"
      }

      assert Reader.workflow_access(workflows, "explore") == :write

      for name <- ~w(review fix plan test absent),
          do: assert(Reader.workflow_access(workflows, name) == :read, name)

      assert Reader.workflow_access(%{}, "explore") == :read
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

  describe "document/2" do
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
      assert Reader.parse("name: !!bool maybe\n") == {:error, :invalid_yaml}
      assert Reader.parse("\t a: 1\n") == {:error, :invalid_yaml}
      assert Reader.parse(<<0xFF, 0xFE, 0>>) == {:error, :invalid_yaml}
    end

    test "reads the core schema's scalars" do
      assert Reader.parse("a: 1\nb: 1.5\nc: true\nd: null\ne: yes\nf: '1'\n") ==
               {:ok, %{"a" => 1, "b" => 1.5, "c" => true, "d" => nil, "e" => "yes", "f" => "1"}}
    end
  end

  describe "the parse's limits" do
    # Each slow input took seconds to minutes in yamerl before the limits, and each is
    # under 64 KiB. The parse stops at 30 million reductions, 64 MiB of heap or 10 s,
    # whichever comes first. On an idle machine each slow input passes the reductions
    # within 3 s, and an ordinary 64 KiB file parses within 0.2 s.
    @slow [
      String.duplicate("[", 65_000),
      "[" <> String.duplicate("a,", 32_000) <> "a]",
      "- [" <> String.duplicate("a,", 32_000) <> "a]"
    ]

    @list "k: [" <> String.duplicate("a,", 32_000) <> "a]"

    # The process the parse of `caller` runs in, which `caller` monitors, once `caller`
    # also monitors the watcher that kills the parse when `caller` exits
    # (`Apiary.Kinds.Budget`). The parse process is the one with a heap limit.
    defp parse_process(caller, tries \\ 100) do
      {:monitors, monitors} = Process.info(caller, :monitors)
      pids = for {:process, pid} <- monitors, do: pid

      case Enum.filter(pids, &heap_limited?/1) do
        [child] when length(pids) == 2 ->
          child

        _not_yet when tries > 0 ->
          Process.sleep(10)
          parse_process(caller, tries - 1)
      end
    end

    defp heap_limited?(pid) do
      match?({:max_heap_size, %{size: size}} when size > 0, Process.info(pid, :max_heap_size))
    end

    # The parse's 10 s backstop, and 2 s to spare.
    defp timed(input) do
      {time, result} = :timer.tc(fn -> Reader.parse(input) end)
      assert time < 12_000_000, "took #{div(time, 1000)} ms"
      result
    end

    # The reductions `fun` does, counted in another process, and its value.
    defp reductions(fun) do
      task =
        Task.async(fn ->
          {:reductions, before} = Process.info(self(), :reductions)
          value = fun.()
          {:reductions, done} = Process.info(self(), :reductions)
          {done - before, value}
        end)

      Task.await(task, :infinity)
    end

    test "refuse 65,000 open brackets" do
      assert timed(String.duplicate("[", 65_000)) == {:error, :too_complex}
    end

    test "refuse a flow sequence of 32,000 items at the top level" do
      assert timed("[" <> String.duplicate("a,", 32_000) <> "a]") == {:error, :too_complex}
    end

    test "refuse a flow sequence of 32,000 items in a block sequence" do
      assert timed("- [" <> String.duplicate("a,", 32_000) <> "a]") == {:error, :too_complex}
    end

    test "end the parse at once when the caller exits first" do
      for input <- [
            "[" <> String.duplicate("a,", 32_000) <> "a]",
            String.duplicate("{a: ", 16_000)
          ] do
        caller = spawn(fn -> Reader.parse(input) end)
        child = parse_process(caller)
        ref = Process.monitor(child)
        Process.exit(caller, :kill)
        assert_receive {:DOWN, ^ref, :process, ^child, :killed}, 1_000
      end
    end

    test "take 64 KiB of ordinary YAML well within the limits" do
      assert {:ok, list} = timed(String.duplicate("- a\n", 16_000))
      assert length(list) == 16_000

      assert {:ok, %{"k" => items}} = timed(@list)
      assert length(items) == 32_001

      keys = Enum.map_join(1..4_000, fn i -> "key-#{i}: value\n" end)
      assert byte_size(keys) < Reader.max_bytes()
      assert {:ok, map} = timed(keys)
      assert map_size(map) == 4_000
    end

    # The next two tests catch a change in how many reductions a parse does, such as
    # after an upgrade of Erlang/OTP or yamerl. If one fails, measure the reductions of
    # the ordinary files and of the slow inputs again, and set the budget,
    # `@max_reductions` in lib/apiary/harnesses/reader.ex, at least 3 times the largest
    # ordinary count and at most half the reductions at which each slow input is still
    # unfinished. Then set the measured counts here and in the comment beside the budget.

    test "an ordinary 64 KiB list does 0.5 to 2 times the reductions measured on OTP 29" do
      # 8,917,982 reductions measured on OTP 29.
      assert {count, {:ok, %{"k" => _items}}} = reductions(fn -> Reader.read(@list) end)
      assert count in 4_458_991..17_835_964, "#{count} reductions"
    end

    @tag timeout: 180_000
    test "each slow input is unfinished at twice the budget of reductions" do
      over =
        Task.async_stream(
          @slow,
          fn input ->
            Budget.run(fn -> Reader.read(input) end,
              reductions: 2 * Reader.max_reductions(),
              heap_words: div(256 * 1024 * 1024, :erlang.system_info(:wordsize)),
              ms: 150_000
            )
          end,
          timeout: :infinity
        )

      assert Enum.to_list(over) == List.duplicate({:ok, {:error, :reductions}}, 3)
    end
  end

  describe "characters and types" do
    @controls [0x00, 0x01, 0x07, 0x08, 0x0B, 0x0C, 0x1B, 0x7F, 0x85, 0x9F]

    test "refuse a control character in any place, and never raise" do
      for code <- @controls,
          template <- ["a: x~y\n", "x~: 1\n", "[x~]", "a: \"x~\"\n", "a: 1 # ~\n", "a: |\n  x~\n"] do
        input = String.replace(template, "~", <<code::utf8>>)
        assert Reader.parse(input) == {:error, :control_character}, inspect(input)
      end
    end

    test "refuse a control character a double-quoted text escapes" do
      for escape <- ["\\0", "\\x01", "\\x1b", "\\x7f", "\\u0085", "\\e"] do
        assert Reader.parse(~s(a: "x#{escape}y"\n)) == {:error, :control_character}, escape
      end
    end

    test "take tab, line feed and carriage return" do
      assert Reader.parse("a:\t1\r\nb: \"x\\ty\"\n") == {:ok, %{"a" => 1, "b" => "x\ty"}}
    end

    test "turn any other failure of the parser into a refusal" do
      for code <- 0..0x2030, code not in 0xD800..0xDFFF do
        result = Reader.parse("a: x" <> <<code::utf8>> <> "y\n[x" <> <<code::utf8>> <> "]")
        assert match?({:error, _reason}, result) or match?({:ok, _value}, result)
      end
    end

    test "refuse !!binary and every other type but text, numbers, booleans and null" do
      assert Reader.parse("a: !!binary //79\n") == {:error, :unsupported_type}
      assert Reader.parse("bind: {agents/x: !!binary //79}\n") == {:error, :unsupported_type}
      assert Reader.parse("a: !!binary aHR0cHM6Ly91OnBAaC9y\n") == {:error, :unsupported_type}
      assert Reader.parse("a: !!timestamp 2001-12-14\n") == {:error, :invalid_yaml}
    end

    test "count the depth of one-pair mappings in a flow sequence" do
      nested = fn n -> String.duplicate("[a: ", n) <> "x" <> String.duplicate("]", n) end
      assert {:ok, _value} = Reader.parse(nested.(8))
      assert Reader.parse(nested.(9)) == {:error, :too_deep}
    end
  end
end
