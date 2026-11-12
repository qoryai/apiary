defmodule Mix.Tasks.ApiaryPro.Notices do
  @shortdoc "Writes THIRD_PARTY_NOTICES from the dependencies' licences and Qory Apiary's"

  @moduledoc """
  Writes `THIRD_PARTY_NOTICES`, which the image carries beside the release: Qory Apiary's
  notice and licence, which the Apache License 2.0 asks a redistribution to carry, then,
  for every package of `mix.lock`, its name, version and licences, with the licence and
  notice files the package ships.

      mix apiary_pro.notices                  # writes THIRD_PARTY_NOTICES
      mix apiary_pro.notices --output PATH

  A Hex package's licences are those its metadata names (`hex_metadata.config`). A Git
  dependency has no metadata, and its checkout may leave its licence file out (a sparse
  checkout); its entry names the repository and the commit, where the licence is. The
  dependencies must be fetched (`mix deps.get`).
  """

  use Mix.Task

  @licence_file ~r/^(licen[cs]e|copying|notice)(\.(md|txt))?$/i
  @rule String.duplicate("=", 80)

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [output: :string])
    output = Keyword.get(opts, :output, "THIRD_PARTY_NOTICES")
    File.write!(output, notices())
    Mix.shell().info("Wrote #{output}")
  end

  @doc """
  notices/0 is the text of the notices: Qory Apiary's notice and licence, then every package
  of the project's lock, by name.
  """
  @spec notices() :: String.t()
  def notices do
    paths = Mix.Project.deps_paths()
    lock = read_lock(Mix.Project.config()[:lockfile] || "mix.lock")

    core = entry("Qory Apiary (apiary)", [], files(File.cwd!(), present(["NOTICE", "LICENSE"])))

    packages =
      for {name, locked} <- Enum.sort(lock), dir = paths[name], dir != nil do
        package(name, locked, dir)
      end

    Enum.join(
      [
        "Third-party notices\n\nQory Apiary carries the software below, each under its " <>
          "licence: Qory Apiary itself,\nand the packages it is built with.\n"
        | [core | packages]
      ],
      "\n"
    )
  end

  # The lock as Mix writes it, a map of quoted atoms, read without the warnings its quotes
  # would give Elixir's parser.
  defp read_lock(path) do
    {lock, _binding} =
      path |> File.read!() |> Code.string_to_quoted!(emit_warnings: false) |> Code.eval_quoted()

    lock
  end

  defp package(name, {:hex, hex_name, version, _hash, _managers, _deps, _repo, _}, dir),
    do: hex(name, hex_name, version, dir)

  defp package(name, {:hex, hex_name, version, _hash, _managers, _deps, _repo}, dir),
    do: hex(name, hex_name, version, dir)

  defp package(name, {:git, url, commit, _opts}, dir) do
    entry("#{name} (Git)", ["Source: #{url} at #{commit}"], licence_files(dir), fn ->
      "The checkout carries no licence file; the licence is in the repository.\n"
    end)
  end

  defp hex(name, hex_name, version, dir) do
    header = [
      "Licences: " <> Enum.join(hex_licences(dir), ", "),
      "Source: https://hex.pm/packages/#{hex_name}/#{version}"
    ]

    entry("#{name} #{version}", header, licence_files(dir), fn ->
      "The package carries no licence file; its licences are named above.\n"
    end)
  end

  defp hex_licences(dir) do
    with {:ok, metadata} <- :file.consult(Path.join(dir, "hex_metadata.config")),
         {_key, [_ | _] = licences} <- List.keyfind(metadata, "licenses", 0) do
      licences
    else
      _ -> ["not named in the package"]
    end
  end

  defp licence_files(dir) do
    case File.ls(dir) do
      {:ok, names} -> files(dir, names |> Enum.filter(&(&1 =~ @licence_file)) |> Enum.sort())
      {:error, _} -> []
    end
  end

  # The project's notice and licence, those of its files that exist in the working directory.
  defp present(names), do: Enum.filter(names, &File.regular?/1)

  defp files(dir, names), do: for(name <- names, do: File.read!(Path.join(dir, name)))

  defp entry(title, header, texts, none \\ fn -> "" end) do
    body = if texts == [], do: [none.()], else: texts
    Enum.join([@rule, title | header] ++ [@rule, ""], "\n") <> Enum.join(body, "\n")
  end
end
