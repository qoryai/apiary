defmodule Apiary.Harnesses.BuiltinComposeTest do
  # The built-in harness (`Apiary.Harnesses.Builtin`) composed by a qory binary, against
  # qory's hello example at the built-in harness's commit, vendored in
  # test/fixtures/qory-hello/. Each compose runs `qory harness compose --dry-run -f`:
  # `-f` takes the vendored stack in place of the section's `extends` source, so qory
  # fetches nothing.
  #
  # The binary is QORY_BIN, read when the file compiles. A `qory` on PATH is not used: a
  # qory older than the pinned commit fails both composes for reasons unrelated to the pin.
  # With QORY_BIN unset or empty, the tests that run qory are skipped.
  use ExUnit.Case, async: true

  alias Apiary.Harnesses.Builtin
  alias ApiaryWeb.Contract.DispatchAnswer

  @moduletag needs: :factory
  @moduletag :tmp_dir

  @fixture Path.expand("../../fixtures/qory-hello", __DIR__)
  @stack Path.join(@fixture, "examples/hello")

  @qory System.get_env("QORY_BIN", "")

  # The qory.yaml of a test work item's run: the `harness` member of the run's documents
  # (`ApiaryWeb.Contract.DispatchAnswer.documents/1`), from the harness members a claim
  # takes from the built-in walk (`Apiary.Dispatches.Handover`).
  defp qory_yaml do
    walked = Builtin.walked()

    documents =
      DispatchAnswer.documents(%{
        step: "explore",
        domain: "software",
        target: nil,
        work_item: nil,
        run_settings: nil,
        harness: %{
          target_version: walked[:target_version],
          workflow: walked[:workflow],
          harness_hidden: walked[:harness_hidden],
          access: walked[:access_level],
          harness: walked[:document]
        },
        inputs: Jason.OrderedObject.new([])
      })

    Jason.encode!(documents["harness"])
  end

  # The environment of qory and git: HOME and each XDG_* directory under `dir`, no other
  # XDG_* or QORY_* variable, and no check for a qory update.
  defp env(dir) do
    inherited =
      for {name, _value} <- System.get_env(),
          String.starts_with?(name, ["XDG_", "QORY_"]),
          into: %{},
          do: {name, nil}

    homes =
      for name <- ~w(HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME
                     XDG_RUNTIME_DIR),
          into: %{} do
        path = Path.join(dir, String.downcase(name))
        File.mkdir_p!(path)
        {name, path}
      end

    inherited
    |> Map.merge(homes)
    |> Map.put("QORY_NO_UPDATE_CHECK", "1")
    |> Enum.to_list()
  end

  # Composes the built-in harness with the binary `qory` in a git checkout under `dir`,
  # with `stack` as its base, for the runtime claude. Returns the checkout, qory's output
  # with stderr, and the exit status.
  defp compose(qory, dir, stack) do
    env = env(dir)
    checkout = Path.join(dir, "checkout")

    assert {_output, 0} =
             System.cmd("git", ["init", "-q", checkout], env: env, stderr_to_stdout: true)

    File.write!(Path.join(checkout, "qory.yaml"), qory_yaml())

    args =
      ~w(harness compose --dry-run --runtime claude -f) ++ [Path.join(stack, "qory-stack.yaml")]

    {output, status} = System.cmd(qory, args, cd: checkout, env: env, stderr_to_stdout: true)
    {checkout, output, status}
  end

  test "the fixture is qory's hello example at the built-in harness's commit" do
    %{"extends" => %{"ref" => ref, "path" => path}} = Builtin.document()

    assert File.read!(Path.join(@fixture, "README.md")) =~ "commit #{ref}"
    assert path == "examples/hello"
  end

  describe "qory harness compose" do
    if @qory == "" do
      @describetag skip:
                     "Set QORY_BIN to a qory built from #{Builtin.document()["extends"]["ref"]} to run this test"
    end

    setup do: %{qory: @qory}

    test "composes the built-in harness on top of the hello stack", %{tmp_dir: dir, qory: qory} do
      %{"extends" => %{"git" => git, "ref" => ref, "path" => path}} = Builtin.document()

      assert {checkout, output, 0} = compose(qory, dir, @stack)

      assert output =~
               ~r/^\s*base\s+.+\s+\(set by -f, in place of extends #{Regex.escape("#{git}##{ref}:#{path}")}\)$/m

      assert output =~ "✓ dry run: nothing written"
      assert Enum.sort(File.ls!(checkout)) == [".git", "qory.yaml"]
    end

    test "refuses a hello stack with no extending block", %{tmp_dir: dir, qory: qory} do
      closed = Path.join(dir, "closed")
      File.cp_r!(@stack, closed)
      stack_file = Path.join(closed, "qory-stack.yaml")
      text = File.read!(stack_file)
      assert text =~ ~r/^extending: \{\}\n/m
      File.write!(stack_file, String.replace(text, ~r/^extending: \{\}\n/m, ""))

      assert {_checkout, output, 2} = compose(qory, dir, closed)
      assert output =~ "is closed: it declares no extending block"
    end
  end
end
