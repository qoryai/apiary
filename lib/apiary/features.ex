defmodule Apiary.Features do
  @moduledoc """
  What this instance offers: its **features**, switched when the instance is launched.

  | Feature | Covers | Needs |
  |---|---|---|
  | `observability` | runs, the terminal log, the session timeline, the connections, retention | nothing |
  | `security` | the security policy and the run configuration served to the gateway | `observability` |
  | `secrets` | the stored secrets, the variables and the integrations of a workspace; opt-in | `security` |

  An edition adds more features after the core's (`c:Apiary.Edition.features/0`), each
  with the features it needs, whether it is built, whether it is opt-in, and its parts.
  The list is read once, checked (`registry/1`), and kept for the life of the node: a
  name listed twice, or a feature that needs one the list does not have, stops the boot.

  A **part** is a named piece of the console that an edition may hide from a person apart
  from the rest (`parts/0`). A part of a feature is named `:"<feature>.<part>"`: the core's
  one is the run's Terminal, `:"observability.terminal"`, the run's log, which
  `run.read_log` reads (`Apiary.Access`). A part may belong to no feature: the core's one
  is `:nodes`, the nodes, the node pools, their access keys and the gateways, to which the
  `node.*` and `access_key.*` actions belong. A part is never switched on or off: a part of a
  feature is on with its feature (`feature_of/1`), and a part of none on every instance.

  `QORY_FEATURES` names the features the instance has, of the whole list: `all`; `all-`
  and the features left out, separated by commas (`all-security`); or the features on,
  separated by commas (`observability,security`). Unset or blank is `all`. A list keeps
  off every feature it does not name, one an upgrade adds included; `all` and `all-…`
  take that one on with the upgrade. A feature of another edition is unknown here.
  `instance_mail`, a name the list once took, is accepted and ignored: Instance settings ›
  Mail, which it switched on, is on every instance.
  `config/runtime.exs` keeps the value as it is (a release reads that file before the
  application's modules can be relied on), and `boot!/0` checks it with `parse/1` when
  the application starts: an unknown name or a feature without the features it needs
  stops the boot. The list is fixed while the instance runs.

  An **opt-in** feature, marked `default: false` (`opt_in/0`), is on only where a list
  names it: `all`, `all-…`, unset and blank leave it off, as an upgrade that adds one
  does. Only an opt-in feature may need one, and it is never one a page shows or hides for
  an organisation (`built/0`).

  A feature that is off is absent, not disabled: its pages answer not found, the navigation
  leaves it out, its processes are not started. Every surface asks `on?/1`, or
  `visible?/2` with the scope of the person it serves; the discovery document of the
  server contract reads no feature.

  ## What a person is shown

  Below the instance a feature is shown or hidden, never switched off. What a person is not
  shown in an organisation is the edition's answer (`c:Apiary.Edition.hidden/1`), features
  and parts, as `hidden_of/1` keeps it; the core's answer is nothing. The scope a
  person's page or a context function holds carries it, `hidden`, loaded with it
  (`Apiary.Organisations.resolve_scope/4`) and read again with its membership
  (`Apiary.Access.reload/2`), so `visible?/2` reads nothing. A feature that needs a hidden
  one is hidden with it (`hidden_of/1`). A hidden feature is absent for that person as one
  the instance lacks is: its pages, menu entries and actions are not found. A hidden part
  is absent for that person the same way, and so is every part of a hidden feature: an
  action of the part (`Apiary.Access.Action`, `part`) is not found. Hiding `:nodes` hides
  the nodes' pages and actions from that person while the nodes keep working.
  What is hidden still works in full for everything that does not ask what a person is
  shown, which follows the instance's features alone (`on?/1`): what a node is served (a
  run's registration, events, attach, outcome and reload, and its run configuration),
  rendering, the instance's jobs, retention and the audit trail, and the guides at
  `/docs`, the sign-in and landing pages and the routes' first answer
  (`ApiaryWeb.Features.Routes`).
  """

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope

  # The core's features, in the order the instance lists them, each with the features it
  # needs, whether it is built, `default: false` for one that is opt-in, and `docs: false`
  # for one the documentation does not differ by.
  #
  # `path_rules` is the Paths field of a policy rule's form, opt-in: an instance without it
  # draws the form without its Paths row (`ApiaryWeb.PolicyComponents.rule_form/1`,
  # `paths`), and the rules, their paths and everything else about paths stay as they are.
  # Every instance is served the same documentation with it on or off (`docs: false`): the
  # module reference is served where it is off, so the table above has no row for it and
  # no doc names it.
  @core [
    observability: [needs: [], built: true, parts: [:terminal]],
    security: [needs: [:observability], built: true],
    secrets: [needs: [:security], built: true, default: false],
    path_rules: [needs: [:security], built: true, default: false, docs: false],
    factory: [needs: [:observability, :security], built: true, default: false, docs: false]
  ]

  # The parts that belong to no feature, after the features' parts in `parts/0`: the
  # nodes, the node pools, their access keys and the gateways.
  @featureless [:nodes]

  # Names `QORY_FEATURES` once took, of a feature since built into every instance: a value
  # that still names one is read as if it did not, so the instance boots as before.
  @retired ["instance_mail"]

  # What `registry/1` says an entry is, when it refuses one.
  @entry_shape "a feature is {name, needs: [feature], built: boolean}, " <>
                 "with default: boolean and docs: boolean where they are given " <>
                 "and parts: [atom] where they are, got: "

  @typedoc "A feature: one of `all/0`."
  @type feature :: atom

  @typedoc """
  A part: one of `parts/0`, `:\"<feature>.<part>\"` for a part of a feature, or a part of
  none, `:nodes`.
  """
  @type part :: atom

  @typedoc "A feature or a part of one."
  @type name :: feature | part

  @typedoc "The features of the core and the edition, as `registry/1` checks them."
  @type registry :: %{
          all: [feature],
          needs: %{feature => [feature]},
          built: [feature],
          opt_in: [feature],
          documented: [feature],
          parts: [part],
          part_of: %{part => feature | nil}
        }

  @doc """
  built/0 is the features listed with `built: true` and not opt-in (`opt_in/0`), in the
  order of `all/0`: the ones a page of an edition may show or hide for an organisation.
  Any other keeps whatever an edition says of it.
  """
  @spec built() :: [feature]
  def built, do: registry().built

  @doc """
  opt_in/0 is the features listed with `default: false`, in the order of `all/0`: on only
  where the value of `QORY_FEATURES` lists them by name (`parse/1`), and never offered to
  show or hide for an organisation (`built/0`).
  """
  @spec opt_in() :: [feature]
  def opt_in, do: registry().opt_in

  @doc "Every feature, the core's and then the edition's, in the order the instance lists them."
  @spec all() :: [feature]
  def all, do: registry().all

  @doc """
  documented/0 is the features the documentation at `/docs` differs by, in the order of
  `all/0`: every feature but the ones listed with `docs: false`, which change nothing the
  documentation says. `mix docs` (`Mix.Tasks.Docs.All`) builds its trees over these alone,
  and `ApiaryWeb.DocsController` names and picks a tree by them: an instance is served the
  same tree with a `docs: false` feature on or off.
  """
  @spec documented() :: [feature]
  def documented, do: registry().documented

  @doc false
  # The core's features listed with `docs: false`, read from the list itself rather than
  # the registry, so a module's documentation may leave out what belongs to them as it
  # is compiled (`Apiary.Access`'s tables).
  @spec core_undocumented() :: [feature]
  def core_undocumented,
    do: for({name, opts} <- @core, Keyword.get(opts, :docs, true) == false, do: name)

  @doc """
  parts/0 is every part: the parts of the features, `:"<feature>.<part>"`, in the order of
  `all/0` and, for one feature, in the order its entry lists them; then the parts of no
  feature, `:nodes`.
  """
  @spec parts() :: [part]
  def parts, do: registry().parts

  @doc """
  feature_of/1 is the feature `name` belongs to: the feature of a part (`parts/0`), nil
  for a part of no feature, and a feature itself. Raises `ArgumentError` for a name that
  is neither a feature nor a part.
  """
  @spec feature_of(name) :: feature | nil
  def feature_of(name) do
    %{all: all, part_of: part_of} = registry()

    cond do
      name in all ->
        name

      is_map_key(part_of, name) ->
        Map.fetch!(part_of, name)

      true ->
        raise ArgumentError,
              "#{inspect(name)} is not a feature of Apiary.Features, nor a part of one"
    end
  end

  @doc "The features `feature` needs on. Raises `ArgumentError` for a name that is no feature."
  @spec needs(feature) :: [feature]
  def needs(feature), do: Map.fetch!(registry().needs, known!(feature))

  @doc """
  registry/1 checks a list of features, the core's followed by the edition's, and returns
  what `all/0`, `needs/1`, `built/0`, `opt_in/0`, `documented/0`, `parts/0` and
  `feature_of/1` answer from; raises `ArgumentError` on a mistake: an entry that is not
  `{name, needs: [feature], built: boolean}`, with `default: boolean` where it is given
  (`true` where it is not, `false` for an opt-in feature), `docs: boolean` where it is
  given (`true` where it is not, `false` for a feature the documentation does not differ
  by) and `parts: [atom]` where they are (none where they are not), a name listed twice,
  a part that is not an atom or is listed twice, a feature named as a part of no feature
  (`nodes`), a feature that needs itself or one the list does not have, or a feature that
  is not opt-in and needs one that is. The parts of no feature follow the features' parts.
  """
  @spec registry([{feature, keyword}]) :: registry
  def registry(features) do
    Enum.each(features, &check_entry!/1)
    names = Enum.map(features, &elem(&1, 0))

    case names -- Enum.uniq(names) do
      [] -> :ok
      twice -> raise ArgumentError, "a feature is listed once, got twice: #{names(twice)}"
    end

    for {name, opts} <- features, need <- opts[:needs], need == name or need not in names do
      raise ArgumentError, "the feature #{name} needs #{need}, which is no other feature"
    end

    opt_in = for {name, opts} <- features, opts[:default] == false, do: name

    part_of =
      for {name, opts} <- features,
          part <- Keyword.get(opts, :parts, []),
          do: {part_name(name, part), name}

    part_of = part_of ++ Enum.map(@featureless, &{&1, nil})
    parts = Enum.map(part_of, &elem(&1, 0))

    # A part's name is its feature's name and the part's, or the name of a part of no
    # feature: listed twice, or the name of a feature, it would answer for two things.
    case (parts -- Enum.uniq(parts)) ++ Enum.filter(parts, &(&1 in names)) do
      [] -> :ok
      twice -> raise ArgumentError, "a part is listed once, got twice: #{names(Enum.uniq(twice))}"
    end

    # `all` leaves the opt-in features off, so only another opt-in feature may need one.
    for {name, opts} <- features, name not in opt_in, need <- opts[:needs], need in opt_in do
      raise ArgumentError,
            "the feature #{name} needs #{need}, which is opt-in: so is a feature that needs one"
    end

    %{
      all: names,
      needs: Map.new(features, fn {name, opts} -> {name, opts[:needs]} end),
      built: for({name, opts} <- features, opts[:built], name not in opt_in, do: name),
      opt_in: opt_in,
      documented: for({name, opts} <- features, Keyword.get(opts, :docs, true), do: name),
      parts: parts,
      part_of: Map.new(part_of)
    }
  end

  defp part_name(feature, part), do: :"#{feature}.#{part}"

  defp check_entry!({name, opts} = entry) when is_atom(name) and is_list(opts) do
    needs = opts[:needs]

    parts = Keyword.get(opts, :parts, [])

    unless is_list(needs) and Enum.all?(needs, &is_atom/1) and is_boolean(opts[:built]) and
             is_boolean(Keyword.get(opts, :default, true)) and
             is_boolean(Keyword.get(opts, :docs, true)) and is_list(parts) do
      raise ArgumentError, @entry_shape <> inspect(entry)
    end

    for part <- parts, not is_atom(part) or is_nil(part) or is_boolean(part) do
      raise ArgumentError, "a part of #{name} is an atom, got: #{inspect(part)}"
    end
  end

  defp check_entry!(entry), do: raise(ArgumentError, @entry_shape <> inspect(entry))

  # The core's features and the edition's, checked once and kept for the life of the node.
  defp registry do
    case :persistent_term.get({__MODULE__, :registry}, nil) do
      nil ->
        registry = registry(@core ++ Apiary.Edition.features())
        :persistent_term.put({__MODULE__, :registry}, registry)
        registry

      registry ->
        registry
    end
  end

  # A feature of the list, or an `ArgumentError`: asking of a name that is no feature is a
  # mistake in the caller, never its input.
  defp known!(feature) do
    if feature in registry().all,
      do: feature,
      else: raise(ArgumentError, "#{inspect(feature)} is not a feature of Apiary.Features")
  end

  @doc """
  The features a value of `QORY_FEATURES` names: `{:ok, features}` in the order of `all/0`,
  or `{:error, reason}`.

    * `nil`, an empty or a blank value, and `all`: every feature but the opt-in ones
      (`opt_in/0`).
    * `all-security`: those of `all` but the ones after `all-`, separated by commas.
    * `observability,security`: those features and no other; an opt-in feature is on only
      where a list names it.

  `all` may not be one of the features of a list. Every feature but `observability` needs
  `observability`, whichever form names them. `instance_mail`, a name the list once took,
  is accepted in either list and ignored.
  """
  @spec parse(String.t() | nil) :: {:ok, [feature]} | {:error, String.t()}
  def parse(nil), do: {:ok, all() -- opt_in()}

  def parse(value) when is_binary(value) do
    # What `all` names: every feature but the opt-in ones.
    all = all() -- opt_in()

    case String.trim(value) do
      "" ->
        {:ok, all}

      "all" ->
        {:ok, all}

      "all-" <> left_out ->
        with {:ok, left_out} <- known(terms(left_out)),
             do: check_needs(all -- left_out)

      list ->
        names = terms(list)

        cond do
          # Only commas and blanks: as good as unset.
          names == [""] ->
            {:ok, all}

          Enum.any?(names, &(&1 == "all" or String.starts_with?(&1, "all-"))) ->
            {:error, "all is not a feature to list: all, all-<features>, or the features on"}

          true ->
            with {:ok, listed} <- known(names),
                 do: check_needs(Enum.filter(all(), &(&1 in listed)))
        end
    end
  end

  # The names of a list separated by commas. A list with none names the empty name, so that
  # `all-` alone is refused as naming nothing.
  defp terms(list) do
    case list |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> [""]
      names -> names
    end
  end

  defp known(names) do
    known = Map.new(all(), &{Atom.to_string(&1), &1})
    names = Enum.reject(names, &(&1 in @retired and not Map.has_key?(known, &1)))

    case Enum.reject(names, &Map.has_key?(known, &1)) do
      [] ->
        {:ok, Enum.map(names, &Map.fetch!(known, &1))}

      unknown ->
        # The message does not list the features: an instance shows nothing of a feature
        # it does not have, its boot errors included. The Install guide lists them, but for
        # one the documentation does not differ by (`docs: false`), which no guide names.
        {:error,
         "unknown #{plural(unknown, "feature", "features")} #{names(unknown)}; " <>
           "the Install guide at /docs lists the features"}
    end
  end

  defp check_needs(features) do
    missing =
      for feature <- features, need <- needs(feature), need not in features, do: {feature, need}

    case missing do
      [] ->
        {:ok, features}

      [{feature, need} | _] ->
        {:error, "#{feature} needs #{need}, which is left out"}
    end
  end

  defp names(list), do: Enum.map_join(list, ", ", &name/1)
  defp name(""), do: ~s("")
  defp name(name), do: to_string(name)
  defp plural([_], one, _many), do: one
  defp plural(_, _one, many), do: many

  @doc """
  Reads `QORY_FEATURES` as `config/runtime.exs` left it, checks it and fixes the instance's
  features for the life of the node. Called first thing at boot; raises on a list of
  features `registry/1` refuses, or on a value `parse/1` refuses, so the instance does not
  start.
  """
  @spec boot!() :: [feature]
  def boot! do
    case parse(Application.get_env(:apiary, :features_setting)) do
      {:ok, features} ->
        Application.put_env(:apiary, :features, features)
        features

      {:error, reason} ->
        raise ArgumentError, """
        environment variable QORY_FEATURES is not valid: #{reason}.
        Leave it unset or set it to all for the default features, or name them, for example:
        QORY_FEATURES=observability
        """
    end
  end

  @doc """
  The features this instance has, in the order of `all/0`. Before `boot!/0`, as under
  `bin/apiary eval`, where the application is loaded and not started, the value of
  `QORY_FEATURES` is read here, so a command run beside an instance has its features
  rather than all of them.
  """
  @spec enabled() :: [feature]
  def enabled do
    case Application.fetch_env(:apiary, :features) do
      {:ok, features} -> features
      :error -> boot!()
    end
  end

  @doc """
  Whether `feature` is on for the instance. Raises `ArgumentError` for a name that is no
  feature.
  """
  @spec on?(feature) :: boolean
  def on?(feature), do: known!(feature) in enabled()

  @doc """
  Whether `name`, a feature or a part, is shown where `scope` is: its feature on for the
  instance (`on?/1`), as a part of no feature is on every instance, and, for a person's
  `Apiary.Accounts.Scope`, neither the name nor its feature among what the scope hides
  (`hidden`, the edition's answer, `c:Apiary.Edition.hidden/1`, with the features that
  need a hidden one, as `hidden_of/1` keeps it). An access key, an access key's scope, the
  instance's scope, a scope that carries no `hidden`, as the scope of a job no person
  enqueued, and `nil` answer as the instance. Raises `ArgumentError` for a name that is no
  feature or part.
  """
  @spec visible?(Scope.t() | AccessKey.t() | nil, name) :: boolean
  def visible?(%Scope{access_key: nil, instance: false, hidden: hidden}, name)
      when is_list(hidden) do
    case feature_of(name) do
      nil -> name not in hidden
      feature -> on?(feature) and feature not in hidden and name not in hidden
    end
  end

  def visible?(_scope, name) do
    case feature_of(name) do
      nil -> true
      feature -> on?(feature)
    end
  end

  @doc """
  hidden_of/1 is the edition's answer to `c:Apiary.Edition.hidden/1` as a scope keeps it,
  `hidden`, with the features that depend on a hidden one added: a feature that needs a
  hidden feature, directly or through another (`needs/1`), is hidden too. The features
  come in the order of `all/0`, then the parts in the order of `parts/0`, without a
  feature the instance lacks or a part of one; a part of no feature is kept on every
  instance. Raises `ArgumentError` on a name that is no feature or part: an edition's
  mistake, as `registry/1` treats one.
  """
  @spec hidden_of([name]) :: [name]
  def hidden_of(names) when is_list(names) do
    Enum.each(names, &feature_of/1)
    names = with_dependants(names, registry().needs)
    enabled = enabled()

    Enum.filter(enabled ++ parts(), fn name ->
      name in names and (feature_of(name) in enabled or is_nil(feature_of(name)))
    end)
  end

  # `names` with every feature that needs one of them, directly or through another.
  defp with_dependants(names, needs) do
    dependants =
      for {feature, its} <- needs,
          feature not in names,
          Enum.any?(its, &(&1 in names)),
          do: feature

    if dependants == [], do: names, else: with_dependants(names ++ dependants, needs)
  end

  @doc """
  closed/1 is `features` in the order of `all/0`, without a feature whose needs are not
  among them.
  """
  @spec closed([feature]) :: [feature]
  def closed(features) do
    %{all: all, needs: needs} = registry()

    Enum.filter(all, fn feature ->
      feature in features and Enum.all?(Map.fetch!(needs, feature), &(&1 in features))
    end)
  end
end
