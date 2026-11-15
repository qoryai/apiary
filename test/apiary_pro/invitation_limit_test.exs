defmodule ApiaryPro.InvitationLimitTest do
  @moduledoc """
  An operator and its clients under `INVITATIONS_PER_DAY` (the core's limit,
  `Apiary.InvitationLimitTest`): a client counts its invitations as any other
  organisation, apart from its operator's.
  """
  # Not async: the limit is the node's setting.
  use Apiary.DataCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  import Apiary.AccountsFixtures
  import Ecto.Query

  alias Apiary.Organisations
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Invitation
  alias ApiaryPro.OperatorsFixtures

  @limit 3

  setup do
    previous = Application.fetch_env!(:apiary, :invitations_per_day)
    Application.put_env(:apiary, :invitations_per_day, @limit)
    on_exit(fn -> Application.put_env(:apiary, :invitations_per_day, previous) end)
    :ok
  end

  defp invite(scope),
    do: Organisations.invite_member(scope, %{"email" => unique_user_email()}, & &1)

  defp refused_for_the_day?({:error, %Ecto.Changeset{} = changeset}, organisation) do
    errors_on(changeset).email == [
      "was not invited: #{organisation.name} sent as many invitations in the last 24 hours as it may. Try again later, or contact support."
    ]
  end

  defp refused_for_the_day?(_result, _organisation), do: false

  describe "an operator and its clients" do
    # Each organisation has a separate allowance, a client as any other.
    @describetag with_features: Apiary.Features.all()

    test "each client has a separate allowance, apart from its operator's" do
      operator = OperatorsFixtures.operator_fixture()
      first = OperatorsFixtures.client_fixture(operator.scope, "First")
      second = OperatorsFixtures.client_fixture(operator.scope, "Second")

      for client <- [first, second] do
        for _ <- 1..@limit, do: assert({:ok, %Invitation{}} = invite(client.owner.scope))
        assert refused_for_the_day?(invite(client.owner.scope), client.organisation)
      end

      # The operator's day is untouched by its clients' invitations.
      for _ <- 1..@limit, do: assert({:ok, %Invitation{}} = invite(operator.scope))
      assert refused_for_the_day?(invite(operator.scope), operator.organisation)

      allowances =
        Repo.all(
          from e in Entry,
            where: e.organisation_id == ^first.organisation.id,
            where: e.action == "member.invite",
            select: fragment("?->>'allowance_id'", e.details)
        )

      assert first.organisation.id in allowances
    end

    test "a client's attempts count against the client's ceiling, not its operator's" do
      operator = OperatorsFixtures.operator_fixture()
      client = OperatorsFixtures.client_fixture(operator.scope)
      owner = client.owner.scope

      # Attempts beyond the allowance: entries of invitations withdrawn as undelivered,
      # which count against the ceiling alone.
      for _ <- 1..(@limit * 3) do
        {:ok, invitation} = invite(owner)
        {:ok, _} = Organisations.revoke_invitation(owner, invitation.id)

        Repo.update_all(
          from(e in Entry,
            where: e.subject_id == ^invitation.id and e.action == "invitation.revoke"
          ),
          set: [details: %{"reason" => "undelivered"}, workspace_id: client.workspace.id]
        )
      end

      assert {:error, %Ecto.Changeset{} = changeset} = invite(owner)

      assert errors_on(changeset).email == [
               "was not invited: #{client.organisation.name} sent as many invitations in the last 24 hours as it may. Try again later, or contact support."
             ]

      assert {:ok, %Invitation{}} = invite(operator.scope)
    end
  end
end
