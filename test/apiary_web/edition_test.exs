defmodule ApiaryWeb.EditionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Apiary.Organisations.{Organisation, Workspace}
  alias ApiaryWeb.Edition
  alias ApiaryWeb.Nav.Entry

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
    assert core.who_may_sentence(:"node.create", nil) == nil
    assert core.settings_tabs(nil) == []
    assert core.slot(:notices, %{}) == nil
    assert core.activity_describer() == nil
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
end
