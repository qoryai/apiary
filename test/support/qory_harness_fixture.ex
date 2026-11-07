defmodule Apiary.QoryHarnessFixture do
  @moduledoc """
  The Qory harness of the tests: a git repository in a temporary folder, made once per
  test run from the files in `test/support/fixtures/qory_harness/`, in one commit on
  `main`. `Apiary.PublicGitStub` serves it at the Qory harness's address
  (`Apiary.Harnesses.Qory.git/0`), with no network, so the tests read it the way the
  product reads the Qory harness. Its commit is the test run's, never written in a test:
  `commit/0`.

  `start!/0` makes it and reads it once through `Apiary.Harnesses.Qory.read/1`, committed
  before the sandbox takes over, so every test finds `main`'s files stored, as an instance
  does after its first read.

  The stub serves qory's repository too, at the address of the built-in harness of a test
  work item (`Apiary.Harnesses.Builtin`), with its hello example in one commit on `main`,
  so a claim of a test work item's run reads it.
  """

  @files Path.expand("fixtures/qory_harness", __DIR__)
  @builtin_files %{
    "examples/hello/qory-stack.yaml" =>
      "modules:\n  - name: hello\n    source: {path: modules/hello}\n"
  }

  @doc "start!/0 makes the repositories and reads the Qory harness (the moduledoc). `:ok`."
  @spec start!() :: :ok
  def start! do
    repository = Apiary.PublicGitServer.build!(files())
    builtin = Apiary.PublicGitServer.build!(@builtin_files)
    :persistent_term.put(__MODULE__, Map.put(repository, :builtin, builtin))

    ExUnit.after_suite(fn _result ->
      File.rm_rf(repository.dir)
      File.rm_rf(builtin.dir)
    end)

    {:ok, commit} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Apiary.Repo, fn ->
        Apiary.Harnesses.Qory.read({:branch, Apiary.Harnesses.Qory.default_branch()})
      end)

    ^commit = repository.commit
    :ok
  end

  @doc "files/0 is the fixture's files, by their path in the harness."
  @spec files() :: %{String.t() => binary}
  def files do
    @files
    |> Path.join("**/*.yaml")
    |> Path.wildcard()
    |> Map.new(&{Path.relative_to(&1, @files), File.read!(&1)})
  end

  @doc """
  explore_named/1 is the fixture's files with the first stage of the template, Explore,
  named `name`: a later commit of the harness whose default process differs.
  """
  @spec explore_named(String.t()) :: %{String.t() => binary}
  def explore_named(name) do
    Map.update!(files(), "modules/software-factory/process.yaml", fn process ->
      String.replace(process, "      name: Explore\n", "      name: #{name}\n", global: false)
    end)
  end

  @doc """
  serve!/2 is a repository of `files` (`Apiary.PublicGitServer.repository!/2`, with
  `opts`) served at the Qory harness's address for the calling test, in place of the
  fixture: `%{dir, commit}`.
  """
  @spec serve!(%{String.t() => binary}, keyword) :: %{dir: String.t(), commit: String.t()}
  def serve!(files \\ files(), opts \\ []) do
    repository = Apiary.PublicGitServer.repository!(files, opts)
    Apiary.PublicGitServer.serve(%{Apiary.Harnesses.Qory.git() => repository.dir})
    repository
  end

  @doc "commit/0 is the full id of the fixture's commit on `main`."
  @spec commit() :: String.t()
  def commit, do: repository().commit

  @doc "dir/0 is the folder of the fixture repository."
  @spec dir() :: String.t()
  def dir, do: repository().dir

  @doc "builtin_commit/0 is the full id of the commit on `main` of qory's repository."
  @spec builtin_commit() :: String.t()
  def builtin_commit, do: repository().builtin.commit

  @doc """
  folders/0 is the fixture repository at the Qory harness's address and qory's at its
  address, as `Apiary.PublicGitServer.folders/1` gives them; empty before `start!/0`.
  """
  @spec folders() :: map
  def folders do
    case :persistent_term.get(__MODULE__, nil) do
      %{dir: dir, builtin: builtin} ->
        Apiary.PublicGitServer.folders(%{
          Apiary.Harnesses.Qory.git() => dir,
          Apiary.Harnesses.Builtin.git() => builtin.dir
        })

      nil ->
        %{}
    end
  end

  defp repository, do: :persistent_term.get(__MODULE__)
end
