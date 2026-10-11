defmodule ApiaryWeb.EditionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias ApiaryWeb.Activity.Actor
  alias ApiaryWeb.Edition
  alias ApiaryWeb.Nav.Entry

  # An edition that says who made an entry with how they reached the organisation, from the
  # details its audit edition wrote, and leaves the rest to the core.
  defmodule Through do
    use Phoenix.Component

    def activity_actor(%{details: %{"reached_through_id" => id}}, assigns) do
      assigns = assign(assigns, :through, assigns.names.organisations[id])

      ~H"""
      <span class="through">{@actor.text} of {@through}</span>
      """
    end

    def activity_actor(_entry, _assigns), do: nil
  end

  test "the core's web edition adds nothing" do
    core = Edition.Core

    assert core.nav_entries(nil) == []
    assert core.nav_counts(nil) == %{}
    assert core.new_entries(nil, :organisation) == []
    assert core.switcher_entries(nil) == []
    assert core.account_menu_entries(nil) == []
    assert core.instance_sections(nil) == []
    assert core.place_scope(%Apiary.Organisations.Membership{}, %Workspace{}) == nil
    assert core.reader_sentence(:level, nil) == nil
    assert core.reader_sentence(:refused, nil) == nil
    assert core.settings_tabs(nil) == []
    assert core.slot(:notices, %{}) == nil
    assert core.activity_describer() == nil
    assert core.activity_actor(%Apiary.Audit.Entry{}, %{}) == nil
    assert core.above_policy_link(nil) == nil
    assert core.reserved_slugs() == %{}
    assert core.product_name() == "Qory Apiary"
    assert core.gettext_backend() == nil
  end

  test "an entry leads to its path, or where its function says" do
    organisation = %Organisation{slug: "acme"}
    workspace = %Workspace{slug: "main"}

    assert Entry.path(%Entry{key: :new, label: "New", path: "/somewhere"}, nil, nil) ==
             "/somewhere"

    runs = %Entry{key: :runs, label: "Runs", path: &"/#{&1.slug}/#{&2.slug}/runs"}
    assert Entry.path(runs, organisation, workspace) == "/acme/main/runs"
  end

  describe "a slot" do
    test "renders nothing where the edition leaves it empty" do
      assert render_component(&ApiaryWeb.Extension.slot/1, name: :activity_toolbar, scope: nil) ==
               ""
    end

    test "is one of the core's names" do
      assert :notices in ApiaryWeb.Extension.names()
      assert :workspaces_heading in ApiaryWeb.Extension.names()
      assert :organisation_heading in ApiaryWeb.Extension.names()

      assert_raise ArgumentError, ~r/no slot :nowhere/, fn ->
        render_component(&ApiaryWeb.Extension.slot/1, name: :nowhere, scope: nil)
      end
    end
  end

  describe "who made an entry" do
    setup do
      person = Ecto.UUID.generate()
      through = Ecto.UUID.generate()

      names = %{
        users: %{person => "dana@example.com"},
        access_keys: %{},
        nodes: %{},
        workspaces: %{},
        targets: %{},
        runs: %{},
        organisations: %{through => "Northwind"}
      }

      entry = %Apiary.Audit.Entry{id: Ecto.UUID.generate(), actor_kind: :person, actor_id: person}
      %{person: person, through: through, names: names, entry: entry}
    end

    test "is the core's words in the core", ctx do
      scope = %Scope{user: %User{id: ctx.person}}
      actor = Actor.of(ctx.entry, ctx.names, scope, Edition.Core)

      assert actor == %{
               words: %{kind: :person, text: "dana@example.com", you?: true},
               edition: nil
             }

      html = render_component(&Actor.actor/1, id: "who", actor: actor)
      assert html =~ ~s(id="who")
      assert html =~ "dana@example.com"
      assert html =~ "you"

      gone = %{ctx.entry | actor_id: Ecto.UUID.generate()}
      html = render_component(&Actor.actor/1, id: "who", actor: Actor.of(gone, ctx.names, scope))
      assert html =~ "Former member"

      instance = %{ctx.entry | actor_kind: :instance, actor_id: nil}

      html =
        render_component(&Actor.actor/1, id: "who", actor: Actor.of(instance, ctx.names, scope))

      assert html =~ "Qory Apiary"
    end

    test "is the edition's where it says it, and the core's where it says nil", ctx do
      scope = %Scope{}
      reached = %{ctx.entry | details: %{"reached_through_id" => ctx.through}}

      actor = Actor.of(reached, ctx.names, scope, Through)
      assert actor.words == %{kind: :person, text: "dana@example.com", you?: nil}

      html = render_component(&Actor.actor/1, id: "who", actor: actor)
      assert html =~ ~s(id="who")
      assert html =~ ~r{<span[^>]* class="through">dana@example.com of Northwind</span>}

      html =
        render_component(&Actor.actor/1,
          id: "who",
          actor: Actor.of(ctx.entry, ctx.names, scope, Through)
        )

      assert html =~ "dana@example.com"
      refute html =~ "Northwind"
    end
  end
end
