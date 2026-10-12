defmodule Apiary.KeysFileTest do
  # Not async: get/2 reads the system environment, which these tests change.
  use ExUnit.Case, async: false

  alias Apiary.KeysFile

  @names ~w(SECRET_KEY_BASE APIARY_ENCRYPTION_SECRET APIARY_SIGNING_SECRET DATABASE_PASSWORD)

  setup do
    previous = Map.new(@names, &{&1, System.get_env(&1)})
    Enum.each(@names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp write_keys(dir, contents), do: File.write!(Path.join(dir, "apiary.env"), contents)

  describe "read/1" do
    @tag :tmp_dir
    test "takes each of the four names from its NAME=value line", %{tmp_dir: dir} do
      write_keys(dir, """
      SECRET_KEY_BASE=base/with+slash=and=equals
      APIARY_ENCRYPTION_SECRET=encryption
      APIARY_SIGNING_SECRET=signing
      DATABASE_PASSWORD=password
      """)

      assert KeysFile.read(dir) == %{
               "SECRET_KEY_BASE" => "base/with+slash=and=equals",
               "APIARY_ENCRYPTION_SECRET" => "encryption",
               "APIARY_SIGNING_SECRET" => "signing",
               "DATABASE_PASSWORD" => "password"
             }
    end

    @tag :tmp_dir
    test "takes NAME=value lines of the four names and nothing else", %{tmp_dir: dir} do
      write_keys(
        dir,
        Enum.join(
          [
            "# APIARY_SIGNING_SECRET=commented",
            "PUBLIC_URL=https://qory.example",
            "export SECRET_KEY_BASE=exported",
            " APIARY_ENCRYPTION_SECRET=indented",
            "APIARY_ENCRYPTION_SECRET =spaced",
            "DATABASE_PASSWORD=",
            "",
            "APIARY_SIGNING_SECRET",
            "DATABASE_PASSWORD=last line, no newline"
          ],
          "\n"
        )
      )

      assert KeysFile.read(dir) == %{"DATABASE_PASSWORD" => "last line, no newline"}
    end

    @tag :tmp_dir
    test "the first line of a name wins, as bin/keys reads it", %{tmp_dir: dir} do
      write_keys(dir, "APIARY_SIGNING_SECRET=first\nAPIARY_SIGNING_SECRET=second\n")
      assert KeysFile.read(dir) == %{"APIARY_SIGNING_SECRET" => "first"}
    end

    @tag :tmp_dir
    test "is empty without a directory, or without the file in it", %{tmp_dir: dir} do
      assert KeysFile.read(nil) == %{}
      assert KeysFile.read("") == %{}
      assert KeysFile.read(dir) == %{}
      assert KeysFile.read(Path.join(dir, "absent")) == %{}
    end

    @tag :tmp_dir
    test "a file that cannot be read raises, naming the path and never a value",
         %{tmp_dir: dir} do
      # A directory where the file should be cannot be read as one, whoever runs the suite.
      File.mkdir_p!(Path.join(dir, "apiary.env"))

      error = assert_raise File.Error, fn -> KeysFile.read(dir) end
      assert Exception.message(error) =~ Path.join(dir, "apiary.env")
    end
  end

  describe "get/2" do
    @keys %{"APIARY_SIGNING_SECRET" => "from the file", "DATABASE_PASSWORD" => "file password"}

    test "is the file's value where the environment does not set the name" do
      assert KeysFile.get(@keys, "APIARY_SIGNING_SECRET") == "from the file"
      assert KeysFile.get(@keys, "APIARY_ENCRYPTION_SECRET") == nil
    end

    test "the environment always wins" do
      System.put_env("APIARY_SIGNING_SECRET", "from the environment")
      System.put_env("APIARY_ENCRYPTION_SECRET", "only the environment")

      assert KeysFile.get(@keys, "APIARY_SIGNING_SECRET") == "from the environment"
      assert KeysFile.get(@keys, "APIARY_ENCRYPTION_SECRET") == "only the environment"
      assert KeysFile.get(@keys, "DATABASE_PASSWORD") == "file password"
    end

    test "a blank value in the environment is an unset one" do
      System.put_env("APIARY_SIGNING_SECRET", "")
      System.put_env("APIARY_ENCRYPTION_SECRET", "")

      assert KeysFile.get(@keys, "APIARY_SIGNING_SECRET") == "from the file"
      assert KeysFile.get(@keys, "APIARY_ENCRYPTION_SECRET") == nil
    end
  end
end
