defmodule Apiary.Stacks.HarnessMigrationTest do
  # The migration that keeps a harness document in each stack row, run down and up again
  # inside the test's transaction, which rolls it all back: up converts each reference to
  # a document and stops on a name before it changes anything; down converts a document
  # of the form `extends: {git, ref, path}` back and stops on any other. It changes
  # `stacks` under every other test, so this is not async. The rows are read and written
  # in raw SQL, as the schema names one column of the two.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Stacks

  @migration {20_261_025_100_000, Apiary.Repo.Migrations.KeepAHarnessDocumentAtEachLevel,
              "keep_a_harness_document_at_each_level"}

  @demo "https://github.com/qoryai/qory#a0c1d6e739749ebfa77b15332aa94d4305451261:" <>
          "examples/hello"

  setup_all do
    {version, migration, name} = @migration

    if not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down! do
    {version, migration, _name} = @migration
    Ecto.Migrator.down(Repo, version, migration, @options)
  end

  defp up! do
    {version, migration, _name} = @migration
    Ecto.Migrator.up(Repo, version, migration, @options)
  end

  defp column do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'stacks' AND column_name IN ('stack', 'harness')"
      )

    rows
  end

  # A row at the workspace of `scope` for `workflow`, with `column` set to `value`.
  defp insert!(scope, column, value, workflow) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO stacks (id, organisation_id, workspace_id, workflow, #{column}, " <>
        "inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, now(), now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        workflow,
        value
      ]
    )

    id
  end

  defp value(column, id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM stacks WHERE id = $1", [Ecto.UUID.dump!(id)])

    value
  end

  test "up converts each reference to a document, and down converts it back" do
    %{scope: scope} = sign_up_fixture()
    assert :ok = down!()
    assert column() == [["stack", "NO"]]

    demo = insert!(scope, "stack", @demo, "hello")
    port = insert!(scope, "stack", "https://code.example.com:8443/team/stacks#v1.2.0:.", "x")

    assert :ok = up!()
    assert column() == [["harness", "YES"]]

    assert value("harness", demo) ==
             "extends:\n  git: \"https://github.com/qoryai/qory\"\n" <>
               "  ref: \"a0c1d6e739749ebfa77b15332aa94d4305451261\"\n" <>
               "  path: \"examples/hello\"\n"

    assert Stacks.Document.errors(value("harness", demo)) == []

    assert {:ok, %{"extends" => %{"git" => "https://code.example.com:8443/team/stacks"}}} =
             Apiary.Harnesses.Reader.document(value("harness", port))

    assert :ok = down!()
    assert value("stack", demo) == @demo
    assert value("stack", port) == "https://code.example.com:8443/team/stacks#v1.2.0:."
    assert :ok = up!()
  end

  test "up stops on a name before it changes anything" do
    %{scope: scope} = sign_up_fixture()
    assert :ok = down!()
    insert!(scope, "stack", @demo, "hello")
    insert!(scope, "stack", "software-standard", "review")

    assert_raise RuntimeError,
                 "Replace each stack set by name with a stack reference, then migrate again.",
                 &up!/0

    assert column() == [["stack", "NO"]]

    Repo.query!("DELETE FROM stacks WHERE stack = 'software-standard'")
    assert :ok = up!()
  end

  test "down stops on a document of another form, and on a row with no document" do
    %{scope: scope} = sign_up_fixture()
    message = ~r/^Replace each harness document that is not of the form extends/

    other =
      insert!(scope, "harness", "extends: {git: https://code.example.com/s, ref: v1}\n", "x")

    assert_raise RuntimeError, message, &down!/0
    assert column() == [["harness", "YES"]]

    Repo.query!("DELETE FROM stacks WHERE id = $1", [Ecto.UUID.dump!(other)])
    insert!(scope, "harness", nil, "hello")
    assert_raise RuntimeError, message, &down!/0
    assert column() == [["harness", "YES"]]
  end

  test "a row with neither a document nor a workflow breaks the check" do
    %{scope: scope} = sign_up_fixture()

    assert_raise Postgrex.Error, ~r/stacks_harness_or_workflow/, fn ->
      insert!(scope, "harness", nil, nil)
    end
  end

  test "a document of more than 64 KiB breaks the size check" do
    %{scope: scope} = sign_up_fixture()
    big = "extensions: {note: " <> String.duplicate("x", 65_536) <> "}\n"

    assert_raise Postgrex.Error, ~r/stacks_harness_size/, fn ->
      insert!(scope, "harness", big, nil)
    end
  end
end
