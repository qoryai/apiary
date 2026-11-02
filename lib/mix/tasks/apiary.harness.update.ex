defmodule Mix.Tasks.Apiary.Harness.Update do
  @shortdoc "Copies the Qory harness's template and stack files at a commit into priv/harness/qory"

  @moduledoc false

  # Copies files of the Qory harness, as a commit of a checkout of qoryai/harness has
  # them, into `priv/harness/qory/`, and writes the commit's full id to
  # `priv/harness/qory/.harness-ref`. A release runs it when the Qory harness's pin
  # (`Apiary.Lingo.Domain.Definition`) moves, and commits what it writes
  # (`docs/releases.md`); Qory Apiary reads the copy when it is compiled
  # (`Apiary.Harnesses.QoryCopy`).
  #
  #     mix apiary.harness.update ../harness 0968239f
  #     mix apiary.harness.update ../harness 0968239f --output out --texts out/texts.ex
  #
  # The commit is 7 to 64 lower-case hex digits; `git rev-parse` turns it into the full
  # id, which must start with those digits: a branch or tag with that name stops the task. Each file is read at that commit with `git show <commit>:<path>`, never from the
  # checkout's working tree, and must pass `Apiary.Harnesses.Reader.parse/1`. A missing
  # file, or a file the reader refuses, stops the task before anything is written.
  #
  # The task also writes `lib/apiary/harnesses/qory_copy/texts.ex`: the name, summary
  # and description of each template in `@templates`, as `pgettext("workspace type", …)`
  # calls, so that `mix gettext.extract` keeps them. Run `mix gettext.extract --merge`
  # after the task.

  use Mix.Task

  @requirements ["app.config"]

  alias Apiary.Harnesses.Reader

  @output "priv/harness/qory"
  @texts "lib/apiary/harnesses/qory_copy/texts.ex"
  @ref_file ".harness-ref"

  # The modules of the Qory harness that are templates: each has `process.yaml`.
  @templates ["software-factory"]

  @files ["qory.yaml"] ++
           Enum.map(@templates, &"modules/#{&1}/process.yaml") ++
           ["stacks/core/qory-stack.yaml", "stacks/software/qory-stack.yaml"]

  @commit ~r/\A[0-9a-f]{7,64}\z/
  @full_commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @doc false
  # files/0 is the paths the task copies, relative to the harness's root and to the
  # output folder.
  @spec files() :: [String.t()]
  def files, do: @files

  @doc false
  # templates/0 is the modules of the Qory harness whose `process.yaml` the task copies.
  @spec templates() :: [String.t()]
  def templates, do: @templates

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [output: :string, texts: :string])

    {checkout, given} =
      case rest do
        [checkout, commit] -> {checkout, commit}
        _other -> Mix.raise("Give a checkout of the Qory harness and a commit: #{usage()}")
      end

    unless Regex.match?(@commit, given),
      do: Mix.raise("Give the commit as 7 to 64 lower-case hex digits, not #{inspect(given)}.")

    {:ok, _apps} = Application.ensure_all_started(:yamerl)

    output = Keyword.get(opts, :output, @output)
    texts_path = Keyword.get(opts, :texts, @texts)
    commit = full_commit(checkout, given)
    files = Enum.map(@files, &{&1, read(checkout, commit, &1)})

    texts =
      for template <- @templates,
          do: {template, template_texts(Map.new(files), "modules/#{template}/process.yaml")}

    for {path, bytes} <- files, do: write!(Path.join(output, path), bytes)
    write!(Path.join(output, @ref_file), commit <> "\n")
    write!(texts_path, texts_module(texts))

    Mix.shell().info(
      "Copied #{length(files)} files at #{commit} to #{output} and wrote #{texts_path}. " <>
        "Run mix gettext.extract --merge."
    )
  end

  defp usage, do: "mix apiary.harness.update <checkout> <commit>"

  defp full_commit(checkout, given) do
    case git(checkout, ["rev-parse", "--verify", "--quiet", given <> "^{commit}"]) do
      {out, 0} ->
        commit = String.trim(out)

        cond do
          not Regex.match?(@full_commit, commit) ->
            Mix.raise(
              "Check the commit id: git rev-parse returned #{inspect(commit)} for #{given}."
            )

          # git takes a branch or tag of that name before an abbreviated commit id.
          not String.starts_with?(commit, given) ->
            Mix.raise(
              "Give the full commit id: #{given} is a branch or tag of #{checkout}, " <>
                "at #{commit}."
            )

          true ->
            commit
        end

      {_out, _status} ->
        Mix.raise("Run git fetch in #{checkout}: it has no commit #{given}.")
    end
  end

  defp read(checkout, commit, path) do
    case git(checkout, ["show", "#{commit}:#{path}"]) do
      {bytes, 0} ->
        case Reader.parse(bytes) do
          {:ok, value} when is_map(value) ->
            bytes

          {:ok, _other} ->
            Mix.raise("Correct #{path} at #{commit}: it is not a YAML mapping.")

          {:error, reason} ->
            Mix.raise("Correct #{path} at #{commit}: it is not readable (#{inspect(reason)}).")
        end

      {_out, _status} ->
        Mix.raise("Choose a commit that has #{path}: #{commit} has no such file.")
    end
  end

  defp git(checkout, args) do
    unless File.dir?(checkout),
      do: Mix.raise("Give a checkout folder: #{checkout} is not a folder.")

    System.cmd("git", ["-C", checkout | args])
  end

  defp template_texts(files, path) do
    {:ok, process} = files |> Map.fetch!(path) |> Reader.parse()

    for key <- ["name", "summary", "description"], into: %{} do
      case process[key] do
        text when is_binary(text) and text != "" -> {String.to_atom(key), text}
        _other -> Mix.raise("Add the text #{key} to #{path}.")
      end
    end
  end

  @doc false
  # texts_module/1 is the source of `Apiary.Harnesses.QoryCopy.Texts` for `texts`, each
  # template's module name and its name, summary and description, formatted as
  # `mix format` writes it.
  @spec texts_module([
          {String.t(), %{name: String.t(), summary: String.t(), description: String.t()}}
        ]) ::
          String.t()
  def texts_module(texts) do
    clauses =
      Enum.map_join(texts, "\n\n", fn {template, text} ->
        """
        def texts(#{literal(template)}),
          do: %{
            name: pgettext("workspace type", #{literal(text.name)}),
            summary: pgettext("workspace type", #{literal(text.summary)}),
            description: pgettext("workspace type", #{literal(text.description)})
          }
        """
      end)

    source = """
    defmodule Apiary.Harnesses.QoryCopy.Texts do
      # Written by `mix apiary.harness.update` from the templates' `process.yaml` in
      # priv/harness/qory/; edit the task, not this file. The texts are in the
      # `workspace type` context, so that `mix gettext.extract` keeps them.
      @moduledoc false

      use Gettext, backend: ApiaryWeb.Gettext

      @doc false
      # texts/1 is the name, summary and description of the template in the module
      # `template` of the Qory harness, translated in the locale of the caller's process;
      # nil for a module that is no template.
      @spec texts(String.t()) ::
              %{name: String.t(), summary: String.t(), description: String.t()} | nil
      #{clauses}

      def texts(_template), do: nil
    end
    """

    IO.iodata_to_binary([Code.format_string!(source), "\n"])
  end

  defp literal(text), do: inspect(text, printable_limit: :infinity, limit: :infinity)

  defp write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    temp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    try do
      File.write!(temp, bytes)
      File.rename!(temp, path)
    after
      File.rm(temp)
    end
  end
end
