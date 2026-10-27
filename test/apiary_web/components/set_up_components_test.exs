defmodule ApiaryWeb.SetUpComponentsTest do
  # The set-up's steps (`ApiaryWeb.SetUpComponents.steps_for/3`) per person and instance,
  # with their states and the edition's answer to them; the progress indicator
  # (`steps/1`) and the frame (`frame/1`) that show them.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias ApiaryWeb.SetUpComponents

  defmodule Noted do
    # An edition that notes who does the workspace's steps, and names its title.
    def set_up_steps(_scope, steps) do
      Enum.map(steps, fn
        %{group: :workspace} = step -> %{step | note: "Harbour Ops does this"}
        step -> step
      end)
    end

    def set_up_title(_scope, %{id: :workspace}), do: "Set up the client's workspace"
  end

  defp named(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp shape(steps), do: Enum.map(steps, &{&1.id, &1.state})

  describe "steps_for/3" do
    @describetag needs: :factory

    test "an instance admin: the account, each adapter, mail, the workspace, its source" do
      Apiary.Mail.put_test_source(:none)
      admin = instance_admin_scope()
      %{adapter: adapter} = settable_adapter_fixture(%{name: named("a-tracker")})
      key = {:adapter, adapter.public_id}

      steps = SetUpComponents.steps_for(admin, key)

      assert [
               {:account, :done},
               {^key, :current},
               {:mail, :to_come},
               {:workspace, :done},
               {:source, :to_come}
             ] = shape(steps)

      assert Enum.map(steps, & &1.group) == [nil, :connect, :connect, :workspace, :workspace]

      assert Enum.find(steps, &(&1.id == key)).path ==
               "/instance/set-up?step=#{adapter.public_id}"

      assert Enum.find(steps, &(&1.id == :mail)).path == "/instance/set-up?step=mail"
      assert Enum.find(steps, &(&1.id == :source)).path =~ ~r{^/[^/]+/set-up\?step=source$}
      assert Enum.all?(steps, &is_nil(&1.note))

      # Two adapters, by name; one before the current not done is skipped, one done stays
      # done.
      %{adapter: configured} = connectable_adapter_fixture(%{name: named("0-tracker")})

      assert [
               {:account, :done},
               {{:adapter, configured_id}, :done},
               {^key, :skipped},
               {:mail, :current} | _
             ] = shape(SetUpComponents.steps_for(admin, :mail))

      assert configured_id == configured.public_id
    end

    test "where the server's environment sets mail, there is no mail step" do
      Apiary.Mail.put_test_source(:env)
      admin = instance_admin_scope()

      assert shape(SetUpComponents.steps_for(admin, :account)) ==
               [{:account, :current}, {:workspace, :done}, {:source, :to_come}]

      refute SetUpComponents.connect_steps?(admin)

      %{adapter: adapter} = settable_adapter_fixture(%{name: named("tracker")})
      key = {:adapter, adapter.public_id}

      assert [{:account, :done}, {^key, :current}, {:workspace, :done}, {:source, :to_come}] =
               shape(SetUpComponents.steps_for(admin, key))

      assert SetUpComponents.connect_steps?(admin)
      refute SetUpComponents.connect_steps?(scope_fixture())
    end

    test "with mail not set by the environment, an instance admin has the mail step" do
      Apiary.Mail.put_test_source(:none)
      admin = instance_admin_scope()

      assert {:mail, :to_come} in shape(SetUpComponents.steps_for(admin, :account))
      assert SetUpComponents.connect_steps?(admin)
    end

    test "a sign-up: the account, then the workspace and its source" do
      assert shape(SetUpComponents.steps_for(nil, :account)) ==
               [{:account, :current}, {:workspace, :to_come}, {:source, :to_come}]
    end

    test "the set-up link: the account, then the instance's connections and the workspace" do
      Apiary.Mail.put_test_source(:none)
      %{adapter: adapter} = settable_adapter_fixture(%{name: named("tracker")})
      steps = SetUpComponents.steps_for(nil, :account, first: true)
      ids = Enum.map(steps, & &1.id)

      assert hd(ids) == :account
      assert {:adapter, adapter.public_id} in ids
      assert Enum.take(ids, -3) == [:mail, :workspace, :source]

      # Signed out, no step has a page to open.
      assert Enum.all?(steps, &is_nil(&1.path))

      # Where the server's environment sets mail, no mail step.
      Apiary.Mail.put_test_source(:env)

      assert Enum.map(SetUpComponents.steps_for(nil, :account, first: true), & &1.id) ==
               [:account, {:adapter, adapter.public_id}, :workspace, :source]
    end

    test "an invited sign-up whose invitation has no workspace starts with the invitation" do
      {:ok, %{user: owner, organisation: organisation}} =
        Organisations.sign_up_user(
          %{
            email: "owner-#{System.unique_integer([:positive])}@example.com",
            organisation_name: "Acme"
          },
          nil,
          open: true,
          workspace: false
        )

      token = extract_user_token(&Apiary.Accounts.deliver_login_instructions(owner, &1))
      {:ok, {owner, _expired}} = Apiary.Accounts.login_user_by_magic_link(token)
      scope = Organisations.load_scope(Apiary.Accounts.Scope.for_user(owner))
      %{token: token} = invitation_fixture(scope, %{"email" => "bee@example.com"})
      invitation = Organisations.get_invitation_by_token(token)

      assert shape(
               SetUpComponents.steps_for(nil, :invitation, invitation: invitation, token: token)
             ) ==
               [{:invitation, :current}, {:account, :to_come}, {:workspace, :to_come}]

      steps = SetUpComponents.steps_for(nil, :account, invitation: invitation, token: token)
      assert [%{id: :invitation, state: :done, path: path} | _] = steps
      assert path == "/invitations/#{token}"

      # Once the organisation has a workspace, the invited person sets none up.
      {:ok, _main} = Organisations.create_first_workspace(scope, %{"domain" => "general"})
      invitation = Organisations.get_invitation_by_token(token)

      assert shape(SetUpComponents.steps_for(nil, :account, invitation: invitation, token: token)) ==
               [{:invitation, :done}, {:account, :current}]

      assert organisation.id == invitation.organisation_id
    end

    test "the edition's answer is the list shown, its notes included" do
      :ok = Apiary.Edition.put_test_stub(Noted)
      steps = SetUpComponents.steps_for(nil, :account)

      assert Enum.map(steps, & &1.note) == [nil, "Harbour Ops does this", "Harbour Ops does this"]

      assert Apiary.Edition.set_up_title(nil, Enum.at(steps, 1)) ==
               "Set up the client's workspace"
    end
  end

  describe "the core's edition" do
    test "answers the steps unchanged, and the workspace set-up's title" do
      steps = [
        %{id: :account, label: "Your account", group: nil, state: :current, path: nil, note: nil}
      ]

      assert Apiary.Edition.Core.set_up_steps(nil, steps) == steps
      assert Apiary.Edition.Core.set_up_title(nil, nil) == "Set up your workspace"
    end
  end

  describe "steps/1" do
    defp step(id, label, group, state, path \\ nil, note \\ nil),
      do: %{id: id, label: label, group: group, state: state, path: path, note: note}

    @steps [
      %{id: :account, label: "Your account", group: nil, state: :done, path: nil, note: nil},
      %{
        id: {:adapter, "na_1"},
        label: "GitHub",
        group: :connect,
        state: :skipped,
        path: "/instance/set-up?step=na_1",
        note: nil
      },
      %{
        id: :mail,
        label: "Mail",
        group: :connect,
        state: :done,
        path: "/instance/set-up?step=mail",
        note: nil
      },
      %{
        id: :workspace,
        label: "Workspace",
        group: :workspace,
        state: :current,
        path: "/acme/set-up?step=type",
        note: "Harbour Ops does this"
      },
      %{
        id: :source,
        label: "Work source",
        group: :workspace,
        state: :done,
        path: "/acme/set-up?step=source",
        note: nil
      }
    ]

    test "says Step n of m and draws the bar, with no count of steps left" do
      html = render_component(&SetUpComponents.steps/1, steps: @steps, next: true)
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#set-up-step") |> LazyHTML.text() |> String.trim() ==
               "Step 4 of 5"

      assert doc |> LazyHTML.query("#set-up-step-bar") |> LazyHTML.text() |> String.trim() ==
               "Step 4 of 5: Workspace"

      assert doc |> LazyHTML.query("progress") |> LazyHTML.attribute("value") == ["4"]
      assert doc |> LazyHTML.query("progress") |> LazyHTML.attribute("max") == ["5"]
      refute html =~ "left"
      refute html =~ "·"
    end

    test "lists the steps under their groups, with their marks, links and notes" do
      html =
        render_component(&SetUpComponents.steps/1,
          steps: @steps,
          next: true,
          page: "/acme/set-up"
        )

      assert ApiaryWeb.SetUpSteps.steps(html_doc(html)) == [
               {"Your account", :done},
               {"GitHub", :skipped, :link},
               {"Mail", :done, :link},
               {"Workspace", :current},
               {"Work source", :done, :link}
             ]

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query(".q-su-grp-h") |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
               ["Connect Qory Apiary", "Set up your workspace"]

      assert doc |> LazyHTML.query("[aria-current=step]") |> LazyHTML.text() =~ "Workspace"
      assert doc |> LazyHTML.query(".q-su-skipped") |> LazyHTML.text() == "Skipped"
      assert doc |> LazyHTML.query(".q-su-note") |> LazyHTML.text() == "Harbour Ops does this"

      # A link on this page patches; one to another page navigates.
      assert doc |> LazyHTML.query("#set-up-steps-source") |> LazyHTML.attribute("data-phx-link") ==
               ["patch"]

      assert doc |> LazyHTML.query("#set-up-steps-mail") |> LazyHTML.attribute("data-phx-link") ==
               ["redirect"]

      assert doc |> LazyHTML.query("#set-up-next") |> LazyHTML.text() |> String.trim() ==
               "Next: on the Overview, Machines for runs, Model key and Test run"

      refute render_component(&SetUpComponents.steps/1, steps: @steps) =~ "Next:"
    end

    test "the frame shows no indicator with one step, and no aside without context" do
      one = [step(:workspace, "Workspace", :workspace, :current)]

      html =
        render_component(
          fn assigns ->
            ~H"""
            <SetUpComponents.frame steps={@steps}>Form</SetUpComponents.frame>
            """
          end,
          %{steps: one}
        )

      refute html =~ "set-up-steps"
      refute html =~ "set-up-context"
      assert html =~ "Form"

      html =
        render_component(
          fn assigns ->
            ~H"""
            <SetUpComponents.frame steps={@steps}>
              Form
              <:context>Why</:context>
            </SetUpComponents.frame>
            """
          end,
          %{steps: @steps}
        )

      assert html =~ ~s(id="set-up-steps")
      assert html =~ "About this step"
    end

    test "Back leads to the step before the current one, where it has a page" do
      html = render_component(&SetUpComponents.back/1, steps: @steps, page: "/acme/set-up")
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#set-up-back") |> LazyHTML.attribute("href") ==
               ["/instance/set-up?step=mail"]

      assert doc |> LazyHTML.query("#set-up-back") |> LazyHTML.attribute("aria-label") ==
               ["Back to Mail"]

      first = [
        step(:account, "Your account", nil, :current),
        step(:mail, "Mail", :connect, :to_come)
      ]

      refute render_component(&SetUpComponents.back/1, steps: first) =~ "set-up-back"

      after_account = [
        step(:account, "Your account", nil, :done),
        step(:mail, "Mail", :connect, :current)
      ]

      refute render_component(&SetUpComponents.back/1, steps: after_account) =~ "set-up-back"
    end
  end

  defp html_doc(html), do: "<html><body>#{html}</body></html>"
end
