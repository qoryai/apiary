defmodule Apiary.Races do
  @moduledoc """
  Helpers for the tests that race two changes on connections of their own, outside the
  SQL sandbox (`docs/conventions.md`, Tests): each side commits, and each waits on the
  other's locks as it would in production.

  What such a test commits is visible to every other test, so its module is not async,
  says `setup_all :clean_up_leftovers` and `setup :setup_races`, and makes its
  organisations and people with `sign_up/0` and `member/2`, which remember them for
  `on_exit` to delete. Their addresses end in `@races.test` and their organisations'
  names start with "Races ", so what a run that was stopped half way left
  behind is found and deleted by the next.

  The order of the two sides is forced, not hoped for: `hold/1` runs the first side and
  keeps its transaction open with what it locked, `start/1` starts the second, and
  `await_blocked/2` waits, in the database, until the second waits on a lock the first
  holds (`pg_blocking_pids`); `commit/1` lets the first go. A side paused half way runs
  its second half with `continue/2`, once the other waits on it, inside the same
  transaction: what a deadlock needs, each side waiting on the other.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query

  alias Apiary.{Organisations, OrganisationsFixtures, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Deletion.PurgedOrganisation
  alias Apiary.Organisations.{Membership, Organisation}
  alias Ecto.Adapters.SQL.Sandbox

  @domain "races.test"
  @name "Races "

  # How long a side may take, and how long the second may take to wait on the first.
  @timeout 10_000
  @blocked_ms 5_000

  @doc "Deletes what a stopped run left behind: for `setup_all`."
  def clean_up_leftovers(_context) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    Repo.delete_all(from o in Organisation, where: like(o.name, ^"#{@name}%"))
    users = Repo.all(from u in User, where: like(u.email, ^"%@#{@domain}"), select: u.id)
    :ok = Apiary.EditionKit.forget_accounts(users)
    Repo.delete_all(from u in User, where: u.id in ^users)
    Sandbox.checkin(Repo)
    :ok
  end

  @doc "Checks the test's connection out outside the sandbox, and deletes on exit what it made: for `setup`."
  def setup_races(_context) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    {:ok, created} = Agent.start(fn -> %{organisations: [], users: []} end)
    Process.put(__MODULE__, created)
    on_exit(fn -> clean_up(created) end)
    :ok
  end

  @doc "A fresh owner of a fresh organisation, as `Apiary.OrganisationsFixtures.sign_up_fixture/1` makes them."
  def sign_up do
    OrganisationsFixtures.sign_up_fixture(%{email: email(), organisation_name: @name <> unique()})
    |> created()
  end

  @doc """
  A person who joined the owner's workspace through an invitation, and was then given
  `level` by the owner: the fixture, its membership and its scope at that level.
  """
  def member(%Scope{} = owner, level \\ :member) do
    email = email()
    %{token: token} = OrganisationsFixtures.invitation_fixture(owner, %{"email" => email})

    %{user: user, membership: membership} =
      fixture =
      created(OrganisationsFixtures.sign_up_fixture(%{email: email, invitation_token: token}))

    if level != :member,
      do: {:ok, _} = Organisations.set_member_level(owner, membership.id, level)

    %{
      fixture
      | membership: Repo.get!(Membership, membership.id),
        scope: OrganisationsFixtures.workspace_scope(user, owner.workspace)
    }
  end

  @doc """
  email/0 is a fresh address of a race's, which `clean_up_leftovers/1` finds; name/1 is a
  name of a race's organisation, `what` and a number after the races' prefix.
  """
  @spec email() :: String.t()
  def email, do: "user#{unique()}@#{@domain}"

  @doc false
  @spec name(String.t()) :: String.t()
  def name(what), do: @name <> what <> " " <> unique()

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  @doc """
  created/1 remembers what a fixture made, its organisation and its person, for `on_exit`
  to delete; the fixture.
  """
  @spec created(map) :: map
  def created(%{organisation: organisation, user: user} = fixture) do
    Agent.update(Process.get(__MODULE__), fn %{organisations: organisations, users: users} ->
      %{organisations: [organisation.id | organisations], users: [user.id | users]}
    end)

    fixture
  end

  # The organisations first, which take their rows with them, then what the edition keeps
  # of the accounts (`Apiary.EditionKit.forget_accounts/1`), then the accounts.
  defp clean_up(created) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    %{organisations: organisations, users: users} = Agent.get(created, & &1)
    Agent.stop(created)

    Repo.delete_all(from o in Organisation, where: o.id in ^organisations)
    Repo.delete_all(from p in PurgedOrganisation, where: p.id in ^organisations)
    :ok = Apiary.EditionKit.forget_accounts(users)
    Repo.delete_all(from u in User, where: u.id in ^users)
  end

  @doc """
  Runs `fun` in a transaction on a connection of its own and holds the transaction open,
  with what `fun` locked, until `commit/1`: `{held, backend_pid}`, `held.result` what
  `fun` answered.
  """
  def hold(fun) do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

        Repo.transaction(fn ->
          send(parent, {:held, self(), backend, fun.()})
          held_loop()
        end)
      end)

    receive do
      {:held, pid, backend, result} -> {%{task: task, pid: pid, result: result}, backend}
    after
      @timeout -> flunk("the first side did not finish its change")
    end
  end

  # The held transaction waits for more of its own steps (`continue/2`), or its commit.
  defp held_loop do
    receive do
      {:continue, fun, from} ->
        send(from, {:continued, self(), fun.()})
        held_loop()

      :commit ->
        :ok
    end
  end

  @doc """
  Runs `fun` inside the transaction `hold/1` holds, after what it did, and answers what
  `fun` answered: for a side paused half way, whose second half runs once the other side
  waits on it. The transaction stays open until `commit/1`.
  """
  def continue(%{pid: pid}, fun) do
    send(pid, {:continue, fun, self()})

    receive do
      {:continued, ^pid, result} -> result
    after
      @timeout -> flunk("the held side did not finish its next step")
    end
  end

  @doc "Commits what `hold/1` holds."
  def commit(%{task: task, pid: pid}) do
    send(pid, :commit)
    assert {:ok, :ok} = Task.await(task, @timeout)
  end

  @doc """
  Runs `fun` on a connection of its own: `%{task: task, backend: backend_pid}`, the
  backend known before `fun` starts.
  """
  def start(fun) do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:backend, self(), backend})
        fun.()
      end)

    receive do
      {:backend, _pid, backend} -> %{task: task, backend: backend}
    after
      @timeout -> flunk("the second side did not start")
    end
  end

  @doc """
  Waits, in the database, until the backend `waiter` waits on a lock `holder` holds; five
  seconds at most, which fails the test.
  """
  def await_blocked(waiter, holder) when is_integer(waiter) and is_integer(holder) do
    Repo.query!("""
    DO $$
    BEGIN
      FOR i IN 1..#{div(@blocked_ms, 10)} LOOP
        IF #{holder} = ANY (pg_blocking_pids(#{waiter})) THEN
          RETURN;
        END IF;
        PERFORM pg_sleep(0.01);
      END LOOP;
      RAISE EXCEPTION 'backend % did not wait on backend %', #{waiter}, #{holder};
    END
    $$
    """)
  end

  @doc "Runs the changes, each on a connection of its own, let go at once: their answers, in order."
  def together(funs) do
    parent = self()

    tasks =
      Enum.map(funs, fn fun ->
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, self()})

          receive do
            :go -> fun.()
          end
        end)
      end)

    for %Task{pid: pid} <- tasks, do: assert_receive({:ready, ^pid}, @timeout)
    for %Task{pid: pid} <- tasks, do: send(pid, :go)
    Task.await_many(tasks, @timeout)
  end
end
