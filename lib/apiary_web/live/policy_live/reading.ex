defmodule ApiaryWeb.PolicyLive.Reading do
  @moduledoc """
  The reading line of the rule composer (`docs/design/brief-policy.md`, pd3, pf2 to pf4): a
  rule is read back in plain words before it is saved, and what cannot be said is refused
  in a sentence that names the reason and the ways out.

  Pure: the form and the rules already on the page in, a reading out. No query runs per
  keystroke. The domain checks everything again at the write; this is where a person finds
  out what `*.` means before saving, not where the policy is enforced.

  A reading is `%{kind:, text:, fix:, acts:, invalid:, button:}`:

    * `kind`: `:hint`, `:ok`, `:note`, `:error` or `:refusal`; the button is on for `:ok`
      and `:note`;
    * `text`: rich text, a list of binaries, `{:b, rich}`, `{:m, mono text}` and
      `{:code, chip text}`, rendered by `ApiaryWeb.RichText.rich/1` (always escaped);
    * `fix`: `nil` or `{label, event, values}`, the repair offered as a link;
    * `acts`: more links of the same shape, under a refusal;
    * `invalid`: the fields that take `aria-invalid`;
    * `button`: nil, or the word the submit button takes ("Replace with deny").
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText

  alias Apiary.Policy.Grammar

  @doc "The reading of an empty composer: what a rule is, before anything is typed."
  def hint, do: reading(:hint, hint_text())

  defp hint_text do
    rich_gettext(
      "A host name in lower case, or %{suffix} and a suffix for every host below it. No scheme, no port. Paths go in their own field, separated by spaces.",
      suffix: {:code, "*."}
    )
  end

  @doc """
  Reads a host rule.

  `form` has string keys `"action"`, `"host"`, `"paths"` and `"every"` (`"true"` when every
  path was asked for in so many words). `context`:

    * `scope`: `:hive` or `:target`;
    * `own`: the rules of the scope being edited, maps or structs with `kind`, `action`,
      `host`, `paths`, `locked`, and `by`, `at` when the page knows them;
    * `entries`: the entries of the effective policy (`Apiary.Policy.Entry`);
    * `owner`: whether the reader may change a locked rule;
    * `locked_by`: `%{host => %{by:, at:}}`, who locked what, when the page knows.
  """
  def host_rule(form, context) do
    action = if form["action"] == "deny", do: "deny", else: "allow"
    host = String.trim(form["host"] || "")
    every = form["every"] == "true"
    paths = if action == "deny", do: [], else: split(form["paths"])

    cond do
      host == "" ->
        reading(:hint, hint_text())

      not Grammar.host?(host) ->
        bad_host(host, paths)

      Enum.any?(paths, &(not Grammar.path?(&1))) ->
        reading(:error, bad_path(), invalid: [:paths])

      true ->
        said(action, host, paths, every, context)
    end
  end

  @doc "Reads a credential: a name and an optional argument."
  def credential(form, own) do
    name = String.trim(form["name"] || "")
    argument = String.trim(form["argument"] || "")

    cond do
      name == "" ->
        reading(:hint, [])

      not Grammar.credential_name?(name) ->
        reading(
          :error,
          [
            gettext(
              "A name is 1 to 64 lower-case letters, digits, dots, dashes or underscores, and starts with a letter or digit."
            )
          ],
          invalid: [:name]
        )

      argument != "" and not Grammar.argument?(argument) ->
        reading(:error, [gettext("An argument is at most 256 characters.")], invalid: [:argument])

      existing = Enum.find(own, &(&1.kind == "credential" and &1.name == name)) ->
        if (existing.argument || "") == argument and existing.action == "allow" do
          reading(:error, rich_gettext("%{name} is already named here.", name: {:m, name}),
            invalid: [:name]
          )
        else
          reading(
            :note,
            rich_gettext("%{name} is named here already. Adding it replaces its argument.",
              name: {:m, name}
            ),
            button: gettext("Replace credential")
          )
        end

      true ->
        reading(:ok, [])
    end
  end

  @doc "The paths of a text field: separated by spaces, commas or lines."
  def split(nil), do: []
  def split(text), do: text |> String.split(~r/[\s,]+/u, trim: true) |> Enum.uniq()

  ## Not in the grammar (pf3)

  defp bad_host(host, paths) do
    path_too = if Enum.any?(paths, &(not Grammar.path?(&1))), do: [" " | bad_path()], else: []
    invalid = if path_too == [], do: [:host], else: [:host, :paths]
    rest = String.replace_prefix(host, "*.", "")

    cond do
      String.contains?(rest, "*") ->
        reading(
          :error,
          rich_gettext(
            "%{suffix} may only lead a host: %{example} matches every host below %{domain}.",
            suffix: {:code, "*."},
            example: {:m, "*.example"},
            domain: {:m, "example"}
          ) ++ path_too,
          invalid: invalid
        )

      address?(host) ->
        reading(
          :error,
          rich_gettext(
            "An address is written like a host, digits and dots only: %{address}. The wall refuses the machine's own address whatever the policy says.",
            address: {:m, "10.0.0.12"}
          ) ++ path_too,
          invalid: invalid
        )

      Regex.match?(~r/\A[a-z0-9._-]+\z/, host) ->
        reading(
          :error,
          [
            gettext(
              "Each part of a host is 1 to 63 letters, digits or dashes, and does not start or end with a dash."
            )
            | path_too
          ],
          invalid: invalid
        )

      true ->
        reading(
          :error,
          [
            gettext(
              "A rule names a host and nothing else: lower case, no scheme, no port, no path."
            )
            | path_too
          ],
          invalid: invalid,
          fix: repair(host)
        )
    end
  end

  defp bad_path do
    rich_gettext(
      "A path starts with / and may end in one *; no other wildcard and no query, such as %{example}.",
      example: {:m, "/v1/*"}
    )
  end

  defp address?(host) do
    String.starts_with?(host, "[") or
      Regex.match?(~r/\A\d{1,3}(\.\d{1,3}){3}([:\/].*)\z/, host)
  end

  # A URL, a host with a port or a path, or capitals: the host it names, and its path.
  defp repair(text) do
    case Regex.run(
           ~r/\A(?:[a-z][a-z0-9+.-]*:\/\/)?(?:[^@\/\s]*@)?([^\/:?#\s]+)(?::\d{1,5})?(\/[^?#\s]*)?(?:[?#]\S*)?\z/,
           String.downcase(text)
         ) do
      [_, host | rest] ->
        path =
          case rest do
            [path] when path != "/" -> if Grammar.path?(path), do: path
            _ -> nil
          end

        if Grammar.host?(host) do
          label =
            if path,
              do: gettext("Use %{host} with the path %{path}", host: host, path: path),
              else: gettext("Use %{host}", host: host)

          {label, "composer_use", %{"host" => host, "paths" => path || ""}}
        end

      _ ->
        nil
    end
  end

  ## In the grammar: already there, refused, covered, or said

  defp said(action, host, paths, every, context) do
    own = Enum.filter(context.own, &(&1.kind == "host"))
    existing = Enum.find(own, &(&1.host == host))

    cond do
      existing && existing.locked && !context.owner ->
        refusal([gettext("Only an owner can lock, unlock or change a locked rule.")], [])

      locked = locked_above(action, host, context) ->
        locked_refusal(locked, action, context)

      existing && existing.action == action && same_paths?(existing.paths, paths, every) ->
        reading(
          :error,
          already(action, context.scope, {:m, host}, existing),
          invalid: [:host],
          fix: {gettext("Show it"), "show_rule", %{"host" => host}}
        )

      existing && existing.action != action ->
        reading(:note, replaces(existing.action, context.scope, {:m, host}),
          button:
            if(action == "deny",
              do: gettext("Replace with deny"),
              else: gettext("Replace with allow")
            )
        )

      existing && is_list(existing.paths) && paths == [] && !every ->
        reading(
          :error,
          held(context.scope, {:m, host}, path_chips(existing.paths)),
          invalid: [:paths],
          fix: {gettext("Every path"), "composer_every", %{}}
        )

      existing ->
        reading(
          :note,
          change_paths(
            context.scope,
            {:m, host},
            path_words(existing.paths),
            path_words(if(paths == [], do: nil, else: paths))
          ),
          button: gettext("Change paths")
        )

      cover = action == "allow" && covering_allow(host, context) ->
        reading(
          :note,
          rich_gettext(
            "Already allowed by %{suffix}. Adding it changes nothing today and keeps the host allowed if the suffix rule is removed.",
            suffix: {:code, cover}
          )
        )

      true ->
        reading(:ok, reads_as(action, host, paths, context))
    end
  end

  defp same_paths?(nil, [], _every), do: true
  defp same_paths?(nil, _paths, _every), do: false
  defp same_paths?(_held, [], true), do: false
  defp same_paths?(held, paths, _every), do: Enum.sort(held) == Enum.sort(paths)

  # The same rule again: each action, scope and author is its own sentence.
  defp already(action, scope, host, existing) do
    case {action, scope, by(existing)} do
      {"allow", :hive, {:by, by, at}} ->
        rich_gettext("%{host} is already allowed for the hive, by %{by} on %{at}.",
          host: host,
          by: by,
          at: at
        )

      {"allow", :hive, {:since, at}} ->
        rich_gettext("%{host} is already allowed for the hive, since %{at}.", host: host, at: at)

      {"allow", :hive, nil} ->
        rich_gettext("%{host} is already allowed for the hive.", host: host)

      {"allow", :target, {:by, by, at}} ->
        rich_gettext("%{host} is already allowed for this target, by %{by} on %{at}.",
          host: host,
          by: by,
          at: at
        )

      {"allow", :target, {:since, at}} ->
        rich_gettext("%{host} is already allowed for this target, since %{at}.",
          host: host,
          at: at
        )

      {"allow", :target, nil} ->
        rich_gettext("%{host} is already allowed for this target.", host: host)

      {"deny", :hive, {:by, by, at}} ->
        rich_gettext("%{host} is already denied for the hive, by %{by} on %{at}.",
          host: host,
          by: by,
          at: at
        )

      {"deny", :hive, {:since, at}} ->
        rich_gettext("%{host} is already denied for the hive, since %{at}.", host: host, at: at)

      {"deny", :hive, nil} ->
        rich_gettext("%{host} is already denied for the hive.", host: host)

      {"deny", :target, {:by, by, at}} ->
        rich_gettext("%{host} is already denied for this target, by %{by} on %{at}.",
          host: host,
          by: by,
          at: at
        )

      {"deny", :target, {:since, at}} ->
        rich_gettext("%{host} is already denied for this target, since %{at}.",
          host: host,
          at: at
        )

      {"deny", :target, nil} ->
        rich_gettext("%{host} is already denied for this target.", host: host)
    end
  end

  # The opposite rule: the one there and the one that replaces it.
  defp replaces("allow", :hive, host),
    do:
      rich_gettext("%{host} is allowed for the hive. Adding this deny replaces that rule.",
        host: host
      )

  defp replaces("allow", :target, host),
    do:
      rich_gettext("%{host} is allowed for this target. Adding this deny replaces that rule.",
        host: host
      )

  defp replaces("deny", :hive, host),
    do:
      rich_gettext("%{host} is denied for the hive. Adding this allow replaces that rule.",
        host: host
      )

  defp replaces("deny", :target, host),
    do:
      rich_gettext("%{host} is denied for this target. Adding this allow replaces that rule.",
        host: host
      )

  defp held(:hive, host, paths),
    do:
      rich_gettext(
        "%{host} is held to %{paths} for the hive. Name the paths it should have, or choose Every path to open them all.",
        host: host,
        paths: paths
      )

  defp held(:target, host, paths),
    do:
      rich_gettext(
        "%{host} is held to %{paths} for this target. Name the paths it should have, or choose Every path to open them all.",
        host: host,
        paths: paths
      )

  defp change_paths(:hive, host, from, to),
    do:
      rich_gettext(
        "%{host} is allowed for the hive on %{paths}. Saving changes its paths to %{new_paths}.",
        host: host,
        paths: from,
        new_paths: to
      )

  defp change_paths(:target, host, from, to),
    do:
      rich_gettext(
        "%{host} is allowed for this target on %{paths}. Saving changes its paths to %{new_paths}.",
        host: host,
        paths: from,
        new_paths: to
      )

  defp reads_as("allow", host, paths, _context) do
    case paths do
      [] ->
        rich_gettext("Reads as: %{rule}, on every path.", rule: {:b, subject("allow", host)}) ++
          not_itself(host)

      paths ->
        rich_gettext(
          "Reads as: %{rule}: %{paths}. Behind a wall the proxy reads requests to this host to check the path.",
          rule: {:b, allow_on_paths(host, length(paths))},
          paths: describe_paths(paths)
        )
    end
  end

  defp reads_as("deny", host, _paths, context) do
    rule = {:b, subject("deny", host)}

    lead =
      case {Grammar.wildcard?(host), context.scope} do
        {true, _scope} ->
          rich_gettext("Reads as: %{rule}, and every allow rule it covers.", rule: rule)

        {false, :hive} ->
          rich_gettext(
            "Reads as: %{rule}. It takes the host out of what the hive allows; a target can still allow it unless you lock this rule.",
            rule: rule
          )

        {false, :target} ->
          rich_gettext(
            "Reads as: %{rule}. It takes the host out of what this target is allowed; other targets are not touched.",
            rule: rule
          )
      end

    lead ++
      [" ", gettext("It is denied in either mode, observe too.")] ++ under_suffix(host, context)
  end

  # A deny below an allowed `*.` suffix stands beside it: the runner decides deny first.
  defp under_suffix(host, context) do
    case allowed_suffix_above(host, context) do
      nil ->
        []

      suffix ->
        [
          " "
          | rich_gettext("%{suffix} still allows the other hosts below it.",
              suffix: {:code, suffix.host}
            )
        ]
    end
  end

  defp subject("allow", "*." <> suffix),
    do: rich_gettext("allow every host below %{suffix}", suffix: {:m, suffix})

  defp subject("allow", host), do: rich_gettext("allow %{host}", host: {:m, host})

  defp subject("deny", "*." <> suffix),
    do: rich_gettext("deny every host below %{suffix}", suffix: {:m, suffix})

  defp subject("deny", host), do: rich_gettext("deny %{host}", host: {:m, host})

  defp allow_on_paths("*." <> suffix, n),
    do:
      rich_ngettext(
        "allow every host below %{suffix} on %{count} path",
        "allow every host below %{suffix} on %{count} paths",
        n,
        suffix: {:m, suffix}
      )

  defp allow_on_paths(host, n),
    do:
      rich_ngettext("allow %{host} on %{count} path", "allow %{host} on %{count} paths", n,
        host: {:m, host}
      )

  defp not_itself("*." <> suffix),
    do: [" " | rich_gettext("It does not allow %{suffix} itself.", suffix: {:m, suffix})]

  defp not_itself(_host), do: []

  defp describe_paths(paths) do
    paths
    |> Enum.map(fn path ->
      if String.ends_with?(path, "*"),
        do: rich_gettext("everything below %{path}", path: {:m, String.trim_trailing(path, "*")}),
        else: rich_gettext("%{path} exactly", path: {:m, path})
    end)
    |> join_and()
  end

  defp join_and([one]), do: one

  defp join_and(many) do
    {init, [last]} = Enum.split(many, -1)
    rich_gettext("%{list}, and %{last}", list: Enum.intersperse(init, ", "), last: last)
  end

  defp path_words(nil), do: [gettext("every path")]
  defp path_words([]), do: [gettext("no path")]
  defp path_words(paths), do: path_chips(paths)

  defp path_chips(paths), do: paths |> Enum.map(&{:code, &1}) |> Enum.intersperse(" ")

  ## Refusals (pf4)

  # The allowed `*.` suffix a deny of `host` would sit under, in the scope's policy.
  defp allowed_suffix_above(host, context) do
    Enum.find_value(context.entries, fn entry ->
      if entry.kind == :host and entry.action == :allow and entry.in_force and
           Grammar.wildcard?(entry.host) and entry.host != host and
           Grammar.covers?(entry.host, host),
         do: entry
    end)
  end

  # On a target page: the locked rule of the hive that decides the host whatever is
  # added here. A locked deny holds against an allow below it, a locked allow against a
  # deny below it.
  defp locked_above(_action, _host, %{scope: :hive}), do: nil

  defp locked_above(action, host, context) do
    Enum.find(context.entries, fn entry ->
      entry.kind == :host and entry.source == :hive and entry.locked and
        (entry.host == host or
           (action == "allow" and entry.action == :deny and Grammar.covers?(entry.host, host)) or
           (action == "deny" and entry.action == :allow and Grammar.covers?(entry.host, host)))
    end)
  end

  defp locked_refusal(entry, action, context) do
    lead =
      if entry.action == :deny,
        do: rich_gettext("A locked hive rule denies %{host}.", host: {:code, entry.host}),
        else: rich_gettext("A locked hive rule allows %{host}.", host: {:code, entry.host})

    holds =
      case {entry.action, action} do
        {:deny, _} ->
          gettext(
            "It holds against every target, so no rule added here would change what happens."
          )

        {:allow, "deny"} ->
          gettext("It holds against every target, so a deny added here would change nothing.")

        {:allow, _} ->
          gettext("It holds against every target, so a rule added here would change nothing.")
      end

    who =
      case context[:locked_by] && context.locked_by[entry.host] do
        %{by: by, at: at} when is_binary(by) ->
          [" ", gettext("Locked by %{by} on %{at}.", by: by, at: at)]

        _ ->
          []
      end

    last =
      if context.owner,
        do: gettext("You can change or unlock it on the hive's policy page."),
        else: gettext("Only an owner can change or unlock it.")

    refusal(
      lead ++ [" ", holds] ++ who ++ [" ", last],
      [{gettext("Show the locked rule"), "open_hive_rule", %{"host" => entry.host}}]
    )
  end

  # The allowed `*.` suffix that already covers an allow of `host`.
  defp covering_allow(host, context) do
    Enum.find_value(context.entries, fn entry ->
      if entry.kind == :host and entry.action == :allow and entry.in_force and
           is_nil(entry.paths) and Grammar.wildcard?(entry.host) and entry.host != host and
           Grammar.covers?(entry.host, host),
         do: entry.host
    end)
  end

  ## Words

  defp by(%{by: by, at: at}) when is_binary(by) and is_binary(at), do: {:by, by, at}
  defp by(%{at: at}) when is_binary(at), do: {:since, at}
  defp by(_rule), do: nil

  defp refusal(text, acts), do: reading(:refusal, text, acts: acts, invalid: [:host])

  defp reading(kind, text, opts \\ []) do
    %{
      kind: kind,
      text: text,
      fix: opts[:fix],
      acts: opts[:acts] || [],
      invalid: opts[:invalid] || [],
      button: opts[:button]
    }
  end
end
