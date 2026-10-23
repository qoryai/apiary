defmodule Apiary.Dispatches.MachinesFileTest do
  # The machines file (`Apiary.Dispatches.MachinesFile`): read at boot from the path
  # `APIARY_MACHINES_FILE` is set to, nothing without one, the entries of a valid file by
  # workspace, and each file the boot refuses, with its one line. Not async: the setting
  # and the file read are the whole node's.
  use ExUnit.Case, async: false

  alias Apiary.Dispatches.MachinesFile

  @moduletag :tmp_dir

  @stack "core"

  setup do
    setting = Application.fetch_env(:apiary, :machines_file_setting)
    file = Application.fetch_env(:apiary, :machines_file)

    on_exit(fn ->
      restore(:machines_file_setting, setting)
      restore(:machines_file, file)
    end)
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:apiary, key, value)
  defp restore(key, :error), do: Application.delete_env(:apiary, key)

  # The path of a file in `dir` with `contents`, JSON encoded unless a binary.
  defp file!(dir, contents) do
    path = Path.join(dir, "machines.json")
    File.write!(path, if(is_binary(contents), do: contents, else: Jason.encode!(contents)))
    path
  end

  defp boot_with(path) do
    Application.put_env(:apiary, :machines_file_setting, path)
    MachinesFile.boot!()
  end

  # The line of the boot refused for a file of `contents`.
  defp refused(dir, contents) do
    path = file!(dir, contents)
    error = assert_raise ArgumentError, fn -> boot_with(path) end
    refute error.message =~ "\n"
    String.replace(error.message, " in the machines file #{path}: ", " | ")
  end

  defp workspace(entry),
    do: %{"machines" => ["small", "large"], "workspaces" => %{"acme/factory" => entry}}

  describe "no file" do
    test "with the setting unset or blank, whitespace alone included, nothing is read and no workspace has an entry" do
      for setting <- [nil, "", " ", "\t\n "] do
        assert boot_with(setting) == nil
        assert Application.get_env(:apiary, :machines_file) == nil
        assert MachinesFile.machine("acme", "factory") == nil
        assert MachinesFile.stack("acme", "factory") == nil
      end
    end
  end

  describe "a valid file" do
    test "gives each workspace in it its machine, its stack and workflow, or neither",
         %{tmp_dir: dir} do
      path =
        file!(dir, %{
          "machines" => ["small", "large"],
          "workspaces" => %{
            "acme/factory" => %{"machine" => "small", "stack" => @stack, "workflow" => "hello"},
            "acme/machine-only" => %{"machine" => "large"},
            "acme/stack-only" => %{"stack" => @stack, "workflow" => "build-2"},
            "acme/empty" => %{}
          }
        })

      stack = %{name: "core", workflow: "hello"}

      assert %{machines: ["small", "large"], workspaces: workspaces} = boot_with(path)
      assert map_size(workspaces) == 4

      assert {MachinesFile.machine("acme", "factory"), MachinesFile.stack("acme", "factory")} ==
               {"small", stack}

      assert {MachinesFile.machine("acme", "machine-only"),
              MachinesFile.stack("acme", "machine-only")} == {"large", nil}

      assert {MachinesFile.machine("acme", "stack-only"),
              MachinesFile.stack("acme", "stack-only")} ==
               {nil, %{stack | workflow: "build-2"}}

      assert {MachinesFile.machine("acme", "empty"), MachinesFile.stack("acme", "empty")} ==
               {nil, nil}

      # A workspace not in the file, of a known organisation or not, has no entry.
      assert {MachinesFile.machine("acme", "other"), MachinesFile.stack("acme", "other")} ==
               {nil, nil}

      assert {MachinesFile.machine("other", "factory"), MachinesFile.stack("other", "factory")} ==
               {nil, nil}
    end

    test "may leave out machines, workspaces or both, and take the contract's limits",
         %{tmp_dir: dir} do
      assert boot_with(file!(dir, %{})) == %{machines: [], workspaces: %{}}

      assert boot_with(file!(dir, %{"machines" => ["small"]})) ==
               %{machines: ["small"], workspaces: %{}}

      longest = "a" <> String.duplicate("b", 63)
      entry = %{"machine" => longest, "stack" => longest, "workflow" => longest}

      assert boot_with(file!(dir, %{"machines" => [longest], "workspaces" => %{"a/b" => entry}}))
      assert MachinesFile.stack("a", "b") == %{name: longest, workflow: longest}
    end
  end

  describe "a file the boot refuses" do
    test "is missing, or cannot be read", %{tmp_dir: dir} do
      missing = Path.join(dir, "absent.json")
      error = assert_raise ArgumentError, fn -> boot_with(missing) end

      assert error.message ==
               "Set APIARY_MACHINES_FILE to the path of a file that exists, or unset it: " <>
                 "#{missing} does not exist."

      error = assert_raise ArgumentError, fn -> boot_with(dir) end

      assert error.message ==
               "Make #{dir} a file Qory can read, or unset APIARY_MACHINES_FILE: " <>
                 "the file cannot be read (illegal operation on a directory)."
    end

    test "is not JSON, not an object, or has a key twice", %{tmp_dir: dir} do
      assert refused(dir, "{\"machines\": [") ==
               "Write the machines file as JSON | the file is not valid JSON at byte 14."

      assert refused(dir, "[]") ==
               "Write the machines file as one JSON object | the file is not an object."

      assert refused(dir, ~s({"machines": [], "machines": []})) ==
               "Remove the second \"machines\" from the top level | a key is given twice."

      assert refused(dir, ~s({"workspaces": {"acme/factory": {}, "acme/factory": {}}})) ==
               "Remove the second \"acme/factory\" from workspaces | a key is given twice."
    end

    test "has a member it does not take", %{tmp_dir: dir} do
      assert refused(dir, %{"machines" => [], "machine" => "small"}) ==
               "Remove the member \"machine\" from the top level | " <>
                 "the top level takes only machines, workspaces."

      assert refused(dir, workspace(%{"machine" => "small", "size" => 2})) ==
               "Remove the member \"size\" from workspaces.acme/factory | " <>
                 "workspaces.acme/factory takes only machine, stack, workflow."

      # A key with a line break is shown escaped: the line stays one line.
      assert refused(dir, workspace(%{"machine" => "small", "size\nlarge" => 2})) ==
               "Remove the member \"size\\nlarge\" from workspaces.acme/factory | " <>
                 "workspaces.acme/factory takes only machine, stack, workflow."
    end

    test "has machines that are not a list of names, each once", %{tmp_dir: dir} do
      assert refused(dir, %{"machines" => "small"}) ==
               "Write machines as a list of names | machines is not a list."

      for name <- ["Small", "1x", "-a", "", "a" <> String.duplicate("b", 64), 4, %{}] do
        assert refused(dir, %{"machines" => ["small", name]}) =~
                 ~r/\ACorrect machines\[1\] \| .* is not a machine type name: a lower-case letter,/
      end

      assert refused(dir, %{"machines" => ["small", "large", "small"]}) ==
               "Remove machines[2] | small is listed twice."
    end

    test "has workspaces that are not an object of <organisation>/<workspace>", %{tmp_dir: dir} do
      assert refused(dir, %{"workspaces" => ["acme/factory"]}) ==
               "Write workspaces as a JSON object | workspaces is not an object."

      for key <- [
            "acme",
            "acme/factory/runs",
            "Acme/factory",
            "acme/",
            "/factory",
            "acme/fac tory"
          ] do
        assert refused(dir, %{"workspaces" => %{key => %{}}}) ==
                 "Correct the workspace #{inspect(key)} | a workspace is " <>
                   "<organisation slug>/<workspace slug>, each 1 to 40 lower-case letters, " <>
                   "digits and hyphens."
      end

      assert refused(dir, workspace("small")) ==
               "Write workspaces.acme/factory as a JSON object | " <>
                 "workspaces.acme/factory is not an object."
    end

    test "gives a workspace a machine not in machines", %{tmp_dir: dir} do
      assert refused(dir, workspace(%{"machine" => "huge"})) ==
               "Add the machine to machines, or correct workspaces.acme/factory.machine | " <>
                 "\"huge\" is not in machines."

      assert refused(dir, workspace(%{"machine" => ["small"]})) =~
               ~r/\AAdd the machine to machines, .* \| \["small"\] is not in machines\.\z/

      assert refused(dir, %{"workspaces" => %{"acme/factory" => %{"machine" => "small"}}}) =~
               ~r/is not in machines\.\z/
    end

    test "gives a workspace a stack without a workflow, or a workflow without a stack",
         %{tmp_dir: dir} do
      assert refused(dir, workspace(%{"stack" => @stack})) ==
               "Add workflow to workspaces.acme/factory | stack and workflow come together."

      assert refused(dir, workspace(%{"machine" => "small", "workflow" => "hello"})) ==
               "Add stack to workspaces.acme/factory | stack and workflow come together."
    end

    test "gives a workspace a stack or a workflow the contract refuses", %{tmp_dir: dir} do
      at = "workspaces.acme/factory"

      for stack <- [
            "Core",
            "1core",
            "",
            "a" <> String.duplicate("b", 64),
            %{"url" => "https://forge.example.com/acme/stacks"},
            1
          ] do
        assert refused(dir, workspace(%{"stack" => stack, "workflow" => "hello"})) =~
                 ~r/\ACorrect #{at}\.stack \| .* is not a stack name: a lower-case letter, /
      end

      for workflow <- ["Hello", "/hello", "", 1] do
        assert refused(dir, workspace(%{"stack" => @stack, "workflow" => workflow})) ==
                 "Correct #{at}.workflow | #{inspect(workflow)} is not a workflow name: " <>
                   "a lower-case letter, then up to 63 lower-case letters, digits and hyphens."
      end
    end

    test "keeps the file read before: a refused boot changes nothing", %{tmp_dir: dir} do
      boot_with(file!(dir, workspace(%{"machine" => "small"})))
      assert MachinesFile.machine("acme", "factory") == "small"
      assert_raise ArgumentError, fn -> boot_with(file!(dir, "[]")) end
      assert MachinesFile.machine("acme", "factory") == "small"
    end
  end
end
