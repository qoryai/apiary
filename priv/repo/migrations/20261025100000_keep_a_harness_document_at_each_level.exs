defmodule Apiary.Repo.Migrations.KeepAHarnessDocumentAtEachLevel do
  use Ecto.Migration

  # A stack row keeps a harness document in place of a stack name or a stack reference
  # (`Apiary.Stacks.Stack`): the contents of the `harness` section of qory's format,
  # written in YAML. `stacks.stack` (text, not null) becomes `stacks.harness` (text,
  # nullable), since a row may set only the workflow: the check
  # `stacks_harness_or_workflow` takes a row with a document, a workflow, or both. The
  # check on the old value's form goes, and a document has at most 65,536 bytes.
  #
  # Up converts each reference `<url>#<ref>:<path>` to the document
  # `extends: {git: <url>, ref: <ref>, path: <path>}`. A name has no address, so up stops
  # before it changes anything when a row has one. Down converts a document of exactly
  # that form back to its reference, and stops before it changes anything on any other
  # document or on a row without one.

  # A stack name, and the parts of a stack reference as `Apiary.Contract.Stack` checked
  # them on save: the URL has no `#`, and the ref has no `:`.
  @name ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @reference ~r/\A(https:\/\/[^#]+)#([^:]+):(.+)\z/s

  def up do
    rows =
      for [id, stack] <- rows("stack") do
        cond do
          Regex.match?(@name, stack) ->
            raise "Replace each stack set by name with a stack reference, then migrate again."

          match = Regex.run(@reference, stack, capture: :all_but_first) ->
            [url, ref, path] = match
            {id, document(url, ref, path)}

          true ->
            raise "Replace each stack that is not a stack reference with one, then migrate again."
        end
      end

    drop constraint(:stacks, :stacks_stack_format)
    rename table(:stacks), :stack, to: :harness

    alter table(:stacks) do
      modify :harness, :text, null: true
    end

    flush()
    update!(rows)

    create constraint(:stacks, :stacks_harness_or_workflow,
             check: "harness IS NOT NULL OR workflow IS NOT NULL"
           )

    create constraint(:stacks, :stacks_harness_size, check: "octet_length(harness) <= 65536")
  end

  def down do
    rows =
      for [id, harness] <- rows("harness") do
        case reference(harness) do
          nil ->
            raise "Replace each harness document that is not of the form " <>
                    "extends: {git, ref, path} with one, or delete its row, then roll back again."

          reference ->
            {id, reference}
        end
      end

    drop constraint(:stacks, :stacks_harness_size)
    drop constraint(:stacks, :stacks_harness_or_workflow)
    flush()
    update!(rows)

    alter table(:stacks) do
      modify :harness, :text, null: false
    end

    rename table(:stacks), :harness, to: :stack

    create constraint(:stacks, :stacks_stack_format,
             check: """
             stack ~ '^[a-z][a-z0-9-]{0,63}$'
             OR (stack LIKE 'https://%' AND char_length(stack) <= 2560)
             """
           )
  end

  defp rows(column) do
    %{rows: rows} = repo().query!("SELECT id, #{column} FROM stacks ORDER BY id", [])
    rows
  end

  defp update!(rows) do
    for {id, value} <- rows do
      repo().query!("UPDATE stacks SET harness = $1 WHERE id = $2", [value, id])
    end
  end

  # The document of a reference's parts. None of the three contains `"` or `\`, so each
  # is written as a double-quoted YAML scalar as it is.
  defp document(url, ref, path),
    do: ~s(extends:\n  git: "#{url}"\n  ref: "#{ref}"\n  path: "#{path}"\n)

  # The reference of a document of exactly the form `extends: {git, ref, path}`, each a
  # text, that the old check takes; nil for any other value.
  defp reference(harness) when is_binary(harness) do
    with {:ok, %{"extends" => %{"git" => url, "ref" => ref, "path" => path} = base} = doc}
         when map_size(doc) == 1 and map_size(base) == 3 <-
           Apiary.Harnesses.Reader.document(harness),
         true <- Enum.all?([url, ref, path], &is_binary/1),
         reference = "#{url}##{ref}:#{path}",
         [^url, ^ref, ^path] <- Regex.run(@reference, reference, capture: :all_but_first),
         true <- String.length(reference) <= 2560 do
      reference
    else
      _other -> nil
    end
  end

  defp reference(nil), do: nil
end
