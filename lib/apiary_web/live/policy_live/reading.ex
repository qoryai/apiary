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
      `{:code, chip text}`, rendered by `PolicyComponents.rich/1` (always escaped);
    * `fix`: `nil` or `{label, event, values}`, the repair offered as a link;
    * `acts`: more links of the same shape, under a refusal;
    * `invalid`: the fields that take `aria-invalid`;
    * `button`: nil, or the word the submit button takes ("Replace with deny").
  """

  alias Apiary.Policy.Grammar

  @hint [
    "A host name in lower case, or ",
    {:code, "*."},
    " and a suffix for every host below it. No scheme, no port. Paths go in their own field, separated by spaces."
  ]

  @doc "The reading of an empty composer: what a rule is, before anything is typed."
  def hint, do: reading(:hint, @hint)

  @doc """
  Reads a host rule.

  `form` has string keys `"action"`, `"host"`, `"paths"` and `"every"` (`"true"` when every
  path was asked for in so many words). `context`:

    * `scope`: `:hive` or `:repository`;
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
        reading(:hint, @hint)

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
            "A name is 1 to 64 lower-case letters, digits, dots, dashes or underscores, and starts with a letter or digit."
          ],
          invalid: [:name]
        )

      argument != "" and not Grammar.argument?(argument) ->
        reading(:error, ["An argument is at most 256 characters."], invalid: [:argument])

      existing = Enum.find(own, &(&1.kind == "credential" and &1.name == name)) ->
        if (existing.argument || "") == argument and existing.action == "allow" do
          reading(:error, [{:m, name}, " is already named here."], invalid: [:name])
        else
          reading(:note, [{:m, name}, " is named here already. Adding it replaces its argument."],
            button: "Replace credential"
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
          [
            {:code, "*."},
            " may only lead a host: ",
            {:m, "*.example"},
            " matches every host below ",
            {:m, "example"},
            "." | path_too
          ],
          invalid: invalid
        )

      address?(host) ->
        reading(
          :error,
          [
            "An address is written like a host, digits and dots only: ",
            {:m, "10.0.0.12"},
            ". The wall refuses the machine's own address whatever the policy says." | path_too
          ],
          invalid: invalid
        )

      Regex.match?(~r/\A[a-z0-9._-]+\z/, host) ->
        reading(
          :error,
          [
            "Each part of a host is 1 to 63 letters, digits or dashes, and does not start or end with a dash."
            | path_too
          ],
          invalid: invalid
        )

      true ->
        reading(
          :error,
          [
            "A rule names a host and nothing else: lower case, no scheme, no port, no path."
            | path_too
          ],
          invalid: invalid,
          fix: repair(host)
        )
    end
  end

  defp bad_path do
    [
      "A path starts with / and may end in one *; no other wildcard and no query, such as ",
      {:m, "/v1/*"},
      "."
    ]
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
          label = if path, do: "Use #{host} with the path #{path}", else: "Use #{host}"
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
        refusal(["Only an owner can lock, unlock or change a locked rule."], [])

      locked = locked_above(action, host, context) ->
        locked_refusal(locked, action, context)

      existing && existing.action == action && same_paths?(existing.paths, paths, every) ->
        reading(
          :error,
          [
            {:m, host},
            " is already #{past(action)} #{for_scope(context.scope)}",
            by(existing),
            "."
          ],
          invalid: [:host],
          fix: {"Show it", "show_rule", %{"host" => host}}
        )

      existing && existing.action != action ->
        reading(
          :note,
          [
            {:m, host},
            " is #{past(existing.action)} #{for_scope(context.scope)}. Adding this #{action} replaces that rule."
          ],
          button: "Replace with #{action}"
        )

      existing && is_list(existing.paths) && paths == [] && !every ->
        reading(
          :error,
          [
            {:m, host},
            " is held to ",
            path_chips(existing.paths),
            " #{for_scope(context.scope)}. Name the paths it should have, or choose Every path to open them all."
          ],
          invalid: [:paths],
          fix: {"Every path", "composer_every", %{}}
        )

      existing ->
        reading(
          :note,
          [
            {:m, host},
            " is allowed #{for_scope(context.scope)} on ",
            path_words(existing.paths),
            ". Saving changes its paths to ",
            path_words(if(paths == [], do: nil, else: paths)),
            "."
          ],
          button: "Change paths"
        )

      cover = action == "allow" && covering_allow(host, context) ->
        reading(:note, [
          "Already allowed by ",
          {:code, cover},
          ". Adding it changes nothing today and keeps the host allowed if the suffix rule is removed."
        ])

      true ->
        reading(:ok, reads_as(action, host, paths, context))
    end
  end

  defp same_paths?(nil, [], _every), do: true
  defp same_paths?(nil, _paths, _every), do: false
  defp same_paths?(_held, [], true), do: false
  defp same_paths?(held, paths, _every), do: Enum.sort(held) == Enum.sort(paths)

  defp reads_as("allow", host, paths, _context) do
    subject = subject("allow", host)

    case paths do
      [] ->
        ["Reads as: ", {:b, subject}, ", on every path." | not_itself("allow", host)]

      paths ->
        [
          "Reads as: ",
          {:b, subject ++ [" on #{count(length(paths), "path")}"]},
          ": ",
          describe_paths(paths),
          ". Behind a wall the proxy reads requests to this host to check the path."
        ]
    end
  end

  defp reads_as("deny", host, _paths, context) do
    lead =
      case {Grammar.wildcard?(host), context.scope} do
        {true, _scope} ->
          ["Reads as: ", {:b, subject("deny", host)}, ", and every allow rule it covers."]

        {false, :hive} ->
          [
            "Reads as: ",
            {:b, subject("deny", host)},
            ". It takes the host out of what the hive allows; a repository can still allow it unless you lock this rule."
          ]

        {false, :repository} ->
          [
            "Reads as: ",
            {:b, subject("deny", host)},
            ". It takes the host out of what this repository is allowed; other repositories are not touched."
          ]
      end

    lead ++ [" It is denied in either mode, observe too."] ++ under_suffix(host, context)
  end

  # A deny below an allowed `*.` suffix stands beside it: the runner decides deny first.
  defp under_suffix(host, context) do
    case allowed_suffix_above(host, context) do
      nil -> []
      suffix -> [" ", {:code, suffix.host}, " still allows the other hosts below it."]
    end
  end

  defp subject(action, "*." <> suffix), do: ["#{action} every host below ", {:m, suffix}]
  defp subject(action, host), do: ["#{action} ", {:m, host}]

  defp not_itself(action, "*." <> suffix),
    do: [" It does not #{action} ", {:m, suffix}, " itself."]

  defp not_itself(_action, _host), do: []

  defp describe_paths(paths) do
    paths
    |> Enum.map(fn path ->
      if String.ends_with?(path, "*"),
        do: ["everything below ", {:m, String.trim_trailing(path, "*")}],
        else: [{:m, path}, " exactly"]
    end)
    |> join_and()
  end

  defp join_and([one]), do: one
  defp join_and(many), do: Enum.intersperse(many, ", ") |> List.insert_at(-2, "and ")

  defp path_words(nil), do: ["every path"]
  defp path_words([]), do: ["no path"]
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

  # On a repository page: the locked rule of the hive that decides the host whatever is
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
    holds =
      case {entry.action, action} do
        {:deny, _} -> "so no rule added here would change what happens."
        {:allow, "deny"} -> "so a deny added here would change nothing."
        {:allow, _} -> "so a rule added here would change nothing."
      end

    who =
      case context[:locked_by] && context.locked_by[entry.host] do
        %{by: by, at: at} when is_binary(by) -> " Locked by #{by} on #{at}."
        _ -> ""
      end

    last =
      if context.owner,
        do: " You can change or unlock it on the hive's policy page.",
        else: " Only an owner can change or unlock it."

    refusal(
      [
        "A locked hive rule #{if entry.action == :deny, do: "denies", else: "allows"} ",
        {:code, entry.host},
        ". It holds against every repository, #{holds}#{who}#{last}"
      ],
      [{"Show the locked rule", "open_hive_rule", %{"host" => entry.host}}]
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

  defp past("allow"), do: "allowed"
  defp past("deny"), do: "denied"

  defp for_scope(:hive), do: "for the hive"
  defp for_scope(:repository), do: "for this repository"

  defp by(%{by: by, at: at}) when is_binary(by) and is_binary(at), do: ", by #{by} on #{at}"
  defp by(%{at: at}) when is_binary(at), do: ", since #{at}"
  defp by(_rule), do: ""

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

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
