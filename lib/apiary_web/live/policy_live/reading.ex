defmodule ApiaryWeb.PolicyLive.Reading do
  @moduledoc """
  The reading of a host rule, on the New rule and Edit rule pages
  (`ApiaryWeb.PolicyComponents.rule_form/1`) and in the line of the composer kept for
  callers that have not moved (`ApiaryWeb.PolicyComponents.rule_composer/1`): a rule is
  read back in plain words before it is saved, and what cannot be said is refused in a
  sentence that names the reason and the ways out.

  Pure: the form and the rules already on the page in, a reading out. No query runs per
  keystroke. The domain checks everything again at the write; this is where a person finds
  out what `*.` means before saving, not where the policy is enforced.

  A reading is `%{kind:, text:, fix:, acts:, invalid:, button:, errors:, preview:}`:

    * `kind`: `:hint`, `:ok`, `:note`, `:error` or `:refusal`; a rule is saved on `:ok`
      and `:note`;
    * `text`: rich text, a list of binaries, `{:b, rich}`, `{:m, mono text}` and
      `{:code, chip text}`, rendered by `ApiaryWeb.RichText.rich/1` (always escaped);
    * `fix`: `nil` or `{label, event, values}`, the repair offered as a link;
    * `acts`: more links of the same shape, under a refusal;
    * `invalid`: the fields that take `aria-invalid`;
    * `button`: nil, or the word the submit button takes ("Replace with deny");
    * `errors`: what the form says under its fields, `[{field, text, fix}]` in the
      fields' order, `field` being `:host` or `:paths`;
    * `preview`: what the form's "What this rule does" says, `{kind, text}` with `kind`
      `:idle`, `:ok` or `:note`; nil under a refusal, which the form shows in its place.

  The line of the composer shows `text`, `fix` and `acts`; the form shows `errors`,
  `preview` and, for a refusal, `text` and `acts`.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText

  alias Apiary.Policy.Grammar
  alias ApiaryWeb.Format

  @doc "The reading of an empty form: what a rule is, before anything is typed."
  def hint, do: reading(:hint, host_hint(), preview: {:idle, type_a_host()})

  @doc """
  The reading of a form sent with no host: the error under Host. Never disabled, the form's
  button says what is missing once it is pressed.
  """
  def empty_host do
    text = rich_gettext("Enter a host, such as %{example}.", example: {:m, "api.example.com"})

    reading(:error, text,
      invalid: [:host],
      errors: [{:host, text, nil}],
      preview: {:idle, type_a_host()}
    )
  end

  @doc "The help under the form's Host field."
  def host_hint do
    rich_gettext(
      "The name runs connect to, in lower case, without %{scheme} or a port. Start it with %{suffix} to cover every host below a domain, such as %{example}.",
      scheme: {:m, "https://"},
      suffix: {:code, "*."},
      example: {:m, "*.example.com"}
    )
  end

  @doc "The help under the form's Paths field."
  def paths_hint do
    rich_gettext(
      "Leave it empty to allow every path. Separate paths with spaces; end one with %{star} for everything below it, such as %{example}.",
      star: {:code, "*"},
      example: {:m, "/v1/*"}
    )
  end

  defp type_a_host, do: [gettext("Type a host to see the rule in plain words before you add it.")]

  @doc """
  Reads a host rule.

  `form` has string keys `"action"`, `"host"`, `"paths"` and `"every"` (`"true"` when every
  path was asked for in so many words). `context`:

    * `scope`: `:workspace`, `:target`, or `:organisation` for a level above the
      workspace, whose rules hold in every workspace;
    * `own`: the rules of the scope being edited, maps or structs with `kind`, `action`,
      `host`, `paths`, `locked`, and `by`, `at` when the page knows them;
    * `entries`: the entries of the effective policy (`Apiary.Policy.Entry`);
    * `owner`: whether the reader may change a locked rule;
    * `locked_by`: `%{host => %{by:, at:}}`, who locked what, when the page knows;
    * `who_locks`: the edition's sentence of who may change a locked rule
      (`c:ApiaryWeb.Edition.who_may_sentence/2` with `:"security_policy.lock"`), said in
      place of the core's to a reader who may not, or nil for the core's;
    * `editing`: true on the Edit rule page, where the same rule again has nothing to save.
  """
  def host_rule(form, context) do
    action = if form["action"] == "deny", do: "deny", else: "allow"
    host = String.trim(form["host"] || "")
    every = form["every"] == "true"
    paths = if action == "deny", do: [], else: split(form["paths"])

    cond do
      host == "" ->
        hint()

      not Grammar.host?(host) ->
        bad_host(host, paths)

      Enum.any?(paths, &(not Grammar.path?(&1))) ->
        reading(:error, bad_path(),
          invalid: [:paths],
          errors: [{:paths, bad_path(), nil}],
          preview: {:idle, fix_the_paths()}
        )

      true ->
        said(action, host, paths, every, context)
    end
  end

  @doc "The paths of a text field: separated by spaces, commas or lines."
  def split(nil), do: []
  def split(text), do: text |> String.split(~r/[\s,]+/u, trim: true) |> Enum.uniq()

  ## Not in the grammar

  # The host's sentence, and the paths' after it where they are wrong too: one line in the
  # composer, each under its own field on the form.
  defp bad_host(host, paths) do
    path_bad? = Enum.any?(paths, &(not Grammar.path?(&1)))
    {text, fix} = host_error(host)

    reading(:error, text ++ if(path_bad?, do: [" " | bad_path()], else: []),
      invalid: if(path_bad?, do: [:host, :paths], else: [:host]),
      fix: fix,
      errors: [{:host, text, fix}] ++ if(path_bad?, do: [{:paths, bad_path(), nil}], else: []),
      preview: {:idle, [gettext("Fix the host to see the rule in plain words.")]}
    )
  end

  defp host_error(host) do
    rest = String.replace_prefix(host, "*.", "")

    cond do
      String.contains?(rest, "*") ->
        {rich_gettext(
           "%{suffix} may only lead a host: %{example} matches every host below %{domain}.",
           suffix: {:code, "*."},
           example: {:m, "*.example"},
           domain: {:m, "example"}
         ), nil}

      address?(host) ->
        {rich_gettext(
           "An address is written like a host, digits and dots only: %{address}. The wall refuses link-local addresses and the machine's addresses whatever the policy says.",
           address: {:m, "10.0.0.12"}
         ), nil}

      # An address takes no `*.`: there is nothing below it.
      String.starts_with?(host, "*.") and Grammar.ends_in_number?(String.downcase(rest)) ->
        {rich_gettext("%{suffix} leads a host name, never an address.", suffix: {:code, "*."}),
         nil}

      # An address in a form other than `a.b.c.d`, which the gateway refuses.
      Grammar.ends_in_number?(String.downcase(host)) ->
        {rich_gettext(
           "An address is four numbers from 0 to 255 with dots between them and no leading zeros, such as %{address}.",
           address: {:m, "10.0.0.12"}
         ), nil}

      Regex.match?(~r/\A[a-z0-9._-]+\z/, host) ->
        {[
           gettext(
             "Each part of a host is 1 to 63 letters, digits or dashes, and does not start or end with a dash."
           )
         ], nil}

      true ->
        {[
           gettext(
             "A rule names a host and nothing else: lower case, no scheme, no port, no path."
           )
         ], repair(host)}
    end
  end

  defp fix_the_paths, do: [gettext("Fix the paths to see the rule in plain words.")]

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

          {label, "rule_use", %{"host" => host, "paths" => path || ""}}
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
        refusal(
          [
            context[:who_locks] ||
              gettext("Only an owner can lock, unlock or change a locked rule.")
          ],
          []
        )

      locked = locked_above(action, host, context) ->
        locked_refusal(locked, action, context)

      existing && existing.action == action && same_paths?(existing.paths, paths, every) &&
          context[:editing] ->
        nothing = [gettext("Nothing to save: the rule is as it was.")]
        reading(:error, nothing, preview: {:idle, nothing})

      existing && existing.action == action && same_paths?(existing.paths, paths, every) ->
        text = already(action, context.scope, {:m, host}, existing)
        fix = {gettext("Show it"), "show_rule", %{"host" => host}}

        reading(:error, text,
          invalid: [:host],
          fix: fix,
          errors: [{:host, text, fix}],
          preview:
            {:idle,
             [
               gettext(
                 "Nothing new: this rule is already in the list. To change its paths, edit it from its row."
               )
             ]}
        )

      existing && existing.action != action ->
        note(replaces(existing.action, context.scope, {:m, host}),
          button:
            if(action == "deny",
              do: gettext("Replace with deny"),
              else: gettext("Replace with allow")
            )
        )

      existing && is_list(existing.paths) && paths == [] && !every ->
        text = held(context.scope, {:m, host}, path_chips(existing.paths))
        fix = {gettext("Every path"), "rule_every", %{}}

        reading(:error, text,
          invalid: [:paths],
          fix: fix,
          errors: [{:paths, text, fix}],
          preview: {:idle, fix_the_paths()}
        )

      existing ->
        note(
          change_paths(
            context.scope,
            {:m, host},
            path_words(existing.paths),
            path_words(if(paths == [], do: nil, else: paths))
          ),
          button: gettext("Change paths")
        )

      over = context.scope == :target && workspace_opposite(action, host, context) ->
        note(overrides(over.action, {:m, host}))

      cover = action == "allow" && covering_allow(host, context) ->
        note(
          rich_gettext(
            "Already allowed by %{suffix}. Adding it changes nothing today and keeps the host allowed if the suffix rule is removed.",
            suffix: {:code, cover}
          )
        )

      true ->
        text = reads_as(action, host, paths, context)
        reading(:ok, text, preview: {:ok, text})
    end
  end

  # A note is said in the form's preview, and saves as the button says.
  defp note(text, opts \\ []),
    do: reading(:note, text, Keyword.put(opts, :preview, {:note, text}))

  defp same_paths?(nil, [], _every), do: true
  defp same_paths?(nil, _paths, _every), do: false
  defp same_paths?(_held, [], true), do: false
  defp same_paths?(held, paths, _every), do: Enum.sort(held) == Enum.sort(paths)

  # The same rule again: each action, scope and author is its own sentence.
  defp already(action, scope, host, existing) do
    case {action, scope, by(existing)} do
      {"allow", :workspace, {:by, by, at}} ->
        rich_gettext("%{host} is already allowed for the workspace, by %{by} on %{at}.",
          host: host,
          by: by,
          at: at
        )

      {"allow", :workspace, {:since, at}} ->
        rich_gettext("%{host} is already allowed for the workspace, since %{at}.",
          host: host,
          at: at
        )

      {"allow", :workspace, nil} ->
        rich_gettext("%{host} is already allowed for the workspace.", host: host)

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

      {"deny", :workspace, {:by, by, at}} ->
        rich_gettext("%{host} is already denied for the workspace, by %{by} on %{at}.",
          host: host,
          by: by,
          at: at
        )

      {"deny", :workspace, {:since, at}} ->
        rich_gettext("%{host} is already denied for the workspace, since %{at}.",
          host: host,
          at: at
        )

      {"deny", :workspace, nil} ->
        rich_gettext("%{host} is already denied for the workspace.", host: host)

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

      {"allow", :organisation, {:by, by, at}} ->
        rich_gettext("%{host} is already allowed for every workspace, by %{by} on %{at}.",
          host: host,
          by: by,
          at: at
        )

      {"allow", :organisation, {:since, at}} ->
        rich_gettext("%{host} is already allowed for every workspace, since %{at}.",
          host: host,
          at: at
        )

      {"allow", :organisation, nil} ->
        rich_gettext("%{host} is already allowed for every workspace.", host: host)

      {"deny", :organisation, {:by, by, at}} ->
        rich_gettext("%{host} is already denied for every workspace, by %{by} on %{at}.",
          host: host,
          by: by,
          at: at
        )

      {"deny", :organisation, {:since, at}} ->
        rich_gettext("%{host} is already denied for every workspace, since %{at}.",
          host: host,
          at: at
        )

      {"deny", :organisation, nil} ->
        rich_gettext("%{host} is already denied for every workspace.", host: host)
    end
  end

  # The opposite rule: the one there and the one that replaces it.
  defp replaces("allow", :workspace, host),
    do:
      rich_gettext("%{host} is allowed for the workspace. Adding this deny replaces that rule.",
        host: host
      )

  defp replaces("allow", :target, host),
    do:
      rich_gettext("%{host} is allowed for this target. Adding this deny replaces that rule.",
        host: host
      )

  defp replaces("deny", :workspace, host),
    do:
      rich_gettext("%{host} is denied for the workspace. Adding this allow replaces that rule.",
        host: host
      )

  defp replaces("deny", :target, host),
    do:
      rich_gettext("%{host} is denied for this target. Adding this allow replaces that rule.",
        host: host
      )

  defp replaces("allow", :organisation, host),
    do:
      rich_gettext(
        "%{host} is allowed for every workspace. Adding this deny replaces that rule.",
        host: host
      )

  defp replaces("deny", :organisation, host),
    do:
      rich_gettext(
        "%{host} is denied for every workspace. Adding this allow replaces that rule.",
        host: host
      )

  defp held(:workspace, host, paths),
    do:
      rich_gettext(
        "%{host} is held to %{paths} for the workspace. Name the paths it should have, or choose Every path to open them all.",
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

  defp held(:organisation, host, paths),
    do:
      rich_gettext(
        "%{host} is held to %{paths} for every workspace. Name the paths it should have, or choose Every path to open them all.",
        host: host,
        paths: paths
      )

  defp change_paths(:workspace, host, from, to),
    do:
      rich_gettext(
        "%{host} is allowed for the workspace on %{paths}. Saving changes its paths to %{new_paths}.",
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

  defp change_paths(:organisation, host, from, to),
    do:
      rich_gettext(
        "%{host} is allowed for every workspace on %{paths}. Saving changes its paths to %{new_paths}.",
        host: host,
        paths: from,
        new_paths: to
      )

  defp reads_as("allow", host, paths, _context) do
    case paths do
      [] ->
        rich_gettext("%{rule}, on every path.", rule: {:b, subject("allow", host)}) ++
          not_itself(host)

      paths ->
        rich_gettext(
          "%{rule}: %{paths}. Behind a wall the proxy reads requests to this host to check the path.",
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
          rich_gettext("%{rule}, and every allow rule it covers.", rule: rule)

        {false, :workspace} ->
          rich_gettext(
            "%{rule}. It takes the host out of what the workspace allows; a target can still allow it unless you lock this rule.",
            rule: rule
          )

        {false, :target} ->
          rich_gettext(
            "%{rule}. It takes the host out of what this target is allowed; other targets are not touched.",
            rule: rule
          )

        {false, :organisation} ->
          rich_gettext(
            "%{rule}. It holds in every workspace and target, and no rule of theirs can allow it.",
            rule: rule
          )
      end

    lead ++
      [" ", gettext("It is denied in either mode, observe too.")] ++ under_suffix(host, context)
  end

  # A deny below an allowed `*.` suffix stands beside it: the gateway decides deny first.
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
    do: rich_gettext("Allow every host below %{suffix}", suffix: {:m, suffix})

  defp subject("allow", host), do: rich_gettext("Allow %{host}", host: {:m, host})

  defp subject("deny", "*." <> suffix),
    do: rich_gettext("Deny every host below %{suffix}", suffix: {:m, suffix})

  defp subject("deny", host), do: rich_gettext("Deny %{host}", host: {:m, host})

  defp allow_on_paths("*." <> suffix, n),
    do:
      rich_ngettext(
        "Allow every host below %{suffix} on %{number} path",
        "Allow every host below %{suffix} on %{number} paths",
        n,
        suffix: {:m, suffix},
        number: Format.number(n)
      )

  defp allow_on_paths(host, n),
    do:
      rich_ngettext("Allow %{host} on %{number} path", "Allow %{host} on %{number} paths", n,
        host: {:m, host},
        number: Format.number(n)
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

  ## Refusals

  # The allowed `*.` suffix a deny of `host` would sit under, in the scope's policy.
  defp allowed_suffix_above(host, context) do
    Enum.find_value(context.entries, fn entry ->
      if entry.kind == :host and entry.action == :allow and entry.in_force and
           Grammar.wildcard?(entry.host) and entry.host != host and
           Grammar.covers?(entry.host, host),
         do: entry
    end)
  end

  # On a target page: the locked rule of the workspace that decides the host whatever is
  # added here. A locked deny holds against an allow below it, a locked allow against a
  # deny below it.
  # The workspace's rule for the same host with the other action, which this one would
  # override for the target; a locked one is `locked_above/3`'s, read first.
  defp workspace_opposite(action, host, context) do
    Enum.find(context.entries, fn entry ->
      entry.kind == :host and entry.source == :workspace and not entry.locked and
        entry.host == host and to_string(entry.action) != action
    end)
  end

  defp overrides(:deny, host),
    do:
      rich_gettext(
        "%{host} is denied for the workspace. This rule allows it for this target; other targets keep the deny.",
        host: host
      )

  defp overrides(:allow, host),
    do:
      rich_gettext(
        "%{host} is allowed for the workspace. This rule denies it for this target; other targets keep it.",
        host: host
      )

  defp locked_above(_action, _host, %{scope: scope}) when scope in [:workspace, :organisation],
    do: nil

  defp locked_above(action, host, context) do
    Enum.find(context.entries, fn entry ->
      entry.kind == :host and entry.source == :workspace and entry.locked and
        (entry.host == host or
           (action == "allow" and entry.action == :deny and Grammar.covers?(entry.host, host)) or
           (action == "deny" and entry.action == :allow and Grammar.covers?(entry.host, host)))
    end)
  end

  defp locked_refusal(entry, action, context) do
    lead =
      if entry.action == :deny,
        do: rich_gettext("A locked workspace rule denies %{host}.", host: {:code, entry.host}),
        else: rich_gettext("A locked workspace rule allows %{host}.", host: {:code, entry.host})

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
        do: gettext("You can change or unlock it on the workspace's policy page."),
        else: context[:who_locks] || gettext("Only an owner can change or unlock it.")

    refusal(
      lead ++ [" ", holds] ++ who ++ [" ", last],
      [{gettext("Show the locked rule"), "open_workspace_rule", %{"host" => entry.host}}]
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

  defp reading(kind, text, opts) do
    %{
      kind: kind,
      text: text,
      fix: opts[:fix],
      acts: opts[:acts] || [],
      invalid: opts[:invalid] || [],
      button: opts[:button],
      errors: opts[:errors] || [],
      preview: opts[:preview]
    }
  end
end
