defmodule ApiaryWeb.People do
  @moduledoc """
  How a page names a person it holds by id: the author of a rule or a policy change, the
  person who locked a rule. A row names a person by their account's id and never copies
  a name or an address (`Apiary.Accounts`), so the page looks the account up when it
  shows it, whether or not the person is a member of the organisation, and says
  **Former member** for a person whose account is deleted, a tombstone, or for an id no
  account has. No id at all is nobody: the instance, or a row older than the column; the
  page says what it says for that.
  """
  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Accounts.User

  @doc "The words for a person whose account is deleted, or an id no account has."
  @spec former_member() :: String.t()
  def former_member, do: gettext("Former member")

  @doc """
  email/1 is the email address of `user`, an account a row's id was looked up by: the
  address of an account in use, "Former member" for a deleted one, nil for no account.
  """
  @spec email(%User{} | nil) :: String.t() | nil
  def email(%User{deleted_at: nil, email: email}) when is_binary(email), do: email
  def email(%User{}), do: former_member()
  def email(nil), do: nil

  @doc """
  accounts/1 is the email address of each account of `ids`, by user id
  (`%{user_id => email}`), read in one query whether or not the person is a member of
  the organisation, as `email/1` gives it: the address of an account in use, "Former
  member" for a deleted one. An id no account has is not in it.
  """
  @spec accounts([Ecto.UUID.t() | nil]) :: %{optional(Ecto.UUID.t()) => String.t()}
  def accounts(ids) do
    for user <- Apiary.Accounts.list_users_by_id(ids), into: %{}, do: {user.id, email(user)}
  end

  @doc """
  account/2 is the email address of the person `id` among `accounts`, the accounts a page
  read by user id with `accounts/1`: "Former member" for an id no account has, nil for no
  id.
  """
  @spec account(%{optional(Ecto.UUID.t()) => String.t()}, Ecto.UUID.t() | nil) ::
          String.t() | nil
  def account(_accounts, nil), do: nil
  def account(accounts, id), do: Map.get(accounts, id) || former_member()

  @doc """
  short/1 is the short form of a name `email/1` or `account/2` gave: the local part of an
  address, dana of dana@example.com; "Former member" and nil as they are.
  """
  @spec short(String.t() | nil) :: String.t() | nil
  def short(nil), do: nil
  def short(name), do: User.short_name(name)
end
