defmodule Apiary.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Apiary.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  Beyond the user, the scope carries the organisation the caller is acting in,
  the workspace inside it and the caller's membership there, once
  `Apiary.Organisations.resolve_scope/3` has loaded the ones a page's path names
  (decision 0073), or `Apiary.Organisations.load_scope/2` the user's own. Authorization
  in the contexts reads the membership's level.
  """

  alias Apiary.Accounts.{Preferences, User}

  @typedoc "Who is asking, and in which organisation and workspace."
  @type t :: %__MODULE__{}

  defstruct user: nil, organisation: nil, workspace: nil, membership: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  The time zone the scope's times are shown in: its user's preference, an IANA name
  (`Apiary.Accounts.Preferences`), or UTC without a user. A stored zone the zone database
  no longer knows (a later release of it dropped the name) reads UTC too, so it always
  converts. Every time is stored in UTC.

      iex> Apiary.Accounts.Scope.time_zone(nil)
      "Etc/UTC"
  """
  @spec time_zone(t | nil) :: String.t()
  def time_zone(%__MODULE__{user: %User{time_zone: zone}}) do
    if Preferences.time_zone?(zone), do: zone, else: Preferences.default_time_zone()
  end

  def time_zone(_scope), do: Preferences.default_time_zone()

  @doc """
  The language the scope's pages are written in: its user's preference, or English
  without a user, as stored. `ApiaryWeb.Lingo.locale_for/1` puts it together with the
  workspace's domain, and reads English for a language that has no catalogue.

      iex> Apiary.Accounts.Scope.language(nil)
      "en"
  """
  @spec language(t | nil) :: String.t()
  def language(%__MODULE__{user: %User{language: language}}) when is_binary(language),
    do: language

  def language(_scope), do: Preferences.default_language()
end
