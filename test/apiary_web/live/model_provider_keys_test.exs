defmodule ApiaryWeb.ModelProviderKeysTest do
  # Organisation settings › Model provider keys (`ApiaryWeb.ProviderLive.Index`): one row
  # per key with its provider, its workspaces and its state; New model provider key with
  # Workspaces where the organisation has several; Remove with its confirmation in the row;
  # the paths of the provider's page and of Add key, which are gone, open the list.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelChoicesFixtures, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.Secrets.{Secret, Value}

  @moduletag needs: [:factory, :secrets]

  @key "sk-ant-keys-page-0123456789abcdef"

  setup :register_and_log_in_user

  defp list_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers"
  defp new_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers/new"

  defp add!(scope, reach) do
    {:ok, provider, value_id} =
      Connections.add_key(
        scope,
        Map.merge(%{"provider" => "claude-subscription", "value" => @key}, reach)
      )

    {provider, row(provider, value_id)}
  end

  defp every, do: %{"applies_to" => "all"}

  defp only(workspaces),
    do: %{"applies_to" => "selected", "workspace_ids" => Enum.map(workspaces, & &1.id)}

  defp row(provider, value_id),
    do: Repo.get_by!(Value, secret_id: provider.secret_id, value_id: value_id).id

  defp member_conn(scope, level) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  # The text of the element `selector` selects, its whitespace collapsed.
  defp text(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # Northwind's case: a key for every workspace and a key for Checkout, the scope's
  # workspace; Storefront beside it.
  defp northwind(scope) do
    storefront = workspace_fixture(scope.organisation, "Storefront")
    {every, first} = add!(scope, every())
    {checkout, second} = add!(scope, only([scope.workspace]))
    %{storefront: storefront, every: every, checkout: checkout, first: first, second: second}
  end

  describe "the list" do
    test "has one row per key: Key, Provider, Workspaces, State, Edit and Remove", ctx do
      %{conn: conn, scope: scope} = ctx
      nw = northwind(scope)

      {:ok, lv, html} = live(conn, list_path(scope))

      assert has_element?(lv, "h1", "Model provider keys")
      assert page_title(lv) =~ "Model provider keys · Organisation settings"
      assert has_element?(lv, "#settings-tab-model_providers", "Model provider keys")

      assert has_element?(
               lv,
               ~s{a#new-model-provider[href="#{new_path(scope)}"]},
               "New model provider key"
             )

      assert text(lv, "#key-#{nw.first}-name") == "key-1"
      assert text(lv, "#key-#{nw.first}-provider") == "Claude subscription token"
      assert text(lv, "#key-#{nw.first}-workspaces") == "Every workspace"
      assert text(lv, "#key-#{nw.first}-state") == "Available"
      assert text(lv, "#key-#{nw.second}-name") == "key-2"
      assert text(lv, "#key-#{nw.second}-workspaces") == scope.workspace.name

      edit =
        "#{list_path(scope)}/#{nw.checkout.public_id}/keys/#{nw.second}/edit"

      assert has_element?(lv, ~s{a#key-#{nw.second}-name[href="#{edit}"]})
      assert has_element?(lv, ~s{a#key-#{nw.second}-edit[href="#{edit}"]}, "Edit")
      assert has_element?(lv, "button#key-#{nw.second}-remove", "Remove")

      # The rows in the order the keys were added.
      assert Regex.scan(~r/id="key-([0-9a-f-]{36})"/, html, capture: :all_but_first) ==
               [[nw.first], [nw.second]]

      refute html =~ @key
    end

    test "where the table is narrow, a row has the key and its state, then the provider and the workspaces",
         ctx do
      %{conn: conn, scope: scope} = ctx
      nw = northwind(scope)

      {:ok, lv, _html} = live(conn, list_path(scope))

      row = "#key-#{nw.second}"
      assert has_element?(lv, "#{row} .q-to-sm #{row}-narrow-state", "Available")

      assert has_element?(
               lv,
               "#{row} div.q-to-sm",
               "Claude subscription token · #{scope.workspace.name}"
             )

      assert has_element?(lv, "#{row} .q-to-sm #{row}-narrow-edit", "Edit")
      assert has_element?(lv, "#{row} .q-to-sm #{row}-narrow-remove", "Remove")

      for column <- ~w(provider workspaces state) do
        assert has_element?(lv, "#{row} td.q-from-sm ##{"key-#{nw.second}"}-#{column}")
      end
    end

    test "shows up to three workspaces, then the first two and how many more", ctx do
      %{conn: conn, scope: scope} = ctx

      [b, c, d, e] =
        for name <- ~w(Billing Catalog Docs Events),
            do: workspace_fixture(scope.organisation, name)

      {_three, three} = add!(scope, only([scope.workspace, b, c]))
      {five_provider, five} = add!(scope, only([scope.workspace, b, c, d, e]))

      {:ok, lv, _html} = live(conn, list_path(scope))

      names = Enum.sort_by([scope.workspace.name, "Billing", "Catalog"], &String.downcase/1)
      assert text(lv, "#key-#{three}-workspaces") == Enum.join(names, ", ")

      [first, second | _] =
        Enum.sort_by([scope.workspace.name | ~w(Billing Catalog Docs Events)], &String.downcase/1)

      assert text(lv, "#key-#{five}-workspaces") == "#{first}, #{second} and 3 more"

      # Edit key has the same words.
      {:ok, edit, _html} =
        live(conn, "#{list_path(scope)}/#{five_provider.public_id}/keys/#{five}/edit")

      assert text(edit, "#key-workspaces-names") == "#{first}, #{second} and 3 more"
    end

    test "with none, shows how to start", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, list_path(scope))

      assert has_element?(lv, "h2, h3, p", "No model provider key yet")
      assert has_element?(lv, "#providers-none", "Add a model provider key, so agents can run.")
    end

    test "a member reads the keys without New, Edit and Remove", ctx do
      %{scope: scope} = ctx
      nw = northwind(scope)
      conn = member_conn(scope, :member)

      {:ok, lv, _html} = live(conn, list_path(scope))

      assert text(lv, "#key-#{nw.first}-name") == "key-1"
      refute has_element?(lv, "#new-model-provider")
      refute has_element?(lv, "#key-#{nw.first}-edit")
      refute has_element?(lv, "#key-#{nw.first}-remove")
      assert has_element?(lv, "#providers-who", "Only owners and admins add model provider keys.")
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, new_path(scope)) end
    end

    test "a member's create and remove_key events, sent by hand, change nothing", ctx do
      %{scope: scope} = ctx
      nw = northwind(scope)
      {:ok, lv, _html} = live(member_conn(scope, :member), list_path(scope))

      render_hook(lv, "create", %{
        "provider" => %{"provider" => "claude-subscription", "key" => @key, "reach" => "all"}
      })

      render_hook(lv, "remove_key", %{"id" => nw.first})

      assert {:ok, [_, _]} = Connections.list_providers(scope)
      assert Repo.get_by(Value, id: nw.first)

      assert Repo.aggregate(from(v in Value, where: v.secret_id == ^nw.every.secret_id), :count) ==
               1
    end

    test "the paths of a provider's page and of its Add key open the list", ctx do
      %{conn: conn, scope: scope} = ctx
      {provider, _row} = add!(scope, every())
      list = list_path(scope)

      for path <- ["#{list}/#{provider.public_id}", "#{list}/#{provider.public_id}/keys/new"] do
        assert {:error, {:live_redirect, %{to: ^list}}} = live(conn, path)
      end
    end
  end

  describe "New model provider key" do
    test "with one workspace, has no Workspaces, and adds the key for that workspace", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(lv, "h1", "New model provider key")
      assert has_element?(lv, "#new-provider-form")
      refute has_element?(lv, "#new-provider-workspaces")
      assert render(lv) =~ "About model provider keys"

      for id <- ~w(reset_day pause_number),
          do: assert(has_element?(lv, "#provider_#{id}"))

      {:ok, list, _html} =
        lv
        |> form("#new-provider-form",
          provider: %{
            provider: "claude-subscription",
            key: @key,
            pause_number: "2",
            pause_unit: "hours"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, list_path(scope))

      assert render(list) =~ "key-1 is added."

      assert {:ok, [provider]} = Connections.list_providers(scope)
      assert Connections.workspace_ids_of(provider) == [scope.workspace.id]
      assert Repo.get!(Secret, provider.secret_id).workspace_id == scope.workspace.id
      assert Apiary.ModelKeys.setting(row(provider, "key-1")).pause_seconds == 7200
    end

    test "with several workspaces, has Workspaces, this workspace ticked", ctx do
      %{conn: conn, scope: scope} = ctx
      storefront = workspace_fixture(scope.organisation, "Storefront")
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(lv, "#new-provider-workspaces legend", "Workspaces")

      assert has_element?(
               lv,
               "#new-provider-workspaces label",
               "Every workspace in #{scope.organisation.name}"
             )

      assert has_element?(lv, "#new-provider-reach-selected[checked]")
      assert has_element?(lv, "#new-provider-workspaces label", "Only these workspaces")
      assert has_element?(lv, "#new-provider-workspace-#{scope.workspace.id}[checked]")
      assert has_element?(lv, "#new-provider-workspace-#{storefront.id}")
      refute has_element?(lv, "#new-provider-workspace-#{storefront.id}[checked]")
    end

    # A browser sends the workspaces a person has not touched as `_unused_workspace_ids`, a
    # list: the change of provider is read all the same.
    test "a change of provider with Workspaces untouched shows that provider", ctx do
      %{conn: conn, scope: scope} = ctx
      storefront = workspace_fixture(scope.organisation, "Storefront")
      {:ok, lv, _html} = live(conn, new_path(scope))

      lv
      |> element("#new-provider-form")
      |> render_change(%{
        "_target" => ["provider", "provider"],
        "provider" => %{
          "provider" => "claude-subscription",
          "reach" => "selected",
          "workspace_ids" => ["", scope.workspace.id],
          "_unused_workspace_ids" => ["", storefront.id]
        }
      })

      assert has_element?(lv, "#new-provider-get-key-command", "claude setup-token")
    end

    test "adds a key for the workspaces ticked, or for every workspace", ctx do
      %{conn: conn, scope: scope} = ctx
      storefront = workspace_fixture(scope.organisation, "Storefront")
      {:ok, lv, _html} = live(conn, new_path(scope))

      lv
      |> form("#new-provider-form",
        provider: %{
          provider: "claude-subscription",
          key: @key,
          reach: "selected",
          workspace_ids: [scope.workspace.id, storefront.id]
        }
      )
      |> render_submit()

      assert {:ok, [both]} = Connections.list_providers(scope)

      assert Enum.sort(Connections.workspace_ids_of(both)) ==
               Enum.sort([scope.workspace.id, storefront.id])

      {:ok, lv, _html} = live(conn, new_path(scope))

      {:ok, list, _html} =
        lv
        |> form("#new-provider-form",
          provider: %{provider: "claude-subscription", key: @key, reach: "all"}
        )
        |> render_submit()
        |> follow_redirect(conn, list_path(scope))

      assert render(list) =~ "key-2 is added."
      {:ok, providers} = Connections.list_providers(scope)
      assert Enum.any?(providers, &(&1.applies_to == "all"))
    end

    test "a Key of only whitespace and Resets half set show both errors, and add nothing",
         ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      lv
      |> form("#new-provider-form",
        provider: %{provider: "claude-subscription", key: "  ", reset_time: "09:00"}
      )
      |> render_submit()

      assert has_element?(lv, "#provider_reset_day-resets-error")
      assert has_element?(lv, "#new-provider-key-1-error", "can't be blank")
      assert {:ok, []} = Connections.list_providers(scope)
    end

    test "Only these workspaces with none ticked shows Choose at least one workspace, and adds nothing",
         ctx do
      %{conn: conn, scope: scope} = ctx
      workspace_fixture(scope.organisation, "Storefront")
      {:ok, lv, _html} = live(conn, new_path(scope))

      lv
      |> form("#new-provider-form",
        provider: %{
          provider: "claude-subscription",
          key: @key,
          reach: "selected",
          workspace_ids: []
        }
      )
      |> render_submit()

      assert has_element?(lv, "#new-provider-workspaces-error", "Choose at least one workspace.")
      assert {:ok, []} = Connections.list_providers(scope)
    end

    test "a key added to Northwind's case goes to the provider for every workspace as key-3",
         ctx do
      %{conn: conn, scope: scope} = ctx
      nw = northwind(scope)
      {:ok, lv, _html} = live(conn, new_path(scope))

      {:ok, lv, _html} =
        lv
        |> form("#new-provider-form",
          provider: %{provider: "claude-subscription", key: @key, reach: "all"}
        )
        |> render_submit()
        |> follow_redirect(conn, list_path(scope))

      assert render(lv) =~ "key-3 is added."
      third = row(nw.every, "key-3")
      assert text(lv, "#key-#{third}-workspaces") == "Every workspace"
      assert {:ok, [_, _]} = Connections.list_providers(scope)
    end
  end

  describe "Remove" do
    test "turns the row into its confirmation, and Cancel keeps the key", ctx do
      %{conn: conn, scope: scope} = ctx
      nw = northwind(scope)
      {:ok, lv, _html} = live(conn, list_path(scope))

      lv |> element("#key-#{nw.second}-remove") |> render_click()

      confirm = "#key-#{nw.second}-confirm"
      assert text(lv, "#{confirm}-question") == "Remove key-2?"
      assert text(lv, "#{confirm}-sub") == "Runs in #{scope.workspace.name} stop using it."
      assert has_element?(lv, "#key-#{nw.second}-remove-confirm", "Remove key")

      lv |> element("#{confirm}-cancel") |> render_click()
      refute has_element?(lv, confirm)
      assert has_element?(lv, "#key-#{nw.second}-name")
    end

    test "Remove key removes a key; the default key passes to another key", ctx do
      %{conn: conn, scope: scope} = ctx
      {provider, first} = add!(scope, every())
      {_provider, second} = add!(scope, every())
      {:ok, lv, _html} = live(conn, list_path(scope))

      lv |> element("#key-#{first}-remove") |> render_click()
      assert text(lv, "#key-#{first}-confirm-sub") == "Runs in every workspace stop using it."
      lv |> element("#key-#{first}-remove-confirm") |> render_click()

      refute has_element?(lv, "#key-#{first}-name")
      assert has_element?(lv, "#key-#{second}-name")
      assert Repo.get!(Connection, provider.id).default_value_id == "key-2"
    end

    test "the last key of a provider moves its model choice to another provider of the group",
         ctx do
      %{conn: conn, scope: scope} = ctx
      nw = northwind(scope)

      {:ok, choice} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{provider: nw.every.public_id})

      {:ok, lv, _html} = live(conn, list_path(scope))
      lv |> element("#key-#{nw.first}-remove") |> render_click()
      lv |> element("#key-#{nw.first}-remove-confirm") |> render_click()

      refute has_element?(lv, "#key-#{nw.first}-name")
      refute has_element?(lv, "#keys-refusal")
      assert Repo.get!(ModelChoice, choice.id).connection_id == nw.checkout.id
    end

    test "the last key of the group for a choice's workspace is refused, with what to do", ctx do
      %{conn: conn, scope: scope} = ctx
      nw = northwind(scope)

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{provider: nw.checkout.public_id})

      # The key for every workspace goes first; the Checkout key is then the last.
      {:ok, _} = Connections.remove_key(scope, nw.every, nw.first)

      {:ok, lv, _html} = live(conn, list_path(scope))
      lv |> element("#key-#{nw.second}-remove") |> render_click()
      lv |> element("#key-#{nw.second}-remove-confirm") |> render_click()

      assert text(lv, "#keys-refusal") ==
               "Add another key, or choose another provider in Workspace settings › Model, " <>
                 "then remove key-2. It is the last Claude subscription token key for " <>
                 "#{scope.workspace.name}."

      assert has_element?(lv, "#key-#{nw.second}-name")
    end

    test "the last key of the group for the organisation's default is refused, with what to do",
         ctx do
      %{conn: conn, scope: scope} = ctx
      nw = northwind(scope)

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(scope, :organisation, %{provider: nw.every.public_id})

      {:ok, lv, _html} = live(conn, list_path(scope))
      lv |> element("#key-#{nw.first}-remove") |> render_click()
      lv |> element("#key-#{nw.first}-remove-confirm") |> render_click()

      assert text(lv, "#keys-refusal") ==
               "Add another key for every workspace in #{scope.organisation.name}, then remove " <>
                 "key-1. The organisation's default model uses Claude subscription token."

      assert has_element?(lv, "#key-#{nw.first}-name")
    end
  end
end
