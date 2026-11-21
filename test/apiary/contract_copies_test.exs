defmodule Apiary.ContractCopiesTest do
  use ExUnit.Case, async: true

  # Every copy of a qoryai/integrations contract in this repository is the file at the
  # integrations commit `@ref`. CI has no integrations checkout, so the files are checked
  # against `test/fixtures/contract-copies.sha256`: the SHA-256 and the path here of each
  # file at that commit, one per line, sorted by path.
  @ref "effc22aa2dc85997333918dba64425bdade7f5dc"

  @root Path.expand("../..", __DIR__)

  # The folders that hold only copies and the `.contract-ref` of the commit they come from.
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

  @manifest "test/fixtures/contract-copies.sha256"
            |> then(&Path.join(@root, &1))
            |> File.read!()
            |> String.split("\n", trim: true)
            |> Map.new(fn line ->
              [sha256, path] = String.split(line, "  ", parts: 2)
              {path, sha256}
            end)

  @external_resource Path.join(@root, "test/fixtures/contract-copies.sha256")

  test "every ref file holds the commit of the copies" do
    for file <- @ref_files do
      lines =
        @root
        |> Path.join(file)
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))

      assert lines == [@ref],
             "Write #{@ref} in #{file}, after you copy its files again from integrations #{@ref}."
    end
  end

  test "every copied file is the bytes of the integrations commit" do
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
end
