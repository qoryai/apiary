defmodule Mix.Tasks.Apiary.Harness.UpdateTest do
  # `mix apiary.harness.update` against a git repository the test makes under its tmp_dir,
  # with the files of the Qory harness the task copies; no test reads the network.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Apiary.Harness.Update

  @moduletag :tmp_dir

  @process """
  apiVersion: qory.dev/v1alpha1
  name: Example factory
  summary: Agents "change" things.
  description: |-
    First paragraph.

    Second paragraph.
  type: qory.software
  stack: software
  process: {schema: qory.process/v1}
  """

  @files %{
    "qory.yaml" => "exports:\n  stacks: [core, software]\n",
    "modules/software-factory/process.yaml" => @process,
    "stacks/core/qory-stack.yaml" => "name: core\nmodules:\n  - name: core\n",
    "stacks/software/qory-stack.yaml" => "name: software\nmodules:\n  - name: core\n"
  }

  setup %{tmp_dir: dir} do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    checkout = Path.join(dir, "harness")
    env = git_env(dir)
    git!(env, ["init", "-q", checkout])
    commit = commit!(env, checkout, @files)

    %{
      checkout: checkout,
      commit: commit,
      env: env,
      output: Path.join(dir, "out"),
      texts: Path.join(dir, "texts.ex")
    }
  end

  # A git environment under `dir`, so no setting of the machine's user applies.
  defp git_env(dir) do
    home = Path.join(dir, "home")
    File.mkdir_p!(home)

    [
      {"HOME", home},
      {"XDG_CONFIG_HOME", home},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_AUTHOR_NAME", "Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]
  end

  defp git!(env, args) do
    assert {out, 0} = System.cmd("git", args, env: env, stderr_to_stdout: true)
    out
  end

  # Writes `files` into `checkout`, commits them, and returns the commit's full id.
  defp commit!(env, checkout, files) do
    for {path, bytes} <- files do
      File.mkdir_p!(Path.dirname(Path.join(checkout, path)))
      File.write!(Path.join(checkout, path), bytes)
    end

    git!(env, ["-C", checkout, "add", "-A"])
    git!(env, ["-C", checkout, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "files"])
    env |> git!(["-C", checkout, "rev-parse", "HEAD"]) |> String.trim()
  end

  defp run(ctx, commit),
    do: Update.run([ctx.checkout, commit, "--output", ctx.output, "--texts", ctx.texts])

  test "copies the files at the commit and writes its full id", ctx do
    later = commit!(ctx.env, ctx.checkout, %{"qory.yaml" => "exports:\n  stacks: [core]\n"})
    File.write!(Path.join(ctx.checkout, "stacks/core/qory-stack.yaml"), "name: changed\n")

    run(ctx, String.slice(ctx.commit, 0, 8))

    for {path, bytes} <- @files, do: assert(File.read!(Path.join(ctx.output, path)) == bytes)
    assert File.read!(Path.join(ctx.output, ".harness-ref")) == ctx.commit <> "\n"
    assert Enum.sort(Update.files()) == Enum.sort(Map.keys(@files))

    assert_received {:mix_shell, :info, [line]}
    assert line =~ "Copied 4 files at #{ctx.commit} to #{ctx.output}"

    run(ctx, later)
    assert File.read!(Path.join(ctx.output, "qory.yaml")) == "exports:\n  stacks: [core]\n"
    assert File.read!(Path.join(ctx.output, ".harness-ref")) == later <> "\n"
  end

  test "writes the template's texts as pgettext calls in the workspace type context", ctx do
    run(ctx, ctx.commit)
    source = File.read!(ctx.texts)

    assert source ==
             Update.texts_module([
               {"software-factory",
                %{
                  name: "Example factory",
                  summary: ~s(Agents "change" things.),
                  description: "First paragraph.\n\nSecond paragraph."
                }}
             ])

    assert source =~ ~s|def texts("software-factory")|
    assert source =~ ~s|name: pgettext("workspace type", "Example factory")|
    assert source =~ ~s|pgettext("workspace type", "Agents \\"change\\" things.")|
    assert source =~ ~s|pgettext("workspace type", "First paragraph.\\n\\nSecond paragraph.")|
    assert Code.format_string!(source) |> IO.iodata_to_binary() |> Kernel.<>("\n") == source
  end

  test "stops before writing for a commit the checkout does not have", ctx do
    assert_raise Mix.Error, ~r/\ARun git fetch in .*: it has no commit 0000000\.\z/, fn ->
      run(ctx, "0000000")
    end

    refute File.exists?(ctx.output)
    refute File.exists?(ctx.texts)
  end

  test "stops before writing when the hex digits are a branch's name, not the commit's", ctx do
    later = commit!(ctx.env, ctx.checkout, %{"qory.yaml" => "exports:\n  stacks: [core]\n"})
    name = Enum.find(["abcdef1", "1234567"], &(not String.starts_with?(later, &1)))
    git!(ctx.env, ["-C", ctx.checkout, "branch", name, later])

    assert_raise Mix.Error, ~r/\AGive the full commit id: #{name} is a branch or tag/, fn ->
      run(ctx, name)
    end

    refute File.exists?(ctx.output)
    refute File.exists?(ctx.texts)
  end

  test "takes only lower-case hex digits as the commit", ctx do
    for given <- ["HEAD", "ABCDEF1", "abc", "main~1"] do
      assert_raise Mix.Error, ~r/7 to 64 lower-case hex digits/, fn -> run(ctx, given) end
    end

    refute File.exists?(ctx.output)
  end

  test "stops before writing when the commit lacks a file", ctx do
    git!(ctx.env, ["-C", ctx.checkout, "rm", "-q", "stacks/software/qory-stack.yaml"])

    git!(ctx.env, ["-C", ctx.checkout, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "rm"])

    commit = ctx.env |> git!(["-C", ctx.checkout, "rev-parse", "HEAD"]) |> String.trim()

    message =
      "Choose a commit that has stacks/software/qory-stack.yaml: #{commit} has no such file."

    assert_raise Mix.Error, message, fn ->
      run(ctx, commit)
    end

    refute File.exists?(ctx.output)
  end

  test "stops before writing when a file is not YAML the reader takes", ctx do
    commit = commit!(ctx.env, ctx.checkout, %{"qory.yaml" => "a: &x 1\nb: *x\n"})

    message = "Correct qory.yaml at #{commit}: it is not readable (:alias)."

    assert_raise Mix.Error, message, fn ->
      run(ctx, commit)
    end

    refute File.exists?(ctx.output)
  end

  test "stops before writing when the template has no summary", ctx do
    commit =
      commit!(ctx.env, ctx.checkout, %{
        "modules/software-factory/process.yaml" => "name: Example\ndescription: Text\n"
      })

    message = "Add the text summary to modules/software-factory/process.yaml."
    assert_raise Mix.Error, message, fn -> run(ctx, commit) end
    refute File.exists?(ctx.output)
  end
end
