defmodule Apiary.SupportAddress do
  @moduledoc """
  The support address: where "Contact support" leads on the pages and in the emails that
  people in an organisation read (`ApiaryWeb.Support`). It is an https address, such as
  `https://help.example.com`, or an email address, such as `support@example.com`; with
  none, "Contact support" shows as plain text.

  **The address** (`get/0`) is, in order:

  1. `SUPPORT_ADDRESS` in the server's environment, where it is set and not blank
     (`env/0`). `boot!/0` checks it at boot and keeps it in the application's environment
     under `:support_address`, nil where it is not set; a test that puts the key sets the
     variable;
  2. else the address an instance admin saved in Instance settings › General (`stored/0`);
  3. else none, nil.

  `source/0` returns where it comes from.

  **Where it is kept.** `instance_settings.support_address`, the instance's row
  (`Apiary.SupportAddress.Row`); `NULL`, or no row, is none saved. Each node keeps a copy
  (`Apiary.SupportAddress.Cache`), read again over `Apiary.PubSub` after each save;
  without it, as in the tests, `stored/0` reads the row each time. A node whose migration
  of the column has not run yet, with `MIGRATE_ON_BOOT=false`, reads it as none saved.

  **Saving** (`save/2`) is an instance admin's (`Apiary.Access.instance_admin?/1`), with no
  recent sign-in, as the product's name is. A change is an `instance.support_save` entry
  in the trail of the instance's organisation, by the admin, about the organisation, with
  the address before and after: an https address without its query string or fragment, an
  email address as `"email"`, since the audit entry contains no email address, and nil
  for none. Where `SUPPORT_ADDRESS` is set, the saved address is not shown and not
  changed: the page shows the variable's, read only.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query

  alias Apiary.{Access, Audit, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias Apiary.SupportAddress.{Cache, Row}

  # The longest https address the column takes; an email address is at most 254
  # characters (RFC 5321).
  @max_url 2048
  @max_email 254

  # An email address: letters, digits, dots, underscores, plus signs and hyphens before
  # the `@`; letters, digits and hyphens in each part of the domain, with at least one
  # dot. Nothing else, so the `mailto:` link takes no `?`, `%`, `"`, `<` or `>`, and no
  # header or body with them.
  @email ~r/^[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/

  @invalid_message dgettext_noop(
                     "errors",
                     "Enter an https address, such as https://help.example.com, or an email address, such as support@example.com."
                   )

  @typedoc "An https address or an email address."
  @type address :: String.t()

  @typedoc "Where the address comes from: the server's environment, a save, or none."
  @type source :: :env | :saved | :none

  @doc "invalid_message/0 is the field's error for an address `parse/1` returns an error for."
  @spec invalid_message() :: String.t()
  def invalid_message, do: @invalid_message

  ## Reading

  @doc """
  get/0 is the support address: `SUPPORT_ADDRESS` where it is set (`env/0`), else the
  address an instance admin saved (`stored/0`), else nil.
  """
  @spec get() :: address | nil
  def get, do: env() || stored()

  @doc """
  words/1 is "Contact support", or "contact support" inside a sentence, where
  `mid_sentence` is true.
  """
  @spec words(boolean) :: String.t()
  def words(mid_sentence \\ false)
  def words(false), do: gettext("Contact support")
  def words(true), do: gettext("contact support")

  @doc """
  plain/1 is `words/1` in plain text, for a sentence that has no link: a flash, a data
  attribute, a changeset error. Where an address is set, the address follows the words.
  `mid_sentence:` is as in `words/1`; `address:` is the address to use in place of `get/0`,
  nil for the plain words.

      iex> Apiary.SupportAddress.plain(address: "support@example.com")
      "Contact support at support@example.com"

      iex> Apiary.SupportAddress.plain(address: nil, mid_sentence: true)
      "contact support"
  """
  @spec plain(keyword) :: String.t()
  def plain(opts \\ []) when is_list(opts) do
    words = words(Keyword.get(opts, :mid_sentence, false))

    case Keyword.get_lazy(opts, :address, &get/0) do
      nil ->
        words

      address ->
        gettext("%{contact_support} at %{address}", contact_support: words, address: address)
    end
  end

  @doc """
  href/0 is where a link to support leads: the https address as it is, or `mailto:` and
  the email address; nil where there is no address.
  """
  @spec href() :: String.t() | nil
  def href, do: href(get())

  @doc "href/1 is `href/0` for `address`, nil for none."
  @spec href(address | nil) :: String.t() | nil
  def href(nil), do: nil
  def href("https://" <> _rest = url), do: url
  def href(email) when is_binary(email), do: "mailto:" <> email

  @doc """
  source/0 is where the address comes from: `:env`, `SUPPORT_ADDRESS` sets it; `:saved`, an
  instance admin saved it; `:none`, neither.
  """
  @spec source() :: source
  def source do
    cond do
      env() -> :env
      stored() -> :saved
      true -> :none
    end
  end

  @doc """
  env/0 is the address `SUPPORT_ADDRESS` sets, as `boot!/0` checked it, or nil where the
  variable is not set or is blank. Where no boot has kept it, as under `bin/apiary eval`,
  it runs `boot!/0` now.
  """
  @spec env() :: address | nil
  def env do
    case Application.fetch_env(:apiary, :support_address) do
      {:ok, value} ->
        value

      :error ->
        boot!()
        Application.get_env(:apiary, :support_address)
    end
  end

  @doc """
  stored/0 is the address an instance admin saved, as this node's
  `Apiary.SupportAddress.Cache` keeps it, or as the database has it now where no cache
  runs; nil for none.
  """
  @spec stored() :: address | nil
  def stored do
    case Cache.cached() do
      {:ok, address} -> address
      :error -> load()
    end
  end

  @doc """
  load/0 is the address saved, as the database has it now: nil for none, for no row, and
  on a schema whose migration of the column has not run yet.
  """
  @spec load() :: address | nil
  def load do
    Repo.one(from s in "instance_settings", where: s.id == true, select: s.support_address)
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: code} when code in [:undefined_column, :undefined_table] -> nil
        _other -> reraise error, __STACKTRACE__
      end
  end

  ## The variable

  @doc """
  parse/1 reads an address, of `SUPPORT_ADDRESS` or of the field: `{:ok, nil}` for nil or
  a blank value; `{:ok, address}`, trimmed, for an https address with a host and no user
  name or password, of at most #{@max_url} characters, or an email address of at most
  #{@max_email}; `{:error, reason}` otherwise.
  """
  @spec parse(String.t() | nil) :: {:ok, address | nil} | {:error, String.t()}
  def parse(nil), do: {:ok, nil}

  def parse(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      "https://" <> _rest = url -> parse_url(url)
      other -> parse_email(other)
    end
  end

  defp parse_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        cond do
          String.length(url) > @max_url -> {:error, "it is longer than #{@max_url} characters"}
          String.match?(url, ~r/\s/) -> {:error, "it contains a space"}
          true -> {:ok, url}
        end

      _other ->
        {:error, "it is not an https address with a host and no user name or password"}
    end
  end

  defp parse_email(value) do
    cond do
      not Regex.match?(@email, value) ->
        {:error, "it is neither an https address nor an email address"}

      String.length(value) > @max_email ->
        {:error, "it is longer than #{@max_email} characters"}

      true ->
        {:ok, value}
    end
  end

  @doc """
  boot!/0 reads `SUPPORT_ADDRESS` as `config/runtime.exs` left it, checks it (`parse/1`), and
  keeps the address for the life of the node under `:support_address`, nil where the
  variable is not set or is blank, so the address saved in Instance settings › General
  applies. It reads no saved address, since it runs before the database is reached. It
  returns the variable's address, or nil. Called at boot; raises on a value `parse/1`
  returns an error for, so the instance does not start.
  """
  @spec boot!() :: address | nil
  def boot! do
    case parse(Application.get_env(:apiary, :support_address_setting)) do
      {:ok, address} ->
        Application.put_env(:apiary, :support_address, address)
        address

      {:error, reason} ->
        raise ArgumentError, """
        Set SUPPORT_ADDRESS to an https address or an email address, or leave it unset: \
        #{reason}. For example:
        SUPPORT_ADDRESS=https://help.example.com
        SUPPORT_ADDRESS=support@example.com
        """
    end
  end

  ## Saving

  @doc """
  change/1 is the changeset of the form, for the address saved now, or for `attrs`
  (`Apiary.SupportAddress.Row.changeset/2`).
  """
  @spec change(map) :: Ecto.Changeset.t()
  def change(attrs \\ %{}), do: Row.changeset(%Row{support_address: stored()}, attrs)

  @doc """
  save/2 saves the address `attrs` gives, `"support_address"`, for the instance admin of
  `scope`: trimmed; empty is none, and "Contact support" shows as plain text. A change is
  an `instance.support_save` entry in the trail of the instance's organisation, by the
  admin, about the organisation, with the address before and after, as described in the
  module's documentation; a save of the same address writes nothing. Once committed, every
  node's cache reads it again.

  Returns `{:ok, address}`, nil for none; `{:error, changeset}`; `{:error, :env}` where
  `SUPPORT_ADDRESS` sets the address, which a save does not change; or
  `{:error, :forbidden}` for anyone but an instance admin.
  """
  @spec save(Scope.t() | nil, map) ::
          {:ok, address | nil} | {:error, Ecto.Changeset.t() | :env | :forbidden}
  def save(scope, attrs) when is_map(attrs) do
    cond do
      not Access.instance_admin?(scope) -> {:error, :forbidden}
      env() -> {:error, :env}
      true -> write(scope, attrs)
    end
  end

  defp write(scope, attrs) do
    Repo.transact(fn ->
      current = lock_row()
      changeset = Row.changeset(current, attrs)

      with true <- changeset.valid? || {:error, %{changeset | action: :update}},
           {:ok, organisation} <- instance_organisation(),
           {:ok, row} <- write_row(changeset, current),
           :ok <- record(scope, organisation, current, row) do
        {:ok, row.support_address}
      end
    end)
    |> case do
      {:ok, address} ->
        Cache.changed()
        {:ok, address}

      {:error, _reason} = error ->
        error
    end
  end

  # Writes the address where it changed; a save of the same address writes nothing.
  defp write_row(changeset, current) do
    if Ecto.Changeset.changed?(changeset, :support_address),
      do: changeset |> Ecto.Changeset.change(updated_at: DateTime.utc_now()) |> Repo.update(),
      else: {:ok, current}
  end

  # The trail's entry of a change of address; the same address has none. The audit entry
  # contains an https address without its query string or fragment, and an email address
  # only as "email": it contains no email address, as the mail settings' entry contains
  # no sender's address.
  defp record(scope, organisation, current, row) do
    case Audit.changed(
           %{support_address: current.support_address},
           %{support_address: row.support_address},
           [:support_address]
         ) do
      nil ->
        :ok

      _changed ->
        changes = %{
          before: %{support_address: kept(current.support_address)},
          after: %{support_address: kept(row.support_address)}
        }

        with {:ok, _entry} <-
               Audit.record(
                 Repo,
                 Scope.in_organisation(scope, organisation),
                 :"instance.support_save",
                 organisation,
                 changes
               ),
             do: :ok
    end
  end

  defp kept(nil), do: nil

  defp kept("https://" <> _rest = url),
    do: url |> URI.parse() |> Map.merge(%{query: nil, fragment: nil}) |> URI.to_string()

  defp kept(_email), do: "email"

  # The instance's organisation, whose trail holds the entry; its owners are the
  # instance's admins.
  defp instance_organisation do
    with id when is_binary(id) <- Apiary.Edition.instance_organisation_id(),
         %Organisation{} = organisation <- Repo.get(Organisation, id) do
      {:ok, organisation}
    else
      _none -> {:error, :forbidden}
    end
  end

  # The row, locked for the save, made where there is none yet.
  defp lock_row do
    Repo.insert_all("instance_settings", [%{id: true, updated_at: DateTime.utc_now()}],
      on_conflict: :nothing,
      conflict_target: :id
    )

    Repo.one!(from r in Row, where: r.id == true, lock: "FOR UPDATE")
  end
end
