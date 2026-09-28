defmodule Apiary.SignUpRacesTest do
  # Two sign-ups, or two invitations, at once, each on a connection of its own and outside
  # the SQL sandbox, so that each commits and each waits on the other's locks as it would
  # in production. Not async: what these tests commit is visible to every other test while
  # they run, the instance's organisation hidden included (`Apiary.EditionKit`), and they
  # put it all back before they end.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.AccountsFixtures, only: [unique_user_email: 0, unique_organisation_name: 0]
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.User
  alias Apiary.Organisations.{Invitation, Organisation}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    suite_organisation = ensure_instance_organisation!()
    {:ok, created} = Agent.start(fn -> %{organisations: [], users: []} end)
    Process.put(:created, created)
    on_exit(fn -> clean_up(created, suite_organisation) end)
    %{suite_organisation: suite_organisation}
  end

  test "of two first sign-ups at once, exactly one creates the instance's organisation", ctx do
    for {open, other} <- [{false, :refused}, {true, :later}] do
      # The instance before its first sign-up, as every connection sees it.
      Apiary.EditionKit.hide_instance_organisation()

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

            Organisations.sign_up_user(
              %{email: unique_user_email(), organisation_name: unique_organisation_name()},
              nil,
              open: open
            )
          end)
        end)
        |> Task.await_many(10_000)

      for {:ok, signed_up} <- results, do: created(signed_up)

      first = Apiary.Edition.instance_organisation_id()
      assert Enum.count(results, &match?({:ok, %{organisation: %{id: ^first}}}, &1)) == 1

      case other do
        :refused ->
          assert [{:error, changeset}] = Enum.filter(results, &match?({:error, _}, &1))
          assert changeset.errors[:email]

        :later ->
          assert [%Organisation{}] =
                   for({:ok, %{organisation: %{id: id} = o}} <- results, id != first, do: o)
      end

      # This round's first organisation goes, and the suite's is the instance's again.
      Repo.delete_all(from o in Organisation, where: o.id == ^first)
      Apiary.EditionKit.show_instance_organisation(ctx.suite_organisation.id)
    end
  end

  test "of the release command's claim and a web first sign-up at once, exactly one is first",
       ctx do
    for round <- 1..4 do
      Apiary.EditionKit.hide_instance_organisation()

      claim_email = "claim-#{round}-#{System.unique_integer([:positive])}@example.com"
      web_email = unique_user_email()

      [claim, web] =
        [
          fn ->
            ExUnit.CaptureIO.with_io(fn ->
              Apiary.Release.grant_instance_admin(claim_email, "Claimed")
            end)
            |> elem(0)
          end,
          fn ->
            Organisations.sign_up_user(
              %{email: web_email, organisation_name: unique_organisation_name()},
              nil,
              open: false
            )
          end
        ]
        |> Enum.map(fn fun ->
          Task.async(fn ->
            :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
            fun.()
          end)
        end)
        |> Task.await_many(10_000)

      claimed = Apiary.Accounts.get_user_by_email(claim_email)
      web_user = Apiary.Accounts.get_user_by_email(web_email)
      for user <- [claimed, web_user], user, do: created_user(user)
      for {:ok, signed_up} <- [web], do: created(signed_up)

      first = Repo.get!(Organisation, Apiary.Edition.instance_organisation_id())
      created_organisation(first)

      case {claim, web} do
        # The command was first: the web sign-up is a later one, refused while closed.
        {{:ok, :created}, {:error, %Ecto.Changeset{}}} ->
          assert first.name == "Claimed"
          refute web_user

        # The web was first: the command grants as on any instance, and the account it
        # names does not exist.
        {{:error, :not_found}, {:ok, %{organisation: %{id: id}}}} when id == first.id ->
          refute claimed

        other ->
          flunk("both or neither were first: #{inspect(other)}")
      end

      Repo.delete_all(from o in Organisation, where: o.id == ^first.id)
      Apiary.EditionKit.show_instance_organisation(ctx.suite_organisation.id)
    end
  end

  test "of two invitations at once where one is left of the day's, exactly one is sent" do
    previous = Application.fetch_env!(:apiary, :invitations_per_day)
    Application.put_env(:apiary, :invitations_per_day, 2)
    on_exit(fn -> Application.put_env(:apiary, :invitations_per_day, previous) end)

    %{scope: scope} = created(sign_up_fixture())
    invitation_fixture(scope)

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          Organisations.invite_member(scope, %{"email" => unique_user_email()}, & &1)
        end)
      end)
      |> Task.await_many(10_000)

    assert [{:ok, %Invitation{}}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, %Ecto.Changeset{} = changeset}] =
             Enum.filter(results, &match?({:error, _}, &1))

    assert [message] = Keyword.get_values(changeset.errors, :email) |> Enum.map(&elem(&1, 0))
    assert message =~ "as many as it may"

    assert 2 ==
             Repo.aggregate(
               from(i in Invitation, where: i.organisation_id == ^scope.organisation.id),
               :count
             )
  end

  defp created(%{organisation: organisation, user: user} = fixture) do
    Agent.update(Process.get(:created), fn %{organisations: organisations, users: users} ->
      %{organisations: [organisation.id | organisations], users: [user.id | users]}
    end)

    fixture
  end

  defp created_user(user) do
    Agent.update(Process.get(:created), &%{&1 | users: [user.id | &1.users]})
  end

  defp created_organisation(organisation) do
    Agent.update(
      Process.get(:created),
      &%{&1 | organisations: [organisation.id | &1.organisations]}
    )
  end

  # The organisations first, which take their rows with them, then the accounts; and the
  # suite's organisation is the instance's again, whatever a test left.
  defp clean_up(created, suite_organisation) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    %{organisations: organisations, users: users} = Agent.get(created, & &1)
    Agent.stop(created)

    Repo.delete_all(from o in Organisation, where: o.id in ^organisations)
    Repo.delete_all(from u in User, where: u.id in ^users)

    if Apiary.Edition.instance_organisation_id() != suite_organisation.id do
      Apiary.EditionKit.show_instance_organisation(suite_organisation.id)
    end
  end
end
