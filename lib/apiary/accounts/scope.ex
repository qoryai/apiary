defmodule Apiary.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Apiary.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  Beyond the user, the scope carries the organisation the caller is acting in,
  the hive inside it and the caller's membership there, once
  `Apiary.Organisations.load_scope/2` has loaded them. Authorization in the
  contexts reads the membership's level.
  """

  alias Apiary.Accounts.User

  defstruct user: nil, organisation: nil, hive: nil, membership: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil
end
