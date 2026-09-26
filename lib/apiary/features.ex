defmodule Apiary.Features do
  @moduledoc """
  What this instance offers: its **features**, switched when the instance is launched
  (decision 0070).

  | Feature | Covers | Needs |
  |---|---|---|
  | `observability` | runs, the terminal log, the session timeline, the connections, retention | nothing |
  | `security` | the security policy and the run configuration served to runners | `observability` |

  The other names in `all/0` are kept for features not built yet; each needs
  `observability`.

  `QORY_FEATURES` names the features the instance has: `all`; `all-` and the features left
  out, separated by commas (`all-security`); or the features on, separated by commas
  (`observability,security`). Unset or blank is `all`. A list keeps a feature a later
  release adds off until it is listed; `all` and `all-…` take it on with the upgrade.
  `config/runtime.exs` keeps the value as it is (a release reads that file before the
  application's modules can be relied on), and `boot!/0` checks it with `parse/1` when the
  application starts: an unknown name or a feature without the features it needs stops the
  boot. The list is fixed while the instance runs.

  A feature that is off is absent, not disabled: its pages answer not found, the navigation
  and the discovery document leave it out, its processes are not started. Every surface asks
  `on?/2`, with the scope it serves, so the grants below the instance slot in behind the
  same question; for now the answer is the instance's.
  """

  @features [:observability, :security, :managed_organisations, :factory]

  @needs %{
    observability: [],
    security: [:observability],
    managed_organisations: [:observability],
    factory: [:observability]
  }

  @type feature :: :observability | :security | :managed_organisations | :factory

  @doc "Every feature, in the order the instance lists them."
  @spec all() :: [feature]
  def all, do: @features

  @doc "The features `feature` needs on."
  @spec needs(feature) :: [feature]
  def needs(feature) when feature in @features, do: Map.fetch!(@needs, feature)

  @doc """
  The features a value of `QORY_FEATURES` names: `{:ok, features}` in the order of `all/0`,
  or `{:error, reason}`.

    * `nil`, an empty or a blank value, and `all`: every feature.
    * `all-security`, `all-security,managed_organisations`: every feature but those after
      `all-`, separated by commas.
    * `observability,security`: those features and no other.

  `all` may not be one of the features of a list. Every feature but `observability` needs
  `observability`, whichever form names them.
  """
  @spec parse(String.t() | nil) :: {:ok, [feature]} | {:error, String.t()}
  def parse(nil), do: {:ok, @features}

  def parse(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, @features}

      "all" ->
        {:ok, @features}

      "all-" <> left_out ->
        with {:ok, left_out} <- known(terms(left_out)),
             do: check_needs(@features -- left_out)

      list ->
        names = terms(list)

        cond do
          # Only commas and blanks: as good as unset.
          names == [""] ->
            {:ok, @features}

          Enum.any?(names, &(&1 == "all" or String.starts_with?(&1, "all-"))) ->
            {:error, "all is not a feature to list: all, all-<features>, or the features on"}

          true ->
            with {:ok, listed} <- known(names),
                 do: check_needs(Enum.filter(@features, &(&1 in listed)))
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
    known = Map.new(@features, &{Atom.to_string(&1), &1})

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
  features for the life of the node. Called first thing at boot; raises on a value
  `parse/1` refuses, so the instance does not start.
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
        Leave it unset or set it to all for every feature, or name them, for example:
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
  Whether `feature` is on for the instance.
  """
  @spec on?(feature) :: boolean
  def on?(feature) when feature in @features, do: feature in enabled()

  @doc """
  Whether `feature` is on where `scope` is: a caller's `Apiary.Accounts.Scope`, a
  workspace, an access key, or `nil` for the instance. The answer is the instance's until
  an organisation can be granted less (0070, *Below the instance*); every surface asks
  with its scope so that change reaches it without another edit.
  """
  @spec on?(term, feature) :: boolean
  def on?(_scope, feature) when feature in @features, do: on?(feature)
end
