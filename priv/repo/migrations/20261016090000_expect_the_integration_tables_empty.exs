defmodule Apiary.Repo.Migrations.ExpectTheIntegrationTablesEmpty do
  use Ecto.Migration

  # The guard before the integrations and the stored secrets move from the workspace to
  # the organisation. The migrations after it change these tables as a fresh start: they
  # move no row, encrypt no value again and wrap no data key again. So this one stops the
  # migrations while any of them holds a row, and the boot with them
  # (`Apiary.Release.migrate/0` raises).
  #
  # In one transaction, it takes the seven tables `ACCESS EXCLUSIVE`, so no row arrives
  # while they are counted, then counts each, and raises naming those that hold rows. It
  # deletes nothing: a row of one of them, an orphan or not, stops it all the same. Its
  # `down` changes nothing.
  @tables ~w(workspace_connections connection_targets secrets secret_values
             workspace_data_keys integration_releases service_definitions)

  @doc false
  def tables, do: @tables

  def up do
    execute lock(@tables)
    flush()
    refuse_rows!(repo(), @tables)
  end

  def down, do: :ok

  @doc false
  # The guard on `tables` as they are named now, for the test, whose schema has every
  # migration after this one: the lock and the count, in the caller's transaction.
  def guard!(repo, tables) do
    repo.query!(lock(tables), [], log: false)
    refuse_rows!(repo, tables)
  end

  defp lock(tables),
    do: "LOCK TABLE #{Enum.join(tables, ", ")} IN ACCESS EXCLUSIVE MODE"

  defp refuse_rows!(repo, tables) do
    holding =
      Enum.filter(tables, fn table ->
        %{rows: [[count]]} = repo.query!("SELECT count(*) FROM #{table}", [], log: false)
        count > 0
      end)

    case holding do
      [] -> :ok
      holding -> raise refusal(holding)
    end
  end

  @doc false
  def refusal(holding), do: "holding rows: " <> Enum.join(holding, ", ")
end
