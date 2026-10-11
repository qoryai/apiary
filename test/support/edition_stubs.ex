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

  defmodule HoldsOthers do
    @moduledoc """
    Holds other organisations after some (`c:Apiary.Edition.places_to_lock/1`): an
    organisation the test names (`Process.put(:places_held, %{id => other_ids})` in the
    test's process) is locked with those after its own id; every other one as the core's
    edition locks it (`Apiary.Edition.Core`), whichever edition is configured, so the
    test means the core's order for them.
    """
    alias Apiary.Organisations.Organisation

    def places_to_lock(%Organisation{id: id} = organisation) do
      case Process.get(:places_held, %{}) do
        %{^id => others} -> [id | others]
        _held -> Apiary.Edition.Core.places_to_lock(organisation)
      end
    end
  end

  defmodule ReadsPlaces do
    @moduledoc """
    Reads the organisation's row before it answers `c:Apiary.Edition.places_to_lock/1`, as
    an edition may, and locks nothing; then answers as the core's edition does
    (`Apiary.Edition.Core`).
    """
    import Ecto.Query

    alias Apiary.Organisations.Organisation

    def places_to_lock(%Organisation{id: id} = organisation) do
      _row = Apiary.Repo.one(from o in Organisation, where: o.id == ^id, select: o.id)
      send(self(), {:places_read, id})
      Apiary.Edition.Core.places_to_lock(organisation)
    end
  end

  defmodule Classifies do
    @moduledoc """
    Names other organisations after some (`c:Apiary.Edition.places_to_lock/1`) as a table
    the test keeps says, which it may change while a change runs, as an edition's
    classification changes between a read and a lock: `start/0` makes the table,
    `holds/2` says what an organisation names besides its own id, and `pause_at/1` the
    calls, counted from the first, after whose answer is read the change pauses until the
    test lets it go (`{:classified, pid}` to the test, `:go` back); `answers/2` has an
    organisation name, each time it is asked, the next of the lists given, then the last
    one again; `shifting/1` has it name another each time, one that is not there. Every other
    organisation names itself alone, as the core's edition does.
    """
    alias Apiary.Organisations.Organisation

    @table __MODULE__

    def start do
      :ets.new(@table, [:named_table, :public])
      :ets.insert(@table, [{:calls, 0}, {:pause_at, []}])
      :ok
    end

    def holds(id, others), do: :ets.insert(@table, {{:holds, id}, others})
    def pause_at(calls), do: :ets.insert(@table, {:pause_at, calls})
    def shifting(id), do: :ets.insert(@table, {{:shifting, id}, true})
    def answers(id, others), do: :ets.insert(@table, {{:answers, id}, others})

    def places_to_lock(%Organisation{id: id}) do
      answer =
        case {:ets.lookup(@table, {:shifting, id}), :ets.lookup(@table, {:answers, id}),
              :ets.lookup(@table, {:holds, id})} do
          {[_shifting], _answers, _holds} -> [id, Ecto.UUID.generate()]
          {[], [{_key, answers}], _holds} -> [id | next_answer(id, answers)]
          {[], [], [{_key, others}]} -> [id | others]
          {[], [], []} -> [id]
        end

      call = :ets.update_counter(@table, :calls, 1)
      [{:pause_at, pauses}] = :ets.lookup(@table, :pause_at)

      if call in pauses do
        [test | _] = Process.get(:"$callers", [self()])
        send(test, {:classified, self()})

        receive do
          :go -> :ok
        after
          10_000 -> :ok
        end
      end

      answer
    end

    defp next_answer(_id, [last]), do: last

    defp next_answer(id, [next | rest]) do
      :ets.insert(@table, {{:answers, id}, rest})
      next
    end
  end

  defmodule OutOfUse do
    @moduledoc """
    Holds out of use the organisations the test names
    (`Process.put(:out_of_use, ids)` in the test's process, which the processes it starts
    read too): `c:Apiary.Edition.active_organisations/2` leaves them out, and every other
    organisation as the configured edition does.
    """
    import Ecto.Query

    def active_organisations(query, binding) do
      ids = out_of_use()

      query
      |> Apiary.Edition.module().active_organisations(binding)
      |> where([{^binding, o}], o.id not in ^ids)
    end

    defp out_of_use do
      Enum.find_value([self() | Process.get(:"$callers", [])], [], fn
        pid when pid == self() ->
          Process.get(:out_of_use)

        pid ->
          case Process.info(pid, {:dictionary, :out_of_use}) do
            {{:dictionary, :out_of_use}, ids} when is_list(ids) -> ids
            _unset -> nil
          end
      end)
    end
  end

  defmodule ServesAcross do
    @moduledoc """
    Lets the organisation-level gateways of one organisation serve the workspaces of
    others, as an edition may (`c:Apiary.Edition.serving_organisations/1`,
    `c:Apiary.Edition.served_organisations/1`): the pairs `{serving, served}` the test
    names (`put/1` in the test's process, which the processes it starts read too), the
    serving organisations of one served organisation in the order the test gives them.
    Both answers come from the one list, so each is the reverse of the other. It reads
    nothing and locks nothing. With `out_of_use/1`, it also holds organisations out of use
    as `OutOfUse` does.
    """

    @doc "put/1 names the pairs `{serving, served}`, in order, for the test's processes."
    def put(pairs) when is_list(pairs), do: Process.put(:serves_across, pairs)

    @doc "out_of_use/1 holds the organisations `ids` out of use, as `OutOfUse` reads it."
    def out_of_use(ids) when is_list(ids), do: Process.put(:out_of_use, ids)

    def serving_organisations(id), do: for({serving, ^id} <- pairs(), do: serving)

    def served_organisations(id), do: for({^id, served} <- pairs(), do: served)

    def active_organisations(query, binding), do: OutOfUse.active_organisations(query, binding)

    defp pairs do
      Enum.find_value([self() | Process.get(:"$callers", [])], [], fn
        pid when pid == self() ->
          Process.get(:serves_across)

        pid ->
          case Process.info(pid, {:dictionary, :serves_across}) do
            {{:dictionary, :serves_across}, pairs} when is_list(pairs) -> pairs
            _unset -> nil
          end
      end)
    end
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
