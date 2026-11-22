defmodule Apiary.ContractCopiesTest do
  use ExUnit.Case, async: true

  # Every copy of the qoryai/integrations integration contract and data descriptions in this
  # repository is the file at the integrations commit `@ref`. The run, explore, diagnostics
  # and provisioner contracts are at earlier commits, which other tests check (see
  # @other_ref_files). CI has no integrations checkout, so the files are checked
  # against `test/fixtures/contract-copies.sha256`: the SHA-256 and the path here of each
  # file at that commit, one per line, sorted by path. `.integration-contract-ref` has the
  # command that writes that manifest again after a new copy.
  @ref "effc22aa2dc85997333918dba64425bdade7f5dc"

  @root Path.expand("../..", __DIR__)

  # The folders that contain only copies at @ref. test/fixtures/contract/integration/v1 has
  # a `.contract-ref` with @ref; `.integration-contract-ref` covers the other two.
  @copied_folders ~w(
    priv/contract/integration
    test/fixtures/contract/integration/v1
    test/fixtures/integration-contract
  )

  # Each file that contains the commit of its copies: `.integration-contract-ref` has comment
  # lines, the others one line.
  @ref_files ~w(
    .integration-contract-ref
    test/fixtures/contract/integration/v1/.contract-ref
  )

  # The ref files of other copies, with the place that checks each: this test leaves them
  # alone.
  @other_ref_files %{
    ".forager-contract-ref" => "a Forager commit",
    "priv/contract/harness/v1/.contract-ref" => "a qory commit",
    "lib/apiary/stacks/.contract-ref" => "test/apiary/dispatches/wire_test.exs",
    "test/fixtures/contract/diagnostics/v1/.contract-ref" =>
      "test/apiary/dispatches/wire_test.exs",
    "test/fixtures/contract/explore/v1/.contract-ref" => "test/apiary/dispatches/wire_test.exs",
    "test/fixtures/contract/provisioner/v1/.contract-ref" =>
      "test/apiary/dispatches/wire_test.exs",
    "test/fixtures/contract/run/v1/.contract-ref" => "test/apiary/dispatches/wire_test.exs",
    "test/fixtures/documents-check/.contract-ref" =>
      "test/apiary_web/contract/documents_check_test.exs"
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
             "Delete #{path} if integrations #{@ref} has no such file; else write " <>
               "test/fixtures/contract-copies.sha256 again with the command in " <>
               ".integration-contract-ref."
    end
  end

  # With the test above, the manifest and the folders of copies list the same files: a row
  # missing from the manifest fails there, and a row outside the folders fails here.
  test "every row of the manifest is a copy in a folder of copies" do
    for path <- Map.keys(@manifest) do
      assert Enum.any?(@copied_folders, &String.starts_with?(path, &1 <> "/")),
             "Delete the row of #{path} from test/fixtures/contract-copies.sha256, or add " <>
               "its folder to @copied_folders in test/apiary/contract_copies_test.exs."
    end
  end

  # The test finds every file whose name ends in `contract-ref`, so a ref file missing from
  # @ref_files fails too: each contains @ref unless @other_ref_files has it.
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
               "@other_ref_files with the test that checks its commit."

      lines = file |> ref_lines() |> Enum.reject(&String.starts_with?(&1, "#"))

      assert lines == [@ref],
             "Copy the files of #{Path.dirname(file)} again from integrations #{@ref}, " <>
               "then write #{@ref} in #{file}. It has #{inspect(lines)}."

      folder = Path.dirname(file)

      assert folder in @copied_folders or file == ".integration-contract-ref",
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
