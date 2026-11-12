defmodule ApiaryPro.Organisations do
  @moduledoc """
  Organisations is the edition's ways to more organisations than the core's one: a
  person who has an account creates one from the organisation switcher
  (`create_organisation/2`, `organisation.create`), of a kind the instance's sign-up
  settings open (`ApiaryPro.SignUp`), and the instance owner is the instance
  organisation (`instance_organisation/0`). Each is created by the core's one way,
  `Apiary.Organisations.build_organisation/2`, which tells the edition what it is
  (`ApiaryPro.Tenants.organisation_created/2`).
  """

  use Gettext, backend: ApiaryProWeb.Gettext

  import Ecto.Query, warn: false

  alias Apiary.{Access, Organisations, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{SignUp, Suspensions, Tenants}

  @new_organisation_types %{name: :string, kind: :string}

  @doc """
  instance_organisation/0 is the instance organisation, the organisation the instance's
  first sign-up created, whose owners are the instance admins, of either kind; nil before
  that sign-up.
  """
  @spec instance_organisation() :: %Organisation{} | nil
  def instance_organisation, do: Tenants.instance_organisation()

  @doc """
  new_organisation_kinds/1 is the kinds of organisation the scope's person may create now,
  of `ApiaryPro.Tenants.kinds/0`, as `Apiary.Access.can?/3` answers `organisation.create`
  for each: those the instance's sign-up settings open (`ApiaryPro.SignUp.kinds/0`), for
  anyone signed in. None, `[]`, when both are closed, and for a scope without a person.
  For what a page offers: the switcher's New organisation entry and its form.
  """
  @spec new_organisation_kinds(Scope.t() | nil) :: [Tenants.kind()]
  def new_organisation_kinds(scope) do
    for kind <- Tenants.kinds(),
        Access.can?(scope, :"organisation.create", new_organisation(kind)),
        do: kind
  end

  # The organisation asked about before it exists: of `kind`, of no operator.
  defp new_organisation(kind), do: Tenants.new(kind)

  @doc """
  change_new_organisation/2 is the changeset of the form that names a new organisation for
  a person who has an account: `name`, checked as an organisation's name is, as a
  sign-up's is, and `kind`, among `kinds:`, the kinds of `new_organisation_kinds/1`, as a
  sign-up's kind is (`ApiaryPro.SignUp.validate_kind/2`): asked when there are two, the
  one when there is one.
  """
  @spec change_new_organisation(map, keyword) :: Ecto.Changeset.t()
  def change_new_organisation(attrs \\ %{}, opts \\ []) do
    form =
      {%{}, @new_organisation_types}
      |> Ecto.Changeset.cast(attrs, Map.keys(@new_organisation_types))
      |> Ecto.Changeset.update_change(:name, &String.trim/1)

    name = Ecto.Changeset.get_field(form, :name)

    form
    |> on_name(Organisation.changeset(%Organisation{}, %{name: name}))
    |> SignUp.validate_kind(Keyword.get(opts, :kinds, []))
  end

  @doc """
  create_organisation/2 creates an organisation for the scope's person, who has an account
  already (`organisation.create`, the role `person`'s in `ApiaryPro.Access`): of the kind
  `attrs["kind"]`, or the one kind open when it names none, named `attrs["name"]`, as a
  sign-up creates one (`Apiary.Organisations.build_organisation/2`): a slug made from its
  name, no workspace, the person as its first owner, and the audit entry `organisation.create` that begins its trail, by them, from the scope's
  `origin`, with `details.sign_up` false. They are told, so their switcher shows it.

  The kind is asked of `Apiary.Access` before the form is checked, and again inside the
  transaction, which reads the instance's sign-up settings again, as a sign-up does; the
  person's account is held there `FOR SHARE`, so a deletion of it waits, or is seen.

  Its first workspace comes later: the person makes it from the kind cards on its
  overview, `/:org` (`Apiary.Organisations.create_workspace_of_kind/3`).

  `{:ok, %{organisation:, workspace: nil, membership:}}`; `{:error, changeset}`, the changeset
  of `change_new_organisation/2`, for a name it refuses, one whose address another
  organisation has or a page of Qory Apiary has (Core's `taken: :refuse`: nothing is
  numbered), or a missing choice of kind; `{:error, :forbidden}` for a kind whose setting is
  closed, whatever the form says, and with both closed; `{:error, :not_found}` for an
  account deleted meanwhile, and `Apiary.Access`'s answer otherwise.
  """
  @spec create_organisation(Scope.t(), map) ::
          {:ok, %{organisation: %Organisation{}, workspace: nil, membership: %Membership{}}}
          | {:error, Ecto.Changeset.t() | Access.reason()}
  def create_organisation(%Scope{user: %User{id: user_id} = user} = scope, attrs) do
    kinds = new_organisation_kinds(scope)
    form = change_new_organisation(attrs, kinds: kinds)
    asked = Ecto.Changeset.get_field(form, :kind)
    requested = Enum.find(Tenants.kinds(), &(Atom.to_string(&1) == asked))
    # Without a kind asked for, as when two are open and none is chosen, the form says so,
    # once the person may create any; a kind that is none is refused as a closed one.
    subject = new_organisation(if is_nil(asked), do: List.first(kinds), else: requested)

    with :ok <- Access.authorize(scope, :"organisation.create", subject),
         :ok <- valid_form(form) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:asked, fn _repo, _changes ->
        with :ok <- lock_person(user_id),
             :ok <- active(user_id),
             :ok <- Access.authorize(scope, :"organisation.create", subject),
             do: {:ok, requested}
      end)
      |> Ecto.Multi.put(:user, user)
      |> Organisations.build_organisation(
        name: Ecto.Changeset.get_field(form, :name),
        how: {:kind, requested},
        taken: :refuse,
        workspace: false,
        scope: &person_scope(&1, scope.origin),
        details: %{sign_up: false}
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{created: %{membership: membership} = created}} ->
          Organisations.broadcast_membership_changes([membership])
          {:ok, created}

        {:error, :asked, reason, _changes} ->
          {:error, reason}

        {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, form |> on_name(changeset) |> Map.put(:action, :insert)}
      end
    end
  end

  def create_organisation(_scope, _attrs), do: {:error, :forbidden}

  defp valid_form(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid_form(form), do: {:error, Map.put(form, :action, :insert)}

  # The person who created it, acting in the new organisation.
  defp person_scope(%{user: user, organisation: organisation, workspace: workspace}, origin),
    do: %Scope{user: user, organisation: organisation, workspace: workspace, origin: origin}

  # The errors of the organisation's changeset, every one on the form's `name`.
  defp on_name(form, %Ecto.Changeset{errors: errors}) do
    Enum.reduce(errors, form, fn {_field, {message, keys}}, form ->
      Ecto.Changeset.add_error(form, :name, message, keys)
    end)
  end

  # The person, while their account is not deleted, held `FOR SHARE`, as an acceptance
  # holds them: the deletion of the account waits, or is seen.
  defp lock_person(user_id) do
    if Repo.one(
         from u in User,
           where: u.id == ^user_id and is_nil(u.deleted_at),
           select: u.id,
           lock: "FOR SHARE"
       ),
       do: :ok,
       else: {:error, :not_found}
  end

  # The person, locked by `lock_person/1`, read again: an account suspended meanwhile,
  # which takes it `FOR NO KEY UPDATE`, creates nothing.
  defp active(user_id) do
    if from(u in User, as: :account, where: u.id == ^user_id)
       |> Suspensions.active_accounts(:account)
       |> Repo.exists?(),
       do: :ok,
       else: {:error, :forbidden}
  end
end
