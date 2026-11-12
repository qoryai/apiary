defmodule ApiaryProWeb.MemberLive.OperatorOwnsLevelsTest do
  # The People page of a client while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`): Owner is offered nowhere, and a change
  # to owner sent all the same is refused before it is written, in the operator's words;
  # the invitation's description says the client's admins change the new member's level,
  # and Admin's hint says what an admin manages in a client, the other hints the core's;
  # with the flag off, as it was. The flag is set for this process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Features, Organisations, Repo}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  setup do
    Flags.put_operator_infrastructure(false)
    name = "Hive Ops #{System.unique_integer([:positive])}"
    operator = operator_fixture(%{organisation_name: name})
    client = client_fixture(operator.scope, "Acme")
    client_admin = client_member_fixture(client, :admin)
    client_member = client_member_fixture(client, :member)
    Flags.put_operator_infrastructure(true)

    %{
      operator: operator,
      operator_name: name,
      client: client,
      client_admin: client_admin,
      client_member: client_member
    }
  end

  defp people(user, organisation, suffix \\ "") do
    {:ok, lv, _html} =
      live(log_in_user(build_conn(), user), "/#{organisation.slug}/settings/people#{suffix}")

    lv
  end

  defp entries(organisation) do
    Repo.aggregate(
      from(e in Apiary.Audit.Entry, where: e.organisation_id == ^organisation.id),
      :count
    )
  end

  defp refused(ctx),
    do:
      "Nobody in Acme is made an owner: #{ctx.operator_name}, its operator, owns it."
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

  defp text_of(lv, selector),
    do:
      lv
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

  # The Invite people form's description, with mail and without, read by the client's
  # admin.
  defp invite_descriptions(ctx) do
    for source <- [:env, :none] do
      Apiary.Mail.put_test_source(source)
      lv = people(ctx.client_admin.user, ctx.client.organisation, "/invite")
      text_of(lv, "#invite .q-page-desc")
    end
  end

  # Each level's hint on the People page of the client, read by `reader`, who changes
  # levels there: of the client's owner made before the flag, and of its member.
  defp level_hints(ctx, reader) do
    lv = people(reader, ctx.client.organisation)

    for membership <- [ctx.client.owner.membership, ctx.client_member.membership] do
      for level <- [:owner, :admin, :member],
          has_element?(lv, "#member-#{membership.id}-level-#{level}"),
          do: {level, text_of(lv, "#member-#{membership.id}-level-#{level} .q-mi-t > span")}
    end
  end

  @member_hint "Sees the runs and changes the policy's unlocked rules"

  describe "while the operator owns its clients" do
    test "Owner is not offered, to the operator's owner or the client's", ctx do
      admin = ctx.client_admin.membership

      for user <- [ctx.operator.user, ctx.client.owner.user] do
        lv = people(user, ctx.client.organisation)
        assert has_element?(lv, "#member-#{admin.id}-level-admin")
        assert has_element?(lv, "#member-#{admin.id}-level-member")
        refute has_element?(lv, "#member-#{admin.id}-level-owner")
      end

      # The levels the page offers, and the invitation's form, which offers no level.
      assert Access.grantable_levels(ctx.client.scope) == [:admin, :member]
      assert Access.grantable_levels(ctx.client.owner.scope) == [:admin, :member]

      lv = people(ctx.operator.user, ctx.client.organisation, "/invite")
      assert has_element?(lv, "#invite")
      refute has_element?(lv, "#invite [value='owner']")
    end

    test "the invitation's description says the client's admins change the level", ctx do
      workspace = ctx.client.workspace.name

      assert invite_descriptions(ctx) == [
               "We email them a link that works for seven days and brings them into #{workspace} as a member; Acme's admins can change their level afterwards.",
               "You get a link to send them yourself. It works for seven days and brings them into #{workspace} as a member; Acme's admins can change their level afterwards."
             ]
    end

    test "Admin's hint says what an admin manages in a client, and the others are the core's",
         ctx do
      assert level_hints(ctx, ctx.operator.user) == [
               [
                 owner: "Changes everything, including who owns the organisation",
                 admin: "Manages members and settings",
                 member: @member_hint
               ],
               [admin: "Manages members and settings", member: @member_hint]
             ]

      # The edition answers nil, for the core's words, in the operator, which is no client, and
      # in a client for Owner's and Member's hints.
      bindings = %{workspace: "Main", organisation: ctx.operator_name}
      abouts = [:invite_by_mail, :invite_by_link, {:level_hint, :admin}]

      operator =
        Enum.map(abouts, &ApiaryProWeb.Edition.people_sentence(&1, ctx.operator.scope, bindings))

      assert operator == [nil, nil, nil]

      hints = for level <- [:owner, :member], do: {:level_hint, level}

      assert Enum.map(hints, &ApiaryProWeb.Edition.people_sentence(&1, ctx.client.scope, %{})) ==
               [nil, nil]
    end

    test "a change to owner sent all the same is refused before it is written", ctx do
      member = ctx.client_member.membership
      before = entries(ctx.client.organisation)

      for user <- [ctx.operator.user, ctx.client.owner.user] do
        lv = people(user, ctx.client.organisation)

        render_click(lv, "set_level", %{"membership_id" => member.id, "level" => "owner"})
        assert render(lv) =~ refused(ctx)
      end

      assert Repo.reload!(member).level == :member
      assert entries(ctx.client.organisation) == before

      for scope <- [ctx.client.scope, ctx.client.owner.scope] do
        assert Organisations.set_member_level(scope, member.id, :owner) ==
                 {:error, {:level_refused, :operator_owns}}
      end
    end

    test "the edition's rollback still refuses an owner made past the refusal", ctx do
      member = ctx.client_member.membership

      assert ApiaryPro.Edition.membership_changed(
               Repo,
               ctx.client.scope,
               :level,
               member,
               %{member | level: :owner}
             ) == {:error, :forbidden}
    end

    test "owner is refused in a client alone: the operator makes its own owners", ctx do
      assert Access.level_refusal(ctx.client.scope, ctx.client.organisation, :owner) ==
               :operator_owns

      assert Access.level_refusal(ctx.client.scope, ctx.client.organisation, :admin) == nil
      assert Access.level_refusal(ctx.operator.scope, ctx.operator.organisation, :owner) == nil
      assert Access.grantable_levels(ctx.operator.scope) == [:owner, :admin, :member]
      assert ApiaryProWeb.Edition.level_refusal_sentence(:other, ctx.client.scope) == nil
    end
  end

  describe "with the flag off" do
    setup do: Flags.put_operator_infrastructure(false)

    test "the invitation's description and the levels' hints are the core's", ctx do
      workspace = ctx.client.workspace.name

      assert invite_descriptions(ctx) == [
               "We email them a link that works for seven days and brings them into #{workspace} as a member; an owner can change their level afterwards.",
               "You get a link to send them yourself. It works for seven days and brings them into #{workspace} as a member; an owner can change their level afterwards."
             ]

      admin = "Manages members, workspaces, machines and settings"
      owner = "Changes everything, including who owns the organisation"

      assert level_hints(ctx, ctx.client.owner.user) == [
               [owner: owner, admin: admin, member: @member_hint],
               [owner: owner, admin: admin, member: @member_hint]
             ]
    end

    test "Owner is offered, and the client's owner makes owners", ctx do
      member = ctx.client_member.membership
      lv = people(ctx.client.owner.user, ctx.client.organisation)
      assert has_element?(lv, "#member-#{member.id}-level-owner")

      assert Access.level_refusal(ctx.client.owner.scope, ctx.client.organisation, :owner) ==
               nil

      assert ApiaryProWeb.Edition.level_refusal_sentence(:operator_owns, ctx.client.scope) ==
               nil

      render_click(lv, "set_level", %{"membership_id" => member.id, "level" => "owner"})
      assert Repo.reload!(member).level == :owner
    end
  end
end
