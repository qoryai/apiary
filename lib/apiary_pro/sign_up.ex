defmodule ApiaryPro.SignUp do
  @moduledoc """
  Who may sign up on the instance: saved by an instance admin on Instance
  settings › Configuration, under Sign-up, unless the server's environment sets it, and
  applied at once.

  The instance's first sign-up is its set-up, by its set-up link (`Apiary.Setup`), and
  creates the instance organisation, whatever the settings say: an operator where the
  instance has `managed_organisations`, an organisation otherwise
  (`ApiaryPro.Tenants.organisation_created/2`, `ApiaryPro.Tenants.first_sign_up_kind/0`).
  Nobody signs up before it. Every later sign-up without an invitation creates the kind
  of organisation it chooses, when the instance's setting for that kind is **open**:

  - Organisations, `open` or `closed`: whether a sign-up may create an ordinary
    organisation, to work in;
  - Operators, `open` or `closed`: whether it may create an operator, to run
    organisations for clients.

  **The setting in effect** for each kind (`settings/0`) is, in order:

  1. the variable of the server's environment, `SIGNUP_ORGANISATIONS` or
     `SIGNUP_OPERATORS`, where it is set and not empty (`env/1`), as `config/runtime.exs`
     read it and `boot!/0` checked it;
  2. else the value an instance admin saved (`stored/0`);
  3. else **closed**: the software cannot tell an instance hosted for others from one a
     team hosts for itself, so only the person who sets the instance up has an account
     without an invitation until the instance opens what it wants.

  `source/1` says where a setting comes from. With both closed, a sign-up without an
  invitation is not offered at all; there is no waiting state
  (`c:Apiary.Edition.sign_up_open?/0` is false). The instance organisation is never a
  kind a sign-up offers. A sign-up with an invitation creates no organisation and asks
  neither.

  The same settings decide which kinds a person who is signed in already may create from
  the organisation menu (`ApiaryPro.Organisations.create_organisation/2`), as
  `Apiary.Access` answers `organisation.create`: none when both are closed.

  The edition's sign-up page asks which kinds to offer (`offer/0`) and checks the kind with its
  form (`change_sign_up/2`); the core's sign-up hands the kind to the edition, which asks
  the settings again inside its transaction.

  **Where they are kept.** The one row of `instance_sign_up` (`ApiaryPro.SignUp.Row`),
  NULL for none saved. Each node keeps a copy (`ApiaryPro.SignUp.Cache`), read again over
  `Apiary.PubSub` after each save, so a change applies on every node once it is
  committed; without it, as in the tests, `stored/0` reads the row each time. A node
  whose migration of the table has not run yet, with `MIGRATE_ON_BOOT=false`, reads them
  as none saved.

  **Saving** (`save/2`) is an instance admin's (`instance.change_sign_up`, asked in the
  scope of `Apiary.Access.instance_scope/1`), after a recent sign-in
  (`Apiary.Accounts.sudo_mode?/2`), and saves only the settings that the
  environment does not set. A change of a setting is an `instance.change_sign_up` entry
  in the trail of the instance's organisation, by the admin, with the settings before and
  after.
  """

  use Gettext, backend: ApiaryProWeb.Gettext

  import Ecto.Query

  alias Apiary.{Access, Accounts, Audit, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.SignUp.{Cache, Row}
  alias ApiaryPro.Tenants

  @kinds [:organisation, :operator]
  @settings [organisation: "SIGNUP_ORGANISATIONS", operator: "SIGNUP_OPERATORS"]
  @setting_keys [
    organisation: :sign_up_organisations_setting,
    operator: :sign_up_operators_setting
  ]

  # The row's column of each kind, the name its field and the trail's entry give it too.
  @fields [organisation: :organisations, operator: :operators]

  @typedoc "What a sign-up setting says: a sign-up may create the kind, or it may not."
  @type setting :: :open | :closed

  @typedoc "Where a setting comes from."
  @type source :: :env | :saved | :default

  @typedoc "The saved settings, by kind, each nil where none is saved."
  @type stored :: %{Tenants.kind() => setting | nil}

  @doc """
  kinds/0 is the kinds of organisation a later sign-up without an invitation may create,
  in the order `:organisation`, `:operator`: those whose setting in effect (`settings/0`)
  is open. None when both are closed, the default.
  """
  @spec kinds() :: [Tenants.kind()]
  def kinds do
    settings = settings()
    for kind <- @kinds, settings[kind] == :open, do: kind
  end

  @doc """
  settings/0 is the setting in effect of each kind: the environment's, else the saved one,
  else closed. Reads no saved setting where the environment sets both.
  """
  @spec settings() :: %{Tenants.kind() => setting}
  def settings do
    stored = if Enum.all?(@kinds, &env/1), do: %{}, else: stored()
    settings(stored)
  end

  @doc """
  settings/1 is the setting in effect of each kind, given the saved settings `stored`
  (`load/0`), as `settings/0` reads them.
  """
  @spec settings(map) :: %{Tenants.kind() => setting}
  def settings(stored) when is_map(stored),
    do: Map.new(@kinds, &{&1, env(&1) || stored[&1] || :closed})

  @doc """
  source/1 is where the setting of `kind` comes from: `:env`, the server's environment
  sets it; `:saved`, an instance admin saved it; `:default`, neither, and it is closed.
  """
  @spec source(Tenants.kind()) :: source
  def source(kind) when kind in @kinds do
    cond do
      env(kind) -> :env
      stored()[kind] -> :saved
      true -> :default
    end
  end

  @doc """
  variable/1 is the variable of the server's environment that sets the setting of `kind`:
  `SIGNUP_ORGANISATIONS` or `SIGNUP_OPERATORS`.
  """
  @spec variable(Tenants.kind()) :: String.t()
  def variable(kind) when kind in @kinds, do: Keyword.fetch!(@settings, kind)

  @doc """
  env/1 is the setting of `kind` the server's environment sets, as `config/runtime.exs`
  read it, or nil where the variable is not set, or is empty. Raises on a value `parse/1`
  refuses, naming the variable, as `boot!/0` does.
  """
  @spec env(Tenants.kind()) :: setting | nil
  def env(kind) when kind in @kinds do
    case Application.get_env(:apiary, Keyword.fetch!(@setting_keys, kind)) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: setting!(kind, value)

      _unset ->
        nil
    end
  end

  @doc """
  stored/0 is the saved settings, as this node's `ApiaryPro.SignUp.Cache` holds them, or
  as the database has them now where no cache runs.
  """
  @spec stored() :: stored
  def stored do
    case Cache.cached() do
      {:ok, stored} -> stored
      :error -> load()
    end
  end

  @doc """
  load/0 is the saved settings as the database has them now: each nil where none is saved,
  where there is no row, and on a schema whose migration of the table has not run yet.
  """
  @spec load() :: stored
  def load, do: row() |> to_stored()

  defp row do
    Repo.get(Row, true)
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :undefined_table} -> nil
        _other -> reraise error, __STACKTRACE__
      end
  end

  defp to_stored(nil), do: Map.new(@kinds, &{&1, nil})

  defp to_stored(%Row{} = row),
    do: Map.new(@fields, fn {kind, field} -> {kind, to_setting(Map.fetch!(row, field))} end)

  defp to_setting("open"), do: :open
  defp to_setting("closed"), do: :closed
  defp to_setting(_none), do: nil

  @doc """
  offer/0 is what the edition's sign-up page offers a sign-up without an invitation now:
  `:not_set_up`, nothing, before the instance is set up, which only its set-up link does
  (`Apiary.Setup`); the kinds a sign-up may create (`kinds/0`); none, `[]`, where sign-up
  is by invitation only (`Apiary.Organisations.sign_up_offer/1`).
  """
  @spec offer() :: :not_set_up | [Tenants.kind()]
  def offer do
    case Organisations.sign_up_offer() do
      :not_set_up -> :not_set_up
      :open -> kinds()
      :closed -> []
    end
  end

  ## Saving

  @doc """
  save/2 saves the settings `attrs` gives, `"organisations"` and `"operators"`, each
  `"open"` or `"closed"`, for the person of `scope`, once `Apiary.Access.authorize/3`
  allows `instance.change_sign_up` in their instance scope
  (`Apiary.Access.instance_scope/1`) and they signed in recently. A setting the environment
  sets is left as it is, whatever its value in `attrs`, and so is a setting with no key in
  `attrs`.

  The row is made where there is none yet, empty; past that, it is written only where a
  saved setting changed. A change of a setting in effect is an `instance.change_sign_up`
  entry in the trail of the instance's organisation, by the admin, about the
  organisation, with each setting that changed, before and after, `open` or `closed`; a
  save that changes none, as one that saves `closed` in place of none, has none. Once
  committed, every node's cache reads the settings again, and the next page a person
  loads offers what they open.

  Returns `{:ok, settings}`, the setting in effect of each kind after the save;
  `{:error, changeset}`; `{:error, :sudo}`, an instance admin whose sign-in is not recent;
  or `{:error, :forbidden}`, anyone else, a nil scope among them.
  """
  @spec save(Scope.t() | nil, map) ::
          {:ok, %{Tenants.kind() => setting}}
          | {:error, Ecto.Changeset.t() | :sudo | :forbidden}
  def save(scope, attrs) when is_map(attrs) do
    with {:ok, instance} <- Access.instance_scope(scope),
         :ok <- Access.authorize(instance, :"instance.change_sign_up", instance.organisation),
         true <- Accounts.sudo_mode?(instance.user) || {:error, :sudo} do
      write(scope, attrs)
    else
      {:error, :sudo} -> {:error, :sudo}
      _refused -> {:error, :forbidden}
    end
  end

  defp write(scope, attrs) do
    Repo.transact(fn ->
      current = lock_row()
      before = to_stored(current)
      changeset = changeset(current, attrs)

      with true <- changeset.valid? || {:error, %{changeset | action: :update}},
           {:ok, organisation} <- instance_organisation(),
           {:ok, row} <- write_row(changeset, current),
           after_save = to_stored(row),
           :ok <- record(scope, organisation, before, after_save) do
        {:ok, settings(after_save)}
      end
    end)
    |> case do
      {:ok, settings} ->
        Cache.changed()
        {:ok, settings}

      {:error, _reason} = error ->
        error
    end
  end

  # The row, locked for the save, made where there is none yet.
  defp lock_row do
    Repo.insert_all("instance_sign_up", [%{id: true, updated_at: DateTime.utc_now()}],
      on_conflict: :nothing,
      conflict_target: :id
    )

    Repo.one!(from r in Row, where: r.id == true, lock: "FOR UPDATE")
  end

  # Writes the row where a saved setting changed; a save of the same settings writes
  # nothing.
  defp write_row(changeset, current) do
    if changeset.changes == %{},
      do: {:ok, current},
      else: changeset |> Ecto.Changeset.change(updated_at: DateTime.utc_now()) |> Repo.update()
  end

  # The trail's entry of a change of a setting in effect, by the row's names; a save that
  # changes none has none.
  defp record(scope, organisation, before, after_save) do
    case Audit.changed(in_words(before), in_words(after_save), Keyword.values(@fields)) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <-
               Audit.record(
                 Repo,
                 Scope.in_organisation(scope, organisation),
                 :"instance.change_sign_up",
                 organisation,
                 changes
               ),
             do: :ok
    end
  end

  # The setting in effect of each kind, `"open"` or `"closed"`, by the row's names.
  defp in_words(stored) do
    settings = settings(stored)
    Map.new(@fields, fn {kind, field} -> {field, Atom.to_string(settings[kind])} end)
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

  # What the save casts: the settings the environment does not set, each `open` or
  # `closed`.
  defp changeset(%Row{} = row, attrs) do
    fields = for {kind, field} <- @fields, is_nil(env(kind)), do: field

    row
    |> Ecto.Changeset.cast(attrs, fields)
    |> Ecto.Changeset.validate_inclusion(:organisations, ~w(open closed))
    |> Ecto.Changeset.validate_inclusion(:operators, ~w(open closed))
    |> Ecto.Changeset.check_constraint(:organisations,
      name: :instance_sign_up_organisations_check
    )
    |> Ecto.Changeset.check_constraint(:operators, name: :instance_sign_up_operators_check)
  end

  @doc """
  first_sign_up_line/0 is the set-up page's line on what the instance's set-up creates
  (`c:Apiary.Edition.first_sign_up_line/0`), by the kind it makes
  (`ApiaryPro.Tenants.first_sign_up_kind/0`), read when it is asked: an operator with
  `managed_organisations`, and the core's line, an organisation, otherwise.
  """
  @spec first_sign_up_line() :: String.t()
  def first_sign_up_line do
    case Tenants.first_sign_up_kind() do
      :operator ->
        gettext("Your account and your operator, to run organisations for clients.")

      :organisation ->
        Apiary.Edition.Core.first_sign_up_line()
    end
  end

  @doc """
  change_sign_up/2 is the changeset of the edition's sign-up form: the core's
  (`Apiary.Organisations.change_sign_up/2`, with the same options), and, for a sign-up
  without an invitation, `kind`, what it creates, among `kinds:`, the kinds of
  `offer/0`, as `validate_kind/2` checks it.
  """
  @spec change_sign_up(map, keyword) :: Ecto.Changeset.t()
  def change_sign_up(attrs \\ %{}, opts \\ []) do
    form = Organisations.change_sign_up(attrs, opts)

    if Keyword.get(opts, :invited, false) do
      form
    else
      %{form | types: Map.put(form.types, :kind, :string)}
      |> Ecto.Changeset.cast(attrs, [:kind])
      |> validate_kind(Keyword.get(opts, :kinds, []))
    end
  end

  @doc """
  validate_kind/2 checks a form's `kind` against `kinds`, the kinds it may create: asked,
  and one of them, when there are two; the one when there is one, and refused as another;
  not asked when there is none.
  """
  @spec validate_kind(Ecto.Changeset.t(), [Tenants.kind()]) :: Ecto.Changeset.t()
  def validate_kind(form, [_, _ | _] = kinds) do
    form
    |> Ecto.Changeset.validate_required(:kind, message: choose_what_to_create())
    |> Ecto.Changeset.validate_inclusion(:kind, Enum.map(kinds, &Atom.to_string/1),
      message: choose_what_to_create()
    )
  end

  def validate_kind(form, [kind]) do
    open = Atom.to_string(kind)

    case Ecto.Changeset.get_change(form, :kind) do
      nil -> Ecto.Changeset.put_change(form, :kind, open)
      ^open -> form
      _closed -> Ecto.Changeset.add_error(form, :kind, not_open())
    end
  end

  def validate_kind(form, _none), do: Ecto.Changeset.delete_change(form, :kind)

  @doc "The error of a form that asks which kind to create, and was told none of them."
  @spec choose_what_to_create() :: String.t()
  def choose_what_to_create, do: dgettext_noop("errors", "choose what to create")

  @doc "The error of a form that asks for a kind the instance does not open."
  @spec not_open() :: String.t()
  def not_open, do: dgettext_noop("errors", "is not open for sign-up")

  @doc """
  parse/1 reads a value of `SIGNUP_ORGANISATIONS` or `SIGNUP_OPERATORS`: `{:ok, :open}` or
  `{:ok, :closed}`, closed for nil or a blank value, the case and the spaces around it
  ignored; `{:error, reason}` for anything else.
  """
  @spec parse(String.t() | nil) :: {:ok, setting} | {:error, String.t()}
  def parse(nil), do: {:ok, :closed}

  def parse(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> {:ok, :closed}
      "open" -> {:ok, :open}
      "closed" -> {:ok, :closed}
      other -> {:error, "it is open or closed, got: #{inspect(other)}"}
    end
  end

  @doc """
  boot!/0 checks `SIGNUP_ORGANISATIONS` and `SIGNUP_OPERATORS` as `config/runtime.exs`
  left them. Called at boot, before the database is read; raises on a value `parse/1`
  refuses, naming the variable, so the instance does not start. It reads no saved
  setting: which kinds are open is read each time it is asked (`kinds/0`).
  """
  @spec boot!() :: :ok
  def boot!, do: Enum.each(@kinds, &env/1)

  defp setting!(kind, value) do
    case parse(value) do
      {:ok, setting} ->
        setting

      {:error, reason} ->
        variable = variable(kind)

        raise ArgumentError, """
        environment variable #{variable} is not valid: #{reason}.
        Leave it unset for closed, or set it, for example:
        #{variable}=open
        """
    end
  end
end
