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

  defmodule Renamed do
    # An edition that leaves out the instance's steps and renames Your account, as an
    # edition may for an organisation made after the instance's set-up.
    def set_up_steps(_scope, steps) do
      for step <- steps, step.group != :connect do
        if step.id == :account,
          do: %{step | id: :organisation, label: "Your organisation"},
          else: step
      end
    end
  end

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

      # Your account starts the instance's progress, which the person starts in.
      assert Enum.map(steps, & &1.progress) ==
               [:instance, :instance, :instance, :organisation, :organisation]

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

      steps = SetUpComponents.steps_for(admin, :account)
      assert shape(steps) == [{:account, :current}, {:workspace, :done}, {:source, :to_come}]

      # No step of the instance's: Your account starts the organisation's progress.
      assert Enum.all?(steps, &(&1.progress == :organisation))

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

    test "a sign-up: the account, then the workspace and its source, one progress" do
      Apiary.Mail.put_test_source(:none)
      steps = SetUpComponents.steps_for(nil, :account)

      assert shape(steps) ==
               [{:account, :current}, {:workspace, :to_come}, {:source, :to_come}]

      assert Enum.all?(steps, &(&1.progress == :organisation))
    end

    test "the set-up link: the account, then the instance's connections and the workspace" do
      Apiary.Mail.put_test_source(:none)
      %{adapter: adapter} = settable_adapter_fixture(%{name: named("tracker")})
      steps = SetUpComponents.steps_for(nil, :account, first: true)
      ids = Enum.map(steps, & &1.id)

      assert hd(ids) == :account
      assert {:adapter, adapter.public_id} in ids
      assert Enum.take(ids, -3) == [:mail, :workspace, :source]

      assert Enum.map(steps, &{&1.id, &1.progress}) == [
               {:account, :instance},
               {{:adapter, adapter.public_id}, :instance},
               {:mail, :instance},
               {:workspace, :organisation},
               {:source, :organisation}
             ]

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

      steps = SetUpComponents.steps_for(nil, :invitation, invitation: invitation, token: token)

      assert shape(steps) ==
               [{:invitation, :current}, {:account, :to_come}, {:workspace, :to_come}]

      assert Enum.all?(steps, &(&1.progress == :organisation))

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

    test "a step the edition renames from Your account counts as the organisation's" do
      Apiary.Mail.put_test_source(:none)
      :ok = Apiary.Edition.put_test_stub(Renamed)
      admin = instance_admin_scope()

      steps = SetUpComponents.steps_for(admin, :workspace)

      # The renamed step has no progress, so it counts as the organisation's, with the
      # steps after it.
      assert [%{id: :organisation} = renamed | rest] = steps
      refute Map.has_key?(renamed, :progress)

      assert Enum.map(rest, &{&1.id, &1.progress}) ==
               [{:workspace, :organisation}, {:source, :organisation}]

      html = render_component(&SetUpComponents.steps/1, steps: steps)

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#set-up-step")
             |> LazyHTML.text()
             |> String.trim() == "Step 2 of 3"
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

    defp current(steps, id),
      do: Enum.map(steps, &%{&1 | state: if(&1.id == id, do: :current, else: :done)})

    @steps [
      %{
        id: :account,
        label: "Your account",
        group: nil,
        state: :done,
        path: nil,
        note: nil,
        progress: :instance
      },
      %{
        id: {:adapter, "na_1"},
        label: "GitHub",
        group: :connect,
        state: :skipped,
        path: "/instance/set-up?step=na_1",
        note: nil,
        progress: :instance
      },
      %{
        id: :mail,
        label: "Mail",
        group: :connect,
        state: :done,
        path: "/instance/set-up?step=mail",
        note: nil,
        progress: :instance
      },
      %{
        id: :workspace,
        label: "Workspace",
        group: :workspace,
        state: :current,
        path: "/acme/set-up?step=type",
        note: "Harbour Ops does this",
        progress: :organisation
      },
      %{
        id: :source,
        label: "Work source",
        group: :workspace,
        state: :done,
        path: "/acme/set-up?step=source",
        note: nil,
        progress: :organisation
      }
    ]

    defp text(doc, selector),
      do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

    test "counts the current step's progress alone, from 1, with no count of steps left" do
      html = render_component(&SetUpComponents.steps/1, steps: @steps, next: true)
      doc = LazyHTML.from_fragment(html)

      assert text(doc, "#set-up-step") == "Step 1 of 2"
      assert text(doc, "#set-up-step-bar") == "Step 1 of 2: Workspace"
      assert doc |> LazyHTML.query("progress") |> LazyHTML.attribute("value") == ["1"]
      assert doc |> LazyHTML.query("progress") |> LazyHTML.attribute("max") == ["2"]
      refute html =~ "left"
      refute html =~ "·"

      # On Mail, the instance's progress: Your account, GitHub and Mail.
      doc =
        LazyHTML.from_fragment(
          render_component(&SetUpComponents.steps/1, steps: current(@steps, :mail), next: true)
        )

      assert text(doc, "#set-up-step") == "Step 3 of 3"
      assert text(doc, "#set-up-step-bar") == "Step 3 of 3: Mail"
      assert doc |> LazyHTML.query("progress") |> LazyHTML.attribute("max") == ["3"]
    end

    test "lists the steps of one progress under their groups, with marks, links and notes" do
      html =
        render_component(&SetUpComponents.steps/1,
          steps: @steps,
          next: true,
          page: "/acme/set-up"
        )

      assert ApiaryWeb.SetUpSteps.steps(html_doc(html)) == [
               {"Workspace", :current},
               {"Work source", :done, :link}
             ]

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query(".q-su-grp-h") |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
               ["Set up your workspace"]

      assert doc |> LazyHTML.query("[aria-current=step]") |> LazyHTML.text() =~ "Workspace"
      assert text(doc, ".q-su-note") == "Harbour Ops does this"

      # A link on this page patches.
      assert doc |> LazyHTML.query("#set-up-steps-source") |> LazyHTML.attribute("data-phx-link") ==
               ["patch"]

      assert text(doc, "#set-up-next") ==
               "Next: on the Overview, Machines for runs, Model key and Test run"

      refute render_component(&SetUpComponents.steps/1, steps: @steps) =~ "Next:"

      # The instance's progress: the heading Connect Qory Apiary, a skipped step, a link to another page,
      # and no line on what comes after.
      html =
        render_component(&SetUpComponents.steps/1,
          steps: current(@steps, :mail) |> List.update_at(1, &%{&1 | state: :skipped}),
          next: true,
          page: "/acme/set-up"
        )

      assert ApiaryWeb.SetUpSteps.steps(html_doc(html)) == [
               {"Your account", :done},
               {"GitHub", :skipped, :link},
               {"Mail", :current}
             ]

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query(".q-su-grp-h") |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
               ["Connect Qory Apiary"]

      assert text(doc, ".q-su-skipped") == "Skipped"

      assert doc
             |> LazyHTML.query("#set-up-steps-adapter-na_1")
             |> LazyHTML.attribute("data-phx-link") == ["redirect"]

      refute html =~ "Next:"
    end

    test "a step without a progress counts as the organisation's" do
      # The instance's Your account and Mail, then three steps without the key, as an
      # edition may add them.
      steps = [
        hd(@steps),
        Enum.at(@steps, 2),
        step(:organisation, "Your organisation", nil, :done),
        step(:workspace, "Workspace", :workspace, :current),
        step(:source, "Work source", :workspace, :to_come)
      ]

      html = render_component(&SetUpComponents.steps/1, steps: steps)

      assert text(LazyHTML.from_fragment(html), "#set-up-step") == "Step 2 of 3"

      assert ApiaryWeb.SetUpSteps.steps(html_doc(html)) == [
               {"Your organisation", :done},
               {"Workspace", :current},
               {"Work source", :to_come}
             ]
    end

    test "the frame shows no indicator with one step, and no aside without context" do
      one = [step(:workspace, "Workspace", :workspace, :current)]

      # The instance's steps do not count toward the organisation's one step.
      one_after_instance = [
        hd(@steps),
        Enum.at(@steps, 2),
        step(:workspace, "Workspace", :workspace, :current)
      ]

      for steps <- [one, one_after_instance] do
        html =
          render_component(
            fn assigns ->
              ~H"""
              <SetUpComponents.frame steps={@steps}>Form</SetUpComponents.frame>
              """
            end,
            %{steps: steps}
          )

        refute html =~ "set-up-steps"
        refute html =~ "set-up-context"
        assert html =~ "Form"
      end

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

    test "Back leads to the step before the current one in its progress, where it has a page" do
      # Workspace starts the organisation's progress: no Back to Mail.
      refute render_component(&SetUpComponents.back/1, steps: @steps, page: "/acme/set-up") =~
               "set-up-back"

      html =
        render_component(&SetUpComponents.back/1,
          steps: current(@steps, :source),
          page: "/acme/set-up"
        )

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#set-up-back") |> LazyHTML.attribute("href") ==
               ["/acme/set-up?step=type"]

      assert doc |> LazyHTML.query("#set-up-back") |> LazyHTML.attribute("aria-label") ==
               ["Back to Workspace"]

      html = render_component(&SetUpComponents.back/1, steps: current(@steps, :mail))

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#set-up-back")
             |> LazyHTML.attribute("aria-label") == ["Back to GitHub"]

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
