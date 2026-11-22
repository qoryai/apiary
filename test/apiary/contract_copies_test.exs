defmodule Apiary.ContractCopiesTest do
  use ExUnit.Case, async: true

  # Every copy of a qoryai/integrations contract in this repository is the file at the
  # integrations commit `@ref`. CI has no integrations checkout, so the files are checked
  # against `test/fixtures/contract-copies.sha256`: the SHA-256 and the path here of each
  # file at that commit, one per line, sorted by path. `.integration-contract-ref` has the
  # command that writes that manifest again after a new copy.
  @ref "effc22aa2dc85997333918dba64425bdade7f5dc"

  @root Path.expand("../..", __DIR__)

  # The folders that contain only copies. Each has a `.contract-ref` with the commit of its
  # copies, except priv/contract/diagnostics/v1, priv/contract/explore/v1 and
  # priv/contract/integration: `.integration-contract-ref` covers those three.
  @copied_folders ~w(
    priv/contract/diagnostics/v1
    priv/contract/explore/v1
    priv/contract/integration
    test/fixtures/contract/diagnostics/v1
    test/fixtures/contract/explore/v1
    test/fixtures/contract/integration/v1
    test/fixtures/contract/provisioner/v1
    test/fixtures/contract/run/v1
    test/fixtures/documents-check
    test/fixtures/integration-contract
  )

  # The copies outside the folders of copies.
  @copied_files ~w(lib/apiary/stacks/documents.schema.json)

  # Each file that names the commit of its copies: `.integration-contract-ref` has comment
  # lines, the others one line.
  @ref_files ~w(
    .integration-contract-ref
    lib/apiary/stacks/.contract-ref
    test/fixtures/contract/diagnostics/v1/.contract-ref
    test/fixtures/contract/explore/v1/.contract-ref
    test/fixtures/contract/integration/v1/.contract-ref
    test/fixtures/contract/provisioner/v1/.contract-ref
    test/fixtures/contract/run/v1/.contract-ref
    test/fixtures/documents-check/.contract-ref
  )

  # The ref files that name a commit of another repository: this test leaves them alone.
  @other_ref_files %{
    ".forager-contract-ref" => "Forager",
    "priv/contract/harness/v1/.contract-ref" => "qory"
  }

  # The folders that contain no source file of this repository: the search for ref files
  # skips each folder with one of these names.
  @skipped_folders ~w(.git .elixir_ls _build cover deps node_modules tmp)

  @manifest "test/fixtures/contract-copies.sha256"
            |> then(&Path.join(@root, &1))
            |> File.read!()
            |> String.split("\n", trim: true)
            |> Map.new(fn line ->
              [sha256, path] = String.split(line, "  ", parts: 2)
              {path, sha256}
            end)

  @external_resource Path.join(@root, "test/fixtures/contract-copies.sha256")

  test "every copy matches its SHA-256 in contract-copies.sha256" do
    for {path, sha256} <- @manifest do
      bytes =
        case File.read(Path.join(@root, path)) do
          {:ok, bytes} ->
            bytes

          {:error, _} ->
            flunk("Copy #{path} again from integrations #{@ref}. The file is missing.")
        end

      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha256,
             "Copy #{path} again from integrations #{@ref}. The bytes differ."
    end
  end

  test "no file is in a folder of copies that the integrations commit lacks" do
    present =
      for folder <- @copied_folders,
          path <- Path.wildcard(Path.join([@root, folder, "**", "*"]), match_dot: true),
          File.regular?(path),
          Path.basename(path) != ".contract-ref",
          do: Path.relative_to(path, @root)

    for path <- present do
      assert Map.has_key?(@manifest, path),
             "Delete #{path}. Integrations #{@ref} has no such file."
    end
  end

  # With the test above, a row missing from the manifest fails: each copy is in a folder of
  # copies or in @copied_files, and each of those is in the manifest.
  test "every row of the manifest is a copy in a folder of copies or in @copied_files" do
    for path <- Map.keys(@manifest) do
      assert path in @copied_files or
               Enum.any?(@copied_folders, &String.starts_with?(path, &1 <> "/")),
             "Add the folder of #{path} to @copied_folders, or #{path} to @copied_files, in " <>
               "test/apiary/contract_copies_test.exs."
    end

    for path <- @copied_files do
      assert Map.has_key?(@manifest, path),
             "Write the manifest again with the command in .integration-contract-ref: " <>
               "test/fixtures/contract-copies.sha256 has no row for #{path}."
    end
  end

  # The test finds every file whose name ends in `contract-ref`, so a ref file missing from
  # @ref_files fails too: each names @ref unless @other_ref_files has it.
  test "every ref file of an integrations copy is listed and contains the commit of the copies" do
    found = @root |> ref_files() |> Enum.reject(&Map.has_key?(@other_ref_files, &1))

    for file <- @ref_files do
      assert file in found,
             "Write #{@ref} in #{file}, after you copy its files again from integrations " <>
               "#{@ref}. The file is missing."
    end

    for file <- found do
      assert file in @ref_files,
             "Add #{file} to @ref_files in test/apiary/contract_copies_test.exs, or to " <>
               "@other_ref_files if it names a commit of another repository."

      lines = file |> ref_lines() |> Enum.reject(&String.starts_with?(&1, "#"))

      assert lines == [@ref],
             "Copy the files of #{Path.dirname(file)} again from integrations #{@ref}, " <>
               "then write #{@ref} in #{file}. It has #{inspect(lines)}."

      folder = Path.dirname(file)

      assert folder in @copied_folders or
               file in ~w(.integration-contract-ref lib/apiary/stacks/.contract-ref),
             "Add #{folder} to @copied_folders in test/apiary/contract_copies_test.exs, " <>
               "and its files to test/fixtures/contract-copies.sha256."
    end
  end

  defp ref_lines(file),
    do: @root |> Path.join(file) |> File.read!() |> String.split("\n", trim: true)

  defp ref_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)

      case File.lstat!(path).type do
        :directory ->
          if name in @skipped_folders, do: [], else: ref_files(path)

        :regular ->
          if String.ends_with?(name, "contract-ref"),
            do: [Path.relative_to(path, @root)],
            else: []

        _other ->
          []
      end
    end)
  end
end
