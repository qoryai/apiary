defmodule ApiaryWeb.People do
  @moduledoc """
  How a page names a person it holds by id: the author of a rule or a policy change, the
  person who locked a rule. A row names a person by their account's id and never copies
  a name or an address (`Apiary.Accounts`), so the page looks the account up when it
  shows it, and says **Former member** for a person whose account is deleted, a
  tombstone, whatever row names them. A page that looks people up among the members of
  its workspace says the same for a person who is no longer one. No id at all is nobody:
  the instance, or a row older than the column; the page says what it says for that.
  """
  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Accounts.User

  @doc "The words for a person whose account is deleted or who is no longer a member."
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
  member/2 is the email address of the person `id` among `people`, the members a page
  read by user id (`%{user_id => email}`): "Former member" for an id that is not among
  them, nil for no id.
  """
  @spec member(%{optional(Ecto.UUID.t()) => String.t()}, Ecto.UUID.t() | nil) ::
          String.t() | nil
  def member(_people, nil), do: nil
  def member(people, id), do: Map.get(people, id) || former_member()

  @doc """
  short/1 is the short form of a name `email/1` or `member/2` gave: the local part of an
  address, dana of dana@example.com; "Former member" and nil as they are.
  """
  @spec short(String.t() | nil) :: String.t() | nil
  def short(nil), do: nil
  def short(name), do: name |> String.split("@") |> hd()
end
