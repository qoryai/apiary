defmodule Apiary.Features do
  @moduledoc """
  What this instance offers: its **features**, switched when the instance is launched.

  | Feature | Covers | Needs |
  |---|---|---|
  | `observability` | runs, the terminal log, the session timeline, the connections, retention | nothing |
  | `security` | the security policy and the run configuration served to the gateway | `observability` |
  | `secrets` | the stored secrets, the variables and the integrations of a workspace; opt-in | `security` |
  | `instance_mail` | Instance settings › Mail, the mail settings an instance admin saves (`Apiary.Mail`); opt-in | nothing |

  An edition adds its own features after the core's (`c:Apiary.Edition.features/0`), each
  with the features it needs, whether it is built, and whether it is opt-in. The list is
  read once, checked (`registry/1`), and kept for the life of the node: a name listed
  twice, or a feature that needs one the list does not have, stops the boot.

  `QORY_FEATURES` names the features the instance has, of the whole list: `all`; `all-`
  and the features left out, separated by commas (`all-security`); or the features on,
  separated by commas (`observability,security`). Unset or blank is `all`. A list keeps
  off every feature it does not name, one an upgrade adds included; `all` and `all-…`
  take that one on with the upgrade. A feature of another edition is unknown here.
  `config/runtime.exs` keeps the value as it is (a release reads that file before the
  application's modules can be relied on), and `boot!/0` checks it with `parse/1` when
  the application starts: an unknown name or a feature without the features it needs
  stops the boot. The list is fixed while the instance runs.

  An **opt-in** feature, marked `default: false` (`opt_in/0`), is on only where a list
  names it: `all`, `all-…`, unset and blank leave it off, as an upgrade that adds one
  does. Only an opt-in feature may need one, and it is never one a page switches for an
  organisation (`built/0`).

  A feature that is off is absent, not disabled: its pages answer not found, the navigation
  and the discovery document leave it out, its processes are not started. Every surface asks
  `on?/2`, with the scope it serves.

  ## An organisation's features

  What an organisation or a workspace of it has is `of/2`, the one answer: the edition's
  (`c:Apiary.Edition.features_of/3`), given the instance's features. In the core that is
  the instance's features, in every organisation and workspace alike; an edition may
  narrow them below the instance, and never adds to them: `of/2` keeps only what the
  instance has, and a feature only with the features it needs (`needs/1`, `closed/1`).

  The scope a page or a context function holds carries the answer for its organisation
  and workspace, `features`, loaded with it (`Apiary.Organisations.resolve_scope/4`) and
  read again with its membership (`Apiary.Access.reload/2`), so `on?/2` reads nothing; an
  access key's is read from its organisation and workspace when asked. A feature that is
  off for an organisation is absent there as one the instance lacks is: not reachable,
  shown or advertised. Some surfaces belong to the instance and follow only its switch: the
  guides at `/docs`, the sign-in and landing pages, and the routes' first answer
  (`ApiaryWeb.Features.Routes`).
  """

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Repo

  # The core's features, in the order the instance lists them, each with the features it
  # needs, whether it is built, and `default: false` for one that is opt-in.
  @core [
    observability: [needs: [], built: true],
    security: [needs: [:observability], built: true],
    secrets: [needs: [:security], built: true, default: false],
    instance_mail: [needs: [], built: true, default: false]
  ]

  # What `registry/1` says an entry is, when it refuses one.
  @entry_shape "a feature is {name, needs: [feature], built: boolean}, " <>
                 "with default: boolean where it is given, got: "

  @typedoc "A feature: one of `all/0`."
  @type feature :: atom

  @typedoc "The features of the core and the edition, as `registry/1` checks them."
  @type registry :: %{
          all: [feature],
          needs: %{feature => [feature]},
          built: [feature],
          opt_in: [feature]
        }

  @doc """
  built/0 is the features listed with `built: true` and not opt-in (`opt_in/0`), in the
  order of `all/0`: the ones a page of an edition may switch on or off for an
  organisation. Any other keeps whatever an edition says of it.
  """
  @spec built() :: [feature]
  def built, do: registry().built

  @doc """
  opt_in/0 is the features listed with `default: false`, in the order of `all/0`: on only
  where the value of `QORY_FEATURES` lists them by name (`parse/1`), and never offered for
  an organisation's switch (`built/0`).
  """
  @spec opt_in() :: [feature]
  def opt_in, do: registry().opt_in

  @doc "Every feature, the core's and then the edition's, in the order the instance lists them."
  @spec all() :: [feature]
  def all, do: registry().all

  @doc "The features `feature` needs on. Raises `ArgumentError` for a name that is no feature."
  @spec needs(feature) :: [feature]
  def needs(feature), do: Map.fetch!(registry().needs, known!(feature))

  @doc """
  registry/1 checks a list of features, the core's followed by the edition's, and returns
  what `all/0`, `needs/1`, `built/0` and `opt_in/0` answer from; raises `ArgumentError` on
  a mistake: an entry that is not `{name, needs: [feature], built: boolean}`, with
  `default: boolean` where it is given (`true` where it is not, `false` for an opt-in
  feature), a name listed twice, a feature that needs itself or one the list does not
  have, or a feature that is not opt-in and needs one that is.
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

    # `all` leaves the opt-in features off, so only another opt-in feature may need one.
    for {name, opts} <- features, name not in opt_in, need <- opts[:needs], need in opt_in do
      raise ArgumentError,
            "the feature #{name} needs #{need}, which is opt-in: so is a feature that needs one"
    end

    %{
      all: names,
      needs: Map.new(features, fn {name, opts} -> {name, opts[:needs]} end),
      built: for({name, opts} <- features, opts[:built], name not in opt_in, do: name),
      opt_in: opt_in
    }
  end

  defp check_entry!({name, opts} = entry) when is_atom(name) and is_list(opts) do
    needs = opts[:needs]

    unless is_list(needs) and Enum.all?(needs, &is_atom/1) and is_boolean(opts[:built]) and
             is_boolean(Keyword.get(opts, :default, true)) do
      raise ArgumentError, @entry_shape <> inspect(entry)
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

  `all` may not be one of the features of a list. Every feature but `observability` and
  `instance_mail` needs `observability`, whichever form names them.
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

    case Enum.reject(names, &Map.has_key?(known, &1)) do
      [] ->
        {:ok, Enum.map(names, &Map.fetch!(known, &1))}

      unknown ->
        # The message does not list the features: an instance shows nothing of a feature
        # it does not have, its boot errors included. The Install guide lists them.
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
  Whether `feature` is on where `scope` is: a caller's `Apiary.Accounts.Scope`, which
  carries the features of its organisation and workspace (`of/2`), an access key's scope or
  an access key, whose organisation and workspace are read, or `nil` for the instance. A
  scope that carries no features, as the instance's own jobs', answers as the instance.
  Raises `ArgumentError` for a name that is no feature.
  """
  @spec on?(term, feature) :: boolean
  def on?(%Scope{features: features}, feature) when is_list(features),
    do: known!(feature) in features and on?(feature)

  def on?(%Scope{access_key: %AccessKey{} = key}, feature), do: on?(key, feature)

  def on?(%AccessKey{} = key, feature), do: known!(feature) in of_key(key)

  def on?(_scope, feature), do: on?(feature)

  @doc """
  of/2 is the features `organisation` has, and `workspace` of it when given, as the
  edition answers now (`c:Apiary.Edition.features_of/3`), in the order of `all/0`: of the
  instance's, and each only with the features it needs. Nil for no organisation.
  """
  @spec of(%Organisation{} | nil, %Workspace{} | nil) :: [feature] | nil
  def of(organisation, workspace \\ nil)

  def of(nil, _workspace), do: nil

  def of(%Organisation{} = organisation, workspace) do
    enabled = enabled()

    organisation
    |> Apiary.Edition.features_of(workspace, enabled)
    |> Enum.filter(&(&1 in enabled))
    |> closed()
  end

  @doc """
  of_organisation/1 is the features of the organisation `organisation_id` itself, with no
  workspace, as the database has them now (`of/2`); [] for one that is not there.
  """
  @spec of_organisation(Ecto.UUID.t()) :: [feature]
  def of_organisation(organisation_id) do
    case Repo.get(Organisation, organisation_id) do
      %Organisation{} = organisation -> of(organisation)
      nil -> []
    end
  end

  # The features of an access key's organisation and workspace.
  defp of_key(%AccessKey{organisation_id: organisation_id, workspace_id: workspace_id}) do
    case Repo.get(Organisation, organisation_id) do
      %Organisation{} = organisation -> of(organisation, %Workspace{id: workspace_id})
      nil -> []
    end
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
