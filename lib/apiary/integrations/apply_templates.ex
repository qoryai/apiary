defmodule Apiary.Integrations.ApplyTemplates do
  # The apply items of a source role's work credential (`roles.source.apply` of the
  # integrations contract's `description.schema.json`): where and how a run's proxy sets
  # the credential's value, with each path a template in which `{target.path}` stands for
  # the path of the run's target. A start keeps the items (`Apiary.Nodes.Node`'s
  # `source_apply`), and a run's claim fills them (`Apiary.Runs.RunCredentials`).
  #
  # Forager's path grammar is `^/[^*?#\s]*\*?$`, where `\s` is a space character: one
  # below U+0021, U+007F, U+FEFF, U+0085, U+00A0, U+1680, U+2000 to U+200A, U+2028,
  # U+2029, U+202F, U+205F or U+3000. A template contains `{target.path}` at most once,
  # right after a `/`, and the rest of that segment has no `*`; no other `{` or `}`. A
  # template is refused (`problems/2`) when the template filled with a target path
  # (`fill/2`) could leave the grammar, and an item is refused when one of its hosts is
  # not an entry of the description's `egress_hosts`.
  #
  # A target path is refused before any template is filled when it contains `..`, `//`,
  # `*`, `?`, `#` or a space character, or is not UTF-8. Filling replaces the placeholder
  # with the path exactly as the adapter wrote it, with no case folding and no decoding,
  # and leaves out a filled path equal to an earlier filled path of the same item.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  @placeholder "{target.path}"
  @space "\\x{0}-\\x{20}\\x{7F}\\x{85}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}" <>
           "\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"
  @grammar Regex.compile!("\\A/[^*?\\#" <> @space <> "]*\\*?\\z", "u")
  @refused_target Regex.compile!("\\.\\.|//|[*?\\#" <> @space <> "]", "u")
  # The members of an item, in the order a run configuration writes them.
  @members ~w(hosts scheme username header paths)

  @typedoc "An apply item as decoded from JSON: `hosts`, `scheme`, and the members it has."
  @type item :: %{optional(String.t()) => term}

  @doc false
  # problems/2 is what refuses the apply items `items` of a description whose
  # `egress_hosts` string entries are `egress_hosts`: `{:apply_host_not_in_egress_hosts,
  # host}` for a host with no equal entry, and `{:apply_path_invalid, template}` for a
  # template whose filled form could leave the path grammar. `[]` for none, and for nil.
  @spec problems([item] | nil, [String.t()]) :: [{atom, String.t()}]
  def problems(nil, _egress_hosts), do: []

  def problems(items, egress_hosts) when is_list(items) and is_list(egress_hosts) do
    hosts =
      for %{"hosts" => hosts} <- items,
          host <- hosts,
          host not in egress_hosts,
          uniq: true,
          do: {:apply_host_not_in_egress_hosts, host}

    paths =
      for %{"paths" => paths} <- items,
          template <- paths,
          not template?(template),
          uniq: true,
          do: {:apply_path_invalid, template}

    hosts ++ paths
  end

  # Whether `template` stays in the path grammar whatever target path fills it: its
  # placeholder, if any, once, right after a `/`, with no `*` after it in its segment and
  # no other brace; and the template filled with a one-character path in the grammar.
  # A target path `fill/2` takes has none of the characters the grammar refuses, so every
  # path it fills is in the grammar too.
  defp template?(template) when is_binary(template) do
    case String.split(template, @placeholder) do
      [whole] ->
        braceless?(whole) and grammar?(whole)

      [before, rest] ->
        segment = rest |> String.split("/", parts: 2) |> hd()

        String.ends_with?(before, "/") and not String.contains?(segment, "*") and
          braceless?(before <> rest) and grammar?(before <> "x" <> rest)

      _twice ->
        false
    end
  end

  defp template?(_template), do: false

  defp braceless?(text), do: not String.contains?(text, ["{", "}"])

  defp grammar?(path), do: String.valid?(path) and Regex.match?(@grammar, path)

  @doc false
  # target_path?/1 is whether a target path may fill a template: UTF-8 with no `..`, `//`,
  # `*`, `?`, `#` and no space character.
  @spec target_path?(term) :: boolean
  def target_path?(path) when is_binary(path) and path != "",
    do: String.valid?(path) and not Regex.match?(@refused_target, path)

  def target_path?(_path), do: false

  @doc false
  # fill/2 is the apply items `items` with `{target.path}` in each path replaced by
  # `target_path`, each item's members in a run configuration's order and its filled
  # paths with no repeat, the first kept: `{:ok, items}`, or `{:error, :path_refused}`
  # for a target path `target_path?/1` refuses, or a filled path out of the grammar.
  @spec fill([item], String.t()) :: {:ok, [Jason.OrderedObject.t()]} | {:error, :path_refused}
  def fill(items, target_path) when is_list(items) do
    if target_path?(target_path) do
      filled = Enum.map(items, &fill_item(&1, target_path))

      if Enum.all?(filled, &paths_in_grammar?/1),
        do: {:ok, filled},
        else: {:error, :path_refused}
    else
      {:error, :path_refused}
    end
  end

  defp fill_item(%{} = item, target_path) do
    item
    |> Map.replace_lazy("paths", fn paths ->
      paths |> Enum.map(&String.replace(&1, @placeholder, target_path)) |> Enum.uniq()
    end)
    |> ordered()
  end

  @doc false
  # ordered/1 is the apply item `item`, a map, with its members in the schema's order.
  @spec ordered(item) :: Jason.OrderedObject.t()
  def ordered(%{} = item),
    do:
      Jason.OrderedObject.new(
        for name <- @members, Map.has_key?(item, name), do: {name, item[name]}
      )

  defp paths_in_grammar?(%Jason.OrderedObject{values: members}) do
    case List.keyfind(members, "paths", 0) do
      {"paths", paths} -> Enum.all?(paths, &grammar?/1)
      nil -> true
    end
  end

  @doc false
  # hosts/1 is every host of the apply items `items`, each once, in their order.
  @spec hosts([item | Jason.OrderedObject.t()]) :: [String.t()]
  def hosts(items) when is_list(items) do
    items
    |> Enum.flat_map(fn
      %Jason.OrderedObject{} = item -> item["hosts"]
      %{"hosts" => hosts} -> hosts
    end)
    |> Enum.uniq()
  end
end
