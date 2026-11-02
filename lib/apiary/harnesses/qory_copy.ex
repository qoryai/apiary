defmodule Apiary.Harnesses.QoryCopy do
  # The files of the Qory harness that `mix apiary.harness.update` copied into
  # priv/harness/qory/, at the commit in priv/harness/qory/.harness-ref. Read when the
  # module is compiled, so a release has the copy and nothing reads the folder while it
  # runs. The ref file's one line is 40 or 64 lower-case hex digits, or the compile
  # stops. The templates' texts are in `Apiary.Harnesses.QoryCopy.Texts`.
  #
  # `template/0` and `workflows/1` decode the bytes on first use and keep the result in
  # `:persistent_term`. `template/0` cannot run when this module is compiled, because
  # `Reader.template/1` reads its schema from the application's priv folder.
  @moduledoc false

  alias Apiary.Harnesses.{QoryCopy.Texts, Reader}

  # The module of the Qory harness with the software type's template.
  @template "software-factory"

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

  @doc false
  # template/0 is the copied template of the software type, as `Reader.template/1` reads
  # it. Raises for a file the reader refuses, which the tests of the copy would catch.
  @spec template() :: Reader.template()
  def template do
    kept(:template, fn ->
      {:ok, template} = Reader.template(file("modules/#{@template}/process.yaml"))
      template
    end)
  end

  @doc false
  # template_module/0 is the name of the module of the Qory harness with that template.
  @spec template_module() :: String.t()
  def template_module, do: @template

  @doc false
  # texts/0 is the name, summary and description of the copied template, translated in
  # the locale of the caller's process.
  @spec texts() :: %{name: String.t(), summary: String.t(), description: String.t()}
  def texts, do: Texts.texts(@template)

  @doc false
  # workflows/1 is the workflow names the copied stack `stack` lists, sorted. Raises for
  # a stack the copy does not have.
  @spec workflows(String.t()) :: [String.t()]
  def workflows(stack) when is_binary(stack) do
    kept({:workflows, stack}, fn ->
      {:ok, %{workflows: workflows}} = Reader.stack(file("stacks/#{stack}/qory-stack.yaml"))
      workflows |> Map.keys() |> Enum.sort()
    end)
  end

  defp kept(key, decode) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil ->
        value = decode.()
        :persistent_term.put({__MODULE__, key}, value)
        value

      value ->
        value
    end
  end
end
