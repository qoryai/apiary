defmodule Apiary.ProductName do
  @moduledoc """
  The product's name on this instance: the name an instance admin sets in Instance
  settings › General, else a default, which is one of two:

  - `name/0`, the name a page or an email shows: every page title, the log-in, sign-up,
    set-up and welcome pages, the docs' not-built page, and every email's from-name,
    subject and body. Where no name is set it is "Qory Apiary", in every edition.
  - `button_name/0`, the name on the Qory Apiary menu's button and the menu's names.
    Where no name is set it is the edition's (`edition_name/0`,
    `c:ApiaryWeb.Edition.product_name/0`, "Qory Apiary" in Qory Apiary Community).

  The form of Instance settings › General, its toast and the Activity page say an empty
  name as the edition's (`edition_name/0`), as the button shows it.

  **Where it is kept.** `instance_settings.product_name`, the instance's row; `NULL`, or
  no row, is no name set. `updated_by_id` is the admin who set it last. `get/0` is the
  name set, nil for none.

  **Its rules.** A name given keeps the rules of an organisation's name, all of them
  (`Apiary.Organisations.Organisation.validate_name/2`): it is shown inside sentences Qory
  writes, in every email. Spaces at either end are taken off; an empty name is none. Where
  the edition's name is "Qory Apiary", a name of "Qory Apiary" is none too; where the
  edition names the product otherwise, it is kept as given.

  **"Powered by Qory Apiary"** (`powered_by?/0`) shows beside a name set that is not "Qory
  Apiary", where the edition carries it (`c:Apiary.Edition.attribution?/0`).

  **Renaming** (`rename/2`) is an instance admin's (`Apiary.Access.instance_admin?/1`), an
  `instance.rename` entry in the trail of the instance's organisation, with the name
  before and after, nil for none.

  Each node keeps a copy (`Apiary.ProductName.Cache`), read again over `Apiary.PubSub`
  whenever an admin renames the instance; without it, as in the tests, `get/0` reads the
  row each time. A live page reads it once, as it connects (`hold/0`, from
  `ApiaryWeb.ProductName`), and shows that name until the person opens another page, so
  its updates read no row; the page that renames reloads.
  """

  import Ecto.Query

  alias Apiary.{Access, Audit, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias Apiary.ProductName.{Cache, Row}

  # The product's name, which "Powered by" names, and which a name set equal to it does
  # not follow.
  @product "Qory Apiary"

  # Where a live page holds the name it read as it connected (`hold/0`).
  @held {__MODULE__, :held}

  @doc """
  name/0 is the name a page or an email shows: the name an instance admin set (`get/0`),
  else "Qory Apiary", in every edition. A name, not a sentence: it is not translated.
  """
  @spec name() :: String.t()
  def name, do: get() || @product

  @doc """
  button_name/0 is the name on the Qory Apiary menu's button and the menu's names: the
  name an instance admin set (`get/0`), else the edition's (`edition_name/0`).
  """
  @spec button_name() :: String.t()
  def button_name, do: get() || edition_name()

  @doc """
  edition_name/0 is the edition's name for the product
  (`c:ApiaryWeb.Edition.product_name/0`), "Qory Apiary" in Qory Apiary Community: the
  button's where no name is set, and how the form, its toast and the Activity page say an
  empty name.
  """
  @spec edition_name() :: String.t()
  def edition_name, do: ApiaryWeb.Edition.product_name()

  @doc """
  get/0 is the name an instance admin set, as this node's `Apiary.ProductName.Cache` holds
  it, or as the database has it now where no cache runs; nil where none is set.
  """
  @spec get() :: String.t() | nil
  def get do
    case Process.get(@held) do
      {:held, name} ->
        name

      nil ->
        case Cache.cached() do
          {:ok, name} -> name
          :error -> load()
        end
    end
  end

  @doc """
  hold/0 reads the name set once for the calling process, a live page's, which `get/0`
  then answers from until the process ends or renames the instance (`rename/2`). Returns
  `:ok`.
  """
  @spec hold() :: :ok
  def hold do
    Process.delete(@held)
    Process.put(@held, {:held, get()})
    :ok
  end

  @doc "load/0 reads the name set from the database: nil for none, or no row."
  @spec load() :: String.t() | nil
  def load do
    Repo.one(from s in "instance_settings", where: s.id == true, select: s.product_name)
  end

  @doc """
  powered_by?/0 is whether pages and emails say "Powered by Qory Apiary": where a name is
  set that is not "Qory Apiary", and the edition carries the line
  (`c:Apiary.Edition.attribution?/0`).
  """
  @spec powered_by?() :: boolean
  def powered_by?, do: powered_by?(get())

  @doc "powered_by?/1 is `powered_by?/0` for the name set `name`, nil for none."
  @spec powered_by?(String.t() | nil) :: boolean
  def powered_by?(name),
    do: is_binary(name) and name != @product and Apiary.Edition.attribution?()

  @doc """
  change/1 is the changeset of the form, for the name set now, or for `attrs`
  (`Apiary.ProductName.Row.changeset/3`).
  """
  @spec change(map) :: Ecto.Changeset.t()
  def change(attrs \\ %{}) do
    Row.changeset(%Row{product_name: get()}, attrs, edition_name())
  end

  @doc """
  rename/2 sets the name `attrs` gives, `"product_name"`, for the instance admin of
  `scope`, by the rules of the module's documentation: an empty name is none, and the
  defaults show. A change is an `instance.rename` entry in the trail of the instance's
  organisation, by the admin, about the organisation, with the name before and after, nil
  for none; once committed, every node's cache reads it again. `{:ok, name}`, nil for
  none; `{:error, changeset}`; or `{:error, :forbidden}` for anyone but an instance admin.
  """
  @spec rename(Scope.t() | nil, map) ::
          {:ok, String.t() | nil} | {:error, Ecto.Changeset.t() | :forbidden}
  def rename(scope, attrs) when is_map(attrs) do
    if Access.instance_admin?(scope),
      do: save(scope, attrs),
      else: {:error, :forbidden}
  end

  defp save(%Scope{user: user} = scope, attrs) do
    Repo.transact(fn ->
      current = lock_row()
      changeset = Row.changeset(current, attrs, edition_name())

      with true <- changeset.valid? || {:error, %{changeset | action: :update}},
           {:ok, organisation} <- instance_organisation(),
           {:ok, row} <- write(changeset, user, current),
           :ok <- record(scope, organisation, current, row) do
        {:ok, row.product_name}
      end
    end)
    |> case do
      {:ok, name} ->
        Process.delete(@held)
        Cache.changed()
        {:ok, name}

      {:error, _reason} = error ->
        error
    end
  end

  # Writes the name where it changed; a save of the same name writes nothing.
  defp write(changeset, user, current) do
    if Ecto.Changeset.changed?(changeset, :product_name) do
      changeset
      |> Ecto.Changeset.change(updated_by_id: user.id, updated_at: DateTime.utc_now())
      |> Repo.update()
    else
      {:ok, current}
    end
  end

  # The trail's entry of a change of name; the same name has none.
  defp record(scope, organisation, current, row) do
    case Audit.changed(%{name: current.product_name}, %{name: row.product_name}, [:name]) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <-
               Audit.record(
                 Repo,
                 Scope.in_organisation(scope, organisation),
                 :"instance.rename",
                 organisation,
                 changes
               ),
             do: :ok
    end
  end

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
