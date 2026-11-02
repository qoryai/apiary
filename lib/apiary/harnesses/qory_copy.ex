defmodule Apiary.Harnesses.QoryCopy do
  # The files of the Qory harness that `mix apiary.harness.update` copied into
  # priv/harness/qory/, at the commit in priv/harness/qory/.harness-ref, which is the
  # newest version this release ships (`Apiary.Lingo.Domain.Definition.qory_harness/0`).
  # Read when the module is compiled, so a release has the copy and nothing reads the
  # folder while it runs. The ref file's one line is 40 or 64 lower-case hex digits, or
  # the compile stops. The templates' texts are in `Apiary.Harnesses.QoryCopy.Texts`.
  @moduledoc false

  @dir Path.expand("../../../priv/harness/qory", __DIR__)
  @ref_path Path.join(@dir, ".harness-ref")
  @external_resource @ref_path

  @ref (case File.read!(@ref_path) |> String.split("\n", trim: true) do
          [ref] ->
            if Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, ref),
              do: ref,
              else: raise("#{@ref_path} has no full commit id: #{inspect(ref)}")

          lines ->
            raise "#{@ref_path} has #{length(lines)} lines, not one"
        end)

  @paths @dir
         |> Path.join("**/*.yaml")
         |> Path.wildcard(match_dot: false)
         |> Enum.map(&Path.relative_to(&1, @dir))
         |> Enum.sort()

  for path <- @paths, do: @external_resource(Path.join(@dir, path))

  @files Map.new(@paths, &{&1, File.read!(Path.join(@dir, &1))})

  # A file added to or removed from the folder recompiles the module.
  @doc false
  def __mix_recompile__? do
    @dir
    |> Path.join("**/*.yaml")
    |> Path.wildcard(match_dot: false)
    |> Enum.map(&Path.relative_to(&1, @dir))
    |> Enum.sort() != @paths
  end

  @doc false
  # ref/0 is the full id of the commit the files were copied from.
  @spec ref() :: String.t()
  def ref, do: @ref

  @doc false
  # paths/0 is the copied files, by their path in the harness, in order.
  @spec paths() :: [String.t()]
  def paths, do: @paths

  @doc false
  # file/1 is the bytes of the copied file at `path` in the harness, nil for a file the
  # copy does not have.
  @spec file(String.t()) :: binary | nil
  def file(path) when is_binary(path), do: Map.get(@files, path)
end
