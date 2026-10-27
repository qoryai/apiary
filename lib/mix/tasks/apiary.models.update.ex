defmodule Mix.Tasks.Apiary.Models.Update do
  @shortdoc "Writes the Model field's suggestions from the model list of models.dev"

  @moduledoc false

  # Writes `priv/models/suggestions.json`: for each model provider of the catalogue, one
  # file of `priv/contract/integration/descriptions/`, the model ids and titles that the
  # Model field suggests (`Apiary.ModelChoices.suggestions/2`), from the model list of
  # models.dev. A release runs it and commits the file (`docs/releases.md`); Qory Apiary
  # reads the file when it is compiled and downloads nothing while it runs.
  #
  #     mix apiary.models.update                    # download https://models.dev/api.json
  #     mix apiary.models.update --file api.json    # read a saved copy of it instead
  #     mix apiary.models.update --output out.json  # write there, not to the priv file
  #
  # Each provider takes the models of the models.dev provider `@sources` maps it to, with
  # the ids as models.dev lists them; one mapped to nil takes none. A provider that
  # `@sources` does not map stops the task, so a new description needs a line there.
  #
  # The download goes to the one fixed URL over HTTPS, with no redirect and no retry, the
  # server's certificate verified against the system's CA certificates and its host name.
  # The connection has 15 seconds to open and each read 30 seconds; the whole download
  # runs in a separate process that the task stops after 60 seconds. A body over 32 MB,
  # like a saved copy over 32 MB, stops the task.
  # The input is decoded with Jason alone and must be a JSON object whose mapped providers
  # are each an object with a `models` object. A model is kept when it is an object whose
  # `id` matches `@id` and whose `name`, the title, matches `@title`, and its `status` is
  # not `deprecated`, and no other kept model with the same id comes before it in the
  # order of id, then title; each model left out is printed with the reason. A provider with more
  # than 1,000 kept models stops the task, and nothing is written.
  #
  # The file is one JSON object: the providers in the order of their name, each a list of
  # `id` and `title` in the order of the id, one model a line, so the same input gives the
  # same bytes. It is written to a temporary file beside the output, then renamed onto it.

  use Mix.Task

  @url "https://models.dev/api.json"

  @output "priv/models/suggestions.json"
  @descriptions "priv/contract/integration/descriptions"

  # Each provider of the catalogue, by the name of its description, and the models.dev
  # provider whose ids its API takes. claude-subscription calls Anthropic's API with the
  # same model ids; a LiteLLM proxy serves the models set up in that proxy, under names
  # no list has.
  @sources %{
    "anthropic" => "anthropic",
    "claude-subscription" => "anthropic",
    "deepseek" => "deepseek",
    "litellm" => nil,
    "openrouter" => "openrouter"
  }

  @max_bytes 32_000_000
  @max_models 1_000

  # A model id, within the form a model choice takes (`Apiary.ModelChoices`), and a title
  # of letters, digits, spaces and a few marks.
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,127}\z/
  @title ~r/\A[A-Za-z0-9][A-Za-z0-9 .,:()\/+&'_-]{0,127}\z/

  @id_refused "the id is not 1 to 128 letters, digits and ._:/@+-, from a letter or digit"
  @title_refused "the title is not 1 to 128 letters, digits, spaces and .,:()/+&'_-, " <>
                   "from a letter or digit"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [file: :string, output: :string])
    output = Keyword.get(opts, :output, @output)

    names =
      @descriptions
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".json"))

    if names == [],
      do:
        Mix.raise(
          "Run the task from the repository root: #{@descriptions} has no .json file here."
        )

    {suggestions, left_out} = opts |> Keyword.get(:file) |> read() |> decode() |> build(names)

    for {provider, id, reason} <- left_out,
        do:
          Mix.shell().error(
            "Left out #{provider} #{inspect(id, printable_limit: 80, limit: 5)}: #{reason}."
          )

    write!(output, encode(suggestions))

    counts =
      Enum.map_join(suggestions, ", ", fn {name, models} -> "#{name} #{length(models)}" end)

    Mix.shell().info("Wrote #{output}: #{counts}.")
  end

  @doc false
  # build/2 is the suggestions of the providers named `names` from `api`, the decoded
  # models.dev list: `{[{name, [%{id: id, title: title}]}], left_out}`, the providers in
  # the order of their name and each one's models in the order of their id; `left_out` is
  # each model not kept, `{name, id, reason}`. Raises for a name `@sources` does not map,
  # for a mapped models.dev provider that `api` lacks, and for more than 1,000 models.
  @spec build(map, [String.t()]) ::
          {[{String.t(), [%{id: String.t(), title: String.t()}]}],
           [{String.t(), term, String.t()}]}
  def build(api, names) when is_map(api) do
    results = for name <- Enum.sort(Enum.uniq(names)), do: {name, provider(api, name)}

    {for({name, {models, _left_out}} <- results, do: {name, models}),
     for({name, {_models, left_out}} <- results, {id, reason} <- left_out, do: {name, id, reason})}
  end

  defp provider(api, name) do
    case Map.fetch(@sources, name) do
      {:ok, nil} ->
        {[], []}

      {:ok, source} ->
        models(api, source)

      :error ->
        Mix.raise(
          "Add #{name} to @sources in lib/mix/tasks/apiary.models.update.ex: it maps no provider."
        )
    end
  end

  defp models(api, source) do
    entries =
      case api do
        %{^source => %{"models" => models}} when is_map(models) -> Map.values(models)
        _other -> Mix.raise("The models.dev list has no models object for #{source}.")
      end

    {kept, left_out} =
      Enum.reduce(entries, {[], []}, fn entry, {kept, left_out} ->
        case check(entry) do
          {:ok, model} -> {[model | kept], left_out}
          {:error, id, reason} -> {kept, [{id, reason} | left_out]}
        end
      end)

    {kept, repeated} =
      kept
      |> Enum.sort_by(&{&1.id, &1.title})
      |> Enum.chunk_by(& &1.id)
      |> Enum.map_reduce([], fn [first | rest], repeated ->
        {first, repeated ++ for(model <- rest, do: {model.id, "another model has the same id"})}
      end)

    left_out = left_out ++ repeated

    if length(kept) > @max_models,
      do: Mix.raise("models.dev lists #{length(kept)} models for #{source}, over #{@max_models}.")

    {kept, Enum.sort_by(left_out, &inspect(elem(&1, 0), printable_limit: 80, limit: 5))}
  end

  defp check(%{"id" => id, "name" => title} = entry) when is_binary(id) and is_binary(title) do
    cond do
      not Regex.match?(@id, id) -> {:error, id, @id_refused}
      not Regex.match?(@title, title) -> {:error, id, @title_refused}
      entry["status"] == "deprecated" -> {:error, id, "models.dev marks it deprecated"}
      true -> {:ok, %{id: id, title: title}}
    end
  end

  defp check(%{"id" => id}), do: {:error, id, "it has no title string"}
  defp check(_entry), do: {:error, nil, "it is not an object with an id"}

  defp read(nil), do: download()

  defp read(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @max_bytes ->
        Mix.raise("#{path} has #{size} bytes, over the limit of #{@max_bytes}.")

      {:ok, _stat} ->
        File.read!(path)

      {:error, reason} ->
        Mix.raise("Cannot read #{path}: #{:file.format_error(reason)}.")
    end
  end

  defp download do
    {:ok, _apps} = Application.ensure_all_started(:req)

    task =
      Task.async(fn ->
        Req.get(@url,
          into: &collect/2,
          redirect: false,
          retry: false,
          raw: true,
          connect_options: [timeout: 15_000, transport_opts: [verify: :verify_peer]],
          receive_timeout: 30_000
        )
      end)

    case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
      nil ->
        Mix.raise("The download of #{@url} took more than 60 seconds and was stopped.")

      {:ok, response} ->
        body(response)
    end
  end

  defp body({:ok, %Req.Response{private: %{too_big: true}}}),
    do: Mix.raise("The download of #{@url} stopped at the limit of #{@max_bytes} bytes.")

  defp body({:ok, %Req.Response{status: 200} = resp}),
    do: resp |> Req.Response.get_private(:body, []) |> IO.iodata_to_binary()

  defp body({:ok, %Req.Response{status: status}}),
    do: Mix.raise("The download of #{@url} returned HTTP #{status}.")

  defp body({:error, exception}),
    do: Mix.raise("The download of #{@url} failed: #{Exception.message(exception)}")

  defp collect({:data, data}, {req, resp}) do
    size = Req.Response.get_private(resp, :size, 0) + byte_size(data)

    if size > @max_bytes do
      {:halt, {req, Req.Response.put_private(resp, :too_big, true)}}
    else
      resp =
        resp
        |> Req.Response.put_private(:size, size)
        |> Req.Response.update_private(:body, [data], &[&1, data])

      {:cont, {req, resp}}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = api} -> api
      {:ok, _other} -> Mix.raise("The models.dev list is not a JSON object.")
      {:error, error} -> Mix.raise("The models.dev list is not JSON: #{Exception.message(error)}")
    end
  end

  @doc false
  # encode/1 is the bytes of the file for `suggestions`, as `build/2` returns them.
  @spec encode([{String.t(), [%{id: String.t(), title: String.t()}]}]) :: String.t()
  def encode(suggestions) do
    providers =
      Enum.map_join(suggestions, ",\n", fn {name, models} ->
        "  " <> Jason.encode!(name) <> ": " <> list(models)
      end)

    "{\n" <> providers <> "\n}\n"
  end

  defp list([]), do: "[]"

  defp list(models) do
    lines =
      Enum.map_join(models, ",\n", fn %{id: id, title: title} ->
        ~s(    {"id": #{Jason.encode!(id)}, "title": #{Jason.encode!(title)}})
      end)

    "[\n" <> lines <> "\n  ]"
  end

  defp write!(output, bytes) do
    File.mkdir_p!(Path.dirname(output))
    temp = "#{output}.#{System.unique_integer([:positive])}.tmp"

    try do
      File.write!(temp, bytes)
      File.rename!(temp, output)
    after
      File.rm(temp)
    end
  end
end
