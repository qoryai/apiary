defmodule Apiary.EditionStubs do
  @moduledoc """
  EditionStubs is stubs of the edition for the tests of the core's seams: each answers a
  few callbacks as an edition that narrows the core would, in the test's own processes
  (`Apiary.Edition.put_test_stub/1`), and asks the configured edition there, so a test
  holds under every edition. The configured edition answers every other callback.
  """

  alias Apiary.Organisations.Organisation

  defmodule NoOwner do
    @moduledoc """
    Nobody is made an owner (`c:Apiary.Edition.level_refusal/4`, `:no_owner`), which the
    pages say in its own words (`c:ApiaryWeb.Edition.level_refusal_sentence/2`).
    """
    def level_refusal(_scope, _organisation, :owner, _opts), do: :no_owner

    def level_refusal(scope, organisation, level, opts),
      do: Apiary.Edition.module().level_refusal(scope, organisation, level, opts)

    def level_refusal_sentence(:no_owner, %{organisation: %Organisation{name: name}}),
      do: "Nobody in #{name} is made an owner here."

    def level_refusal_sentence(reason, scope),
      do: ApiaryWeb.Edition.module().level_refusal_sentence(reason, scope)
  end

  defmodule NoOwnerInvitedAsOwner do
    @moduledoc """
    Nobody is made an owner, while an invitation's acceptance would make its person one:
    the edition's answer to the acceptance, made owner.
    """
    def level_refusal(scope, organisation, level, opts),
      do: NoOwner.level_refusal(scope, organisation, level, opts)

    def accepting(repo, invitation, user) do
      with {:ok, _level} <- Apiary.Edition.module().accepting(repo, invitation, user),
           do: {:ok, :owner}
    end
  end

  defmodule NoMember do
    @moduledoc "Nobody is made a member (`c:Apiary.Edition.level_refusal/4`, `:no_member`)."
    def level_refusal(_scope, _organisation, :member, _opts), do: :no_member

    def level_refusal(scope, organisation, level, opts),
      do: Apiary.Edition.module().level_refusal(scope, organisation, level, opts)
  end

  @doc """
  rendezvous/0 pauses a change where a stub calls it, while the test that started it asks
  so (`Process.put(:level_refusal_rendezvous, true)` in the test's process): it says
  `{:level_refusal_held, pid}` to the test and waits for `:level_refusal_go`, so changes
  stand at the same place at once before any goes on.
  """
  def rendezvous do
    with [caller | _] when is_pid(caller) <- Process.get(:"$callers", []),
         {{:dictionary, _key}, true} <-
           Process.info(caller, {:dictionary, :level_refusal_rendezvous}) do
      send(caller, {:level_refusal_held, self()})

      receive do
        :level_refusal_go -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end

  defmodule LocksItsRows do
    @moduledoc """
    Keeps the lock order (`c:Apiary.Edition.lock_rows/1`): it takes its rows at the one
    point a change has, all at once in one fixed order, its rows of organisations before
    its rows of people, each by key, and none later. The core has no table of the
    edition's, so its rows are transaction-level advisory locks: a write's asker, shared
    (`{:places, scope}`); a change of people's asker, shared, as at `{:places, scope}`,
    and the organisation whose people change, exclusive (`{:people, scope,
    organisation}`); each organisation the core holds for a deleted account, exclusive
    (`{:account, user_id, organisation_ids}`). Each is held as a row would be until the
    change ends. A change of people pauses just before its point
    (`Apiary.EditionStubs.rendezvous/0`), a write just after.
    """
    alias Apiary.Accounts.{Scope, User}
    alias Apiary.Organisations.Organisation

    def lock_rows({:places, scope}) do
      :ok = take(asker(scope))
      :ok = Apiary.EditionStubs.rendezvous()
    end

    def lock_rows({:people, scope, %Organisation{id: id}}) do
      :ok = Apiary.EditionStubs.rendezvous()
      take([{:organisation, id, :exclusive} | asker(scope)])
    end

    def lock_rows({:account, _user_id, organisation_ids}),
      do: take(Enum.map(organisation_ids, &{:organisation, &1, :exclusive}))

    def lock_rows(_about), do: :ok

    defp asker(%Scope{user: %User{id: user_id}}), do: [{:person, user_id, :shared}]
    defp asker(_scope), do: []

    # Rows of organisations come before rows of people (`:organisation` sorts before
    # `:person`), then by key.
    defp take(rows) do
      for {class, id, mode} <- Enum.sort(rows) do
        function =
          if mode == :shared, do: "pg_advisory_xact_lock_shared", else: "pg_advisory_xact_lock"

        Apiary.Repo.query!(
          "SELECT #{function}(hashtextextended($1, 0))",
          ["apiary-edition-stub:#{class}:#{id}"]
        )
      end

      :ok
    end
  end

  defmodule PausesAfterAccount do
    @moduledoc """
    Takes its rows as `LocksItsRows` does, and pauses an account's deletion once it holds
    them (`Apiary.EditionStubs.rendezvous/0`).
    """
    def lock_rows({:account, _user_id, _organisation_ids} = about) do
      :ok = LocksItsRows.lock_rows(about)
      :ok = Apiary.EditionStubs.rendezvous()
    end

    def lock_rows(about), do: LocksItsRows.lock_rows(about)
  end

  defmodule PausesAroundAccount do
    @moduledoc """
    Takes its rows as `LocksItsRows` does, and pauses an account's deletion twice at
    `{:account, user_id, organisation_ids}`: before it takes its rows, and once it holds
    them (`Apiary.EditionStubs.rendezvous/0`).
    """
    def lock_rows({:account, _user_id, _organisation_ids} = about) do
      :ok = Apiary.EditionStubs.rendezvous()
      :ok = LocksItsRows.lock_rows(about)
      :ok = Apiary.EditionStubs.rendezvous()
    end

    def lock_rows(about), do: LocksItsRows.lock_rows(about)
  end

  defmodule AcceptingLocksTheOrganisation do
    @moduledoc """
    Holds the invitation's organisation `FOR UPDATE` as an acceptance begins
    (`c:Apiary.Edition.accepting/3`, which may hold it more strongly), and takes its rows as
    `PausesAfterAccount` does.
    """
    import Ecto.Query

    alias Apiary.Organisations.Organisation

    def accepting(repo, invitation, user) do
      id = invitation.organisation_id
      repo.one(from o in Organisation, where: o.id == ^id, select: o.id, lock: "FOR UPDATE")
      Apiary.Edition.module().accepting(repo, invitation, user)
    end

    def lock_rows(about), do: PausesAfterAccount.lock_rows(about)
  end

  defmodule OrganisationRow do
    @moduledoc """
    Holds a row of its own per organisation: shared for a write (`{:places, scope}`),
    exclusive for a change of its people (`{:people, scope, organisation}`), which takes it
    in the stronger mode at that one point, and pauses just before it.
    """
    alias Apiary.Accounts.Scope
    alias Apiary.Organisations.Organisation

    def lock_rows({:places, %Scope{organisation: %Organisation{id: id}}}),
      do: lock("pg_advisory_xact_lock_shared", id)

    def lock_rows({:people, _scope, %Organisation{id: id}}) do
      :ok = Apiary.EditionStubs.rendezvous()
      lock("pg_advisory_xact_lock", id)
    end

    def lock_rows(_about), do: :ok

    defp lock(function, id) do
      Apiary.Repo.query!("SELECT #{function}(hashtextextended($1, 0))", [
        "apiary-edition-stub:organisation:#{id}"
      ])

      :ok
    end
  end

  defmodule LocksTwice do
    @moduledoc """
    Breaks the lock order: it takes a row of its own as it is asked for a level, shared,
    keyed by the asker, and another later in the same change, once the membership is
    written, exclusive, keyed by the person whose level changed. A test shows the deadlock
    it makes.
    """
    alias Apiary.Accounts.{Scope, User}

    def level_refusal(%Scope{user: %User{id: user_id}} = scope, organisation, level, opts) do
      if opts[:lock] == :share do
        lock("pg_advisory_xact_lock_shared", user_id)
        Apiary.EditionStubs.rendezvous()
      end

      Apiary.Edition.module().level_refusal(scope, organisation, level, opts)
    end

    def level_refusal(scope, organisation, level, opts),
      do: Apiary.Edition.module().level_refusal(scope, organisation, level, opts)

    def membership_changed(repo, scope, change, old, new) do
      lock("pg_advisory_xact_lock", new.user_id)
      Apiary.Edition.module().membership_changed(repo, scope, change, old, new)
    end

    defp lock(function, user_id) do
      Apiary.Repo.query!("SELECT #{function}(hashtextextended($1, 0))", [
        "apiary-edition-stub:person:#{user_id}"
      ])
    end
  end

  defmodule RecordsLockRows do
    @moduledoc """
    Says each time the core asks the edition to lock its rows (`c:Apiary.Edition.lock_rows/1`)
    to the process that asks, `{:lock_rows, point}`, the point's name, and
    `{:lock_rows_about, about}`, what it was asked, and answers as the configured edition
    does.
    """
    def lock_rows(about) do
      send(self(), {:lock_rows, elem(about, 0)})
      send(self(), {:lock_rows_about, about})
      Apiary.Edition.module().lock_rows(about)
    end
  end

  defmodule LocksAMembership do
    @moduledoc """
    Breaks the lock order: asked inside a change (`lock: :share`), it holds the asker's
    memberships in their other organisations `FOR SHARE`, which the order forbids an
    edition (`c:Apiary.Edition.level_refusal/4`). A test shows the deadlock it makes.
    """
    import Ecto.Query

    alias Apiary.Accounts.{Scope, User}
    alias Apiary.Organisations.{Membership, Organisation}

    def level_refusal(
          %Scope{user: %User{id: user_id}} = scope,
          %Organisation{id: organisation_id} = organisation,
          level,
          opts
        ) do
      if opts[:lock] == :share do
        Apiary.Repo.all(
          from m in Membership,
            where: m.user_id == ^user_id and m.organisation_id != ^organisation_id,
            order_by: [asc: m.id],
            select: m.id,
            lock: "FOR SHARE"
        )

        Apiary.EditionStubs.rendezvous()
      end

      Apiary.Edition.module().level_refusal(scope, organisation, level, opts)
    end

    def level_refusal(scope, organisation, level, opts),
      do: Apiary.Edition.module().level_refusal(scope, organisation, level, opts)
  end

  defmodule AdminsChangeLevels do
    @moduledoc """
    An admin changes the levels of admins and members (`member.change_level`), as an
    edition that lets admins manage both may, and its rows are taken as `LocksItsRows`
    takes them.
    """
    alias Apiary.Access
    alias Apiary.Organisations.Membership

    def check(scope, :"member.change_level", %Membership{level: level} = membership)
        when level in [:admin, :member] do
      with :ok <- Access.check_place(scope, :"member.change_level", membership) do
        if Access.role(scope) == :admin,
          do: :ok,
          else: Apiary.Edition.module().check(scope, :"member.change_level", membership)
      end
    end

    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)

    def lock_rows(about), do: LocksItsRows.lock_rows(about)
  end

  defmodule None do
    @moduledoc "Answers nothing: the configured edition answers every callback, as without a stub."
  end

  defmodule NoLimit do
    @moduledoc "Nobody sets a pool's instance limit (`node.set_limit`), whoever asks."
    def check(_scope, :"node.set_limit", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end
end
