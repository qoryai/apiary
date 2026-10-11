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
  rendezvous/0 pauses a change once the edition holds its first rows, while the test that
  started it asks so (`Process.put(:level_refusal_rendezvous, true)` in the test's
  process): it says `{:level_refusal_held, pid}` to the test and waits for
  `:level_refusal_go`, so two changes hold their rows at once before either goes on.
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
    point a change has, in one fixed order, its rows of people before its rows of
    organisations, each by key, and none later. The core has no table of the edition's, so
    its rows are transaction-level advisory locks: a write's or a change's asker, shared
    (`{:places, scope}`); the organisation whose people change, exclusive
    (`{:people, scope, organisation}`); every organisation of a deleted account, exclusive
    (`{:account, user_id}`). Each is held as a row would be until the change ends.
    """
    import Ecto.Query

    alias Apiary.Accounts.{Scope, User}
    alias Apiary.Organisations.{Membership, Organisation}

    def lock_rows({:places, %Scope{user: %User{id: user_id}}}) do
      :ok = take(:shared, [{:person, user_id}])
      :ok = Apiary.EditionStubs.rendezvous()
    end

    def lock_rows({:people, _scope, %Organisation{id: id}}),
      do: take(:exclusive, [{:organisation, id}])

    def lock_rows({:account, user_id}) do
      ids =
        Apiary.Repo.all(
          from m in Membership, where: m.user_id == ^user_id, select: m.organisation_id
        )

      take(:exclusive, Enum.map(ids, &{:organisation, &1}))
    end

    def lock_rows(_about), do: :ok

    # Rows of people come before rows of organisations, then by key.
    defp take(mode, rows) do
      function =
        if mode == :shared, do: "pg_advisory_xact_lock_shared", else: "pg_advisory_xact_lock"

      for {class, id} <- Enum.sort(rows) do
        Apiary.Repo.query!(
          "SELECT #{function}(hashtextextended($1, 0))",
          ["apiary-edition-stub:#{class}:#{id}"]
        )
      end

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
    to the process that asks, `{:lock_rows, about}`, `about` the point's name, and answers
    as the configured edition does.
    """
    def lock_rows(about) do
      send(self(), {:lock_rows, elem(about, 0)})
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
