defmodule Apiary.AuditCase do
  @moduledoc """
  AuditCase is the audit test as data: every audited action of `Apiary.Access` made the
  way the product makes it, and made again refused, with the trail read before and after
  each. A module of changes gives, for its edition, the audited actions it makes and how
  to make and refuse each. `use`d with the changes modules of the core and of an edition:

      use Apiary.AuditCase, changes: [Apiary.AuditChanges, MyEdition.AuditChanges]

  it generates a test that every action is audited or says why not
  (`Apiary.Audit.not_audited/0`), one that every audited action is made by exactly one of
  the modules and that they make nothing else, and, one per audited action, in a
  `describe "each change"`, that the change leaves exactly one entry, the right one, with
  no personal data or secret, and, in a `describe "a change that is refused or rolled
  back"`, that the change refused leaves none, each asked of the module that makes the
  action. Those two describes are the case's: a test module's own tests go in describes
  of other names. The test module is not async, runs on an instance with every feature,
  has `Oban.Testing`, and imports the helpers a changes module and a hand-written test
  share: `entries/0`, `last/0`, `in_trail/2`, `old!/1`, `organisation_id/1`,
  `refute_personal/2` and `owner/0`.

  The core's own test is `use Apiary.AuditCase, changes: [Apiary.AuditChanges], covers:
  :core`: the core's actions, as `Apiary.AccessCase.actions/1` says them. The edition's
  test covers every action, with the core's module and its own, and so makes the core's
  changes again, under the edition.

  A changes module implements:

  - `actions/0`, the audited actions it makes;
  - `make/2`, given `action` and the test's context (`owner/0`: `owner`, a person who
    signed up, and `scope`, theirs), sets up what the change needs, reads the trail
    (`entries/0`), makes the change, and returns `%{scope: scope, subject: {kind, id},
    before: entries}`: the scope whose organisation's trail holds the entry, and whose
    person made it; the entry's subject; and the trail before the change, with any entry
    the change leaves beside the one looked for. `actor: :instance` for a change the
    instance makes, and `secret:` for a secret the change shows once, which the entry must
    not keep;
  - `refuse/2`, given the same, makes the change refused or rolled back, and returns
    `{before, answer}`: the trail before the attempt, and its answer, `{:error, reason}`.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import Ecto.Query

  alias Apiary.{Access, Audit, Organisations, OrganisationsFixtures, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Audit.Entry

  using opts do
    modules = Keyword.fetch!(opts, :changes)
    covers = Keyword.get(opts, :covers, :all)

    quote bind_quoted: [modules: modules, covers: covers] do
      # Not async: the changes are made on an instance with every feature, which is the
      # node's.
      use Apiary.DataCase, async: false
      use Oban.Testing, repo: Apiary.Repo

      import Apiary.AuditCase,
        only: [
          entries: 0,
          in_trail: 2,
          last: 0,
          old!: 1,
          organisation_id: 1,
          owner: 0,
          refute_personal: 2
        ]

      @moduletag with_features: Apiary.Features.all()

      @audit_changes modules
      @audit_covers covers

      test "every action is audited, or says why it is not" do
        covered = Apiary.AccessCase.actions(@audit_covers)

        for {action, reason} <- Apiary.Audit.not_audited(), action in covered do
          assert is_binary(reason) and reason != "", "#{action} says no reason"
          refute Apiary.Audit.audited?(action)
        end

        for action <- covered do
          assert Apiary.Audit.audited?(action) or
                   Keyword.has_key?(Apiary.Audit.not_audited(), action),
                 "#{action} is not audited, and says not why"
        end

        refute Apiary.Audit.audited?(:"no.such_action")
      end

      test "each audited action is made by exactly one module of changes, and they make no other" do
        Apiary.AuditCase.assert_made(@audit_changes, @audit_covers)
      end

      describe "each change" do
        setup do: Apiary.AuditCase.owner()

        for action <- Apiary.AuditCase.actions(covers) do
          @tag action: action
          test "#{action} leaves exactly one entry, with no personal data or secret", ctx do
            Apiary.AuditCase.assert_one_entry(ctx, @audit_changes)
          end
        end
      end

      describe "a change that is refused or rolled back" do
        setup do: Apiary.AuditCase.owner()

        for action <- Apiary.AuditCase.actions(covers) do
          @tag action: action
          test "#{action} refused leaves no entry", ctx do
            Apiary.AuditCase.assert_no_entry(ctx, @audit_changes)
          end
        end
      end
    end
  end

  @doc """
  actions/1 is the audited actions a test covers: of `Apiary.AccessCase.actions/1`, `:all`
  or `:core`, those that leave an entry (`Apiary.Audit.audited?/1`).
  """
  @spec actions(:all | :core) :: [Access.action()]
  def actions(covers), do: Enum.filter(Apiary.AccessCase.actions(covers), &Audit.audited?/1)

  @doc """
  assert_made/2 asserts that each audited action `covers` names is made by exactly one of
  `modules`, and that they make no other action.
  """
  @spec assert_made([module], :all | :core) :: :ok
  def assert_made(modules, covers) do
    audited = actions(covers)

    for action <- audited do
      makers = makers(modules, action)
      assert length(makers) == 1, "#{action} is made by #{inspect(makers)}, not by exactly one"
    end

    for module <- modules, action <- module.actions() do
      assert action in audited, "#{inspect(module)} makes #{action}, no audited action here"
    end

    :ok
  end

  @doc """
  assert_one_entry/2 makes the test's `action`, by the module of `modules` that makes it,
  and asserts that it left exactly one entry: of the action, in the organisation of the
  scope `make/2` returned, of its subject, by its person or the instance, with no email
  address and not the secret the change showed.
  """
  @spec assert_one_entry(map, [module]) :: :ok
  def assert_one_entry(%{action: action} = ctx, modules) do
    %{scope: scope, subject: subject, before: before} =
      made = maker(modules, action).make(action, ctx)

    assert [entry] = entries() -- before
    assert entry.action == Atom.to_string(action)
    assert Audit.action(entry) == action
    assert entry.organisation_id == organisation_id(scope)
    assert {entry.subject_kind, entry.subject_id} == subject
    assert %DateTime{} = entry.inserted_at

    case made do
      %{actor: :instance} -> assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
      _person -> assert {entry.actor_kind, entry.actor_id} == {:person, scope.user.id}
    end

    refute_personal(entry, made[:secret])
    :ok
  end

  @doc """
  assert_no_entry/2 makes the test's `action` refused, by the module of `modules` that
  makes it, and asserts that the attempt was refused and left no entry.
  """
  @spec assert_no_entry(map, [module]) :: :ok
  def assert_no_entry(%{action: action} = ctx, modules) do
    assert {before, {:error, _reason}} = maker(modules, action).refuse(action, ctx)
    assert entries() -- before == []
    :ok
  end

  defp maker(modules, action) do
    case makers(modules, action) do
      [module] -> module
      makers -> flunk("#{action} is made by #{inspect(makers)}, not by exactly one")
    end
  end

  defp makers(modules, action), do: Enum.filter(modules, &(action in &1.actions()))

  @doc """
  owner/0 is the context each change is made in: `owner`, what
  `Apiary.OrganisationsFixtures.sign_up_fixture/1` returns for a fresh person, and
  `scope`, theirs.
  """
  @spec owner() :: %{owner: map, scope: Scope.t()}
  def owner do
    owner = OrganisationsFixtures.sign_up_fixture()
    %{owner: owner, scope: owner.scope}
  end

  @doc """
  refuse_as_member/4 attempts `action` as a member of the organisation of the context's
  `scope`, where the change is an owner's or an admin's; where every member may make it,
  as a person who was a member when their scope was loaded and is no longer. `prepare`,
  given the context, makes what the attempt needs; `attempt`, given the member's scope
  and what `prepare` made, makes the change. `{before, answer}`, as `refuse/2` returns.
  """
  @spec refuse_as_member(Access.action(), map, (map -> term), (Scope.t(), term -> term)) ::
          {[Entry.t()], term}
  def refuse_as_member(action, %{scope: scope} = ctx, prepare, attempt) do
    %{scope: member, membership: membership} = OrganisationsFixtures.member_fixture(scope)
    prepared = prepare.(ctx)

    if action in Access.roles().member,
      do: {:ok, _} = Organisations.remove_member(scope, membership.id)

    before = entries()
    {before, attempt.(member, prepared)}
  end

  @doc "entries/0 is every entry of the trail, oldest first."
  @spec entries() :: [Entry.t()]
  def entries, do: Repo.all(from e in Entry, order_by: [asc: e.inserted_at, asc: e.id])

  @doc "last/0 is the newest entry of the trail."
  @spec last() :: Entry.t() | nil
  def last, do: Repo.one(from e in Entry, order_by: [desc: e.inserted_at, desc: e.id], limit: 1)

  @doc "in_trail/2 is the one entry of `entries` in `organisation`'s trail."
  @spec in_trail([Entry.t()], %{id: Ecto.UUID.t()}) :: Entry.t()
  def in_trail(entries, organisation) do
    assert [entry] = Enum.filter(entries, &(&1.organisation_id == organisation.id))
    entry
  end

  @doc """
  old!/1 makes an entry of `organisation` older than the trail keeps it, its creation's, a
  year and a day back, and returns it.
  """
  @spec old!(%{id: Ecto.UUID.t()}) :: Entry.t()
  def old!(organisation) do
    %Entry{} =
      entry =
      Repo.one!(
        from e in Entry,
          where: e.organisation_id == ^organisation.id,
          order_by: [asc: e.inserted_at, asc: e.id],
          limit: 1
      )

    at = DateTime.add(DateTime.utc_now(), -366 * 86_400, :second)

    Repo.query!("UPDATE audit_entries SET inserted_at = $1 WHERE id = $2", [
      at,
      Ecto.UUID.dump!(entry.id)
    ])

    entry
  end

  @doc "organisation_id/1 is the id of the scope's organisation."
  @spec organisation_id(Scope.t()) :: Ecto.UUID.t()
  def organisation_id(%Scope{organisation: %{id: id}}), do: id

  @doc """
  refute_personal/2 asserts that no email address of any account, nor its local part,
  which a name made from it would carry, and not `secret`, when given, is anywhere in what
  the entry keeps: its `before`, `after` and `details`.
  """
  @spec refute_personal(Entry.t(), String.t() | nil) :: :ok
  def refute_personal(%Entry{} = entry, secret) do
    kept = Jason.encode!([entry.before, entry.after, entry.details])

    for email <- Repo.all(from u in User, where: not is_nil(u.email), select: u.email),
        text <- [email, email |> String.split("@") |> hd()] do
      refute kept =~ text, "the entry keeps #{text}"
    end

    refute kept =~ "@", "the entry keeps something like an email address: #{kept}"
    if secret, do: refute(kept =~ secret, "the entry keeps the secret")
    :ok
  end
end
