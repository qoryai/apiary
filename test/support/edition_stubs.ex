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

  defmodule LocksElsewhere do
    @moduledoc """
    Refuses no level, and, asked inside a change (`lock: :share`), holds the asker's
    memberships in their other organisations `FOR SHARE`, as an edition that reads a
    person's place in another organisation does: the place the core asks it, in the lock
    order, keeps two changes from waiting on each other at once.
    """
    import Ecto.Query

    alias Apiary.Accounts.{Scope, User}
    alias Apiary.Organisations.Membership

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

        rendezvous()
      end

      Apiary.Edition.module().level_refusal(scope, organisation, level, opts)
    end

    def level_refusal(scope, organisation, level, opts),
      do: Apiary.Edition.module().level_refusal(scope, organisation, level, opts)

    @doc """
    rendezvous/0 pauses a change once it holds its rows, while the test that started it
    asks so (`Process.put(:level_refusal_rendezvous, true)` in the test's process): it
    says `{:level_refusal_held, pid}` to the test and waits for `:level_refusal_go`, so
    two changes hold their rows at once before either goes on.
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
    end
  end

  defmodule AdminsChangeLevels do
    @moduledoc """
    An admin changes the levels of admins and members (`member.change_level`), as an
    edition that lets admins manage both may, and the levels are asked as
    `LocksElsewhere` asks them, holding the asker's memberships in their other
    organisations.
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

    def level_refusal(scope, organisation, level, opts),
      do: LocksElsewhere.level_refusal(scope, organisation, level, opts)
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
