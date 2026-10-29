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
    # An edition that notes who does the flow's steps, and names its title.
    def set_up_steps(_scope, steps) do
      Enum.map(steps, fn step ->
        if step.id in Apiary.WorkspaceSetup.flow(),
          do: %{step | note: "Harbour Ops does this"},
          else: step
      end)
    end

    def set_up_title(_scope, %{id: :name}), do: "Set up the client's workspace"
  end

  defp named(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp shape(steps), do: Enum.map(steps, &{&1.id, &1.state})

  # The flow's steps, none done, as they follow the steps before them.
  @flow [
    {:name, :to_come},
    {:sources, :to_come},
    {:destinations, :to_come},
    {:model, :to_come},
    {:harness, :to_come},
    {:machines, :to_come},
    {:test, :to_come}
  ]

  @flow_ids Enum.map(@flow, &elem(&1, 0))

  # The flow's steps of a workspace that exists, none done but Name.
  defp made, do: List.keyreplace(@flow, :name, 0, {:name, :done})

  describe "steps_for/3" do
    @describetag needs: [:factory, :secrets]

    test "an instance admin: the account, each adapter, mail, then the flow of the workspace" do
      Apiary.Mail.put_test_source(:none)
      admin = instance_admin_scope()
      %{adapter: adapter} = settable_adapter_fixture(%{name: named("a-tracker")})
      key = {:adapter, adapter.public_id}

      steps = SetUpComponents.steps_for(admin, key)

      assert [{:account, :done}, {^key, :current}, {:mail, :to_come} | flow] = shape(steps)
      assert flow == made()

      # The flow's steps have no group, and no heading.
      assert Enum.map(steps, & &1.group) == [nil, :connect, :connect] ++ List.duplicate(nil, 7)
      refute Enum.any?(steps, &Map.has_key?(&1, :heading))

      # Your account starts the instance's progress, which the person starts in.
      assert Enum.map(steps, & &1.progress) ==
               [:instance, :instance, :instance] ++ List.duplicate(:organisation, 7)

      assert Enum.find(steps, &(&1.id == key)).path ==
               "/instance/set-up?step=#{adapter.public_id}"

      assert Enum.find(steps, &(&1.id == :mail)).path == "/instance/set-up?step=mail"

      # The flow's steps lead to the set-up of the admin's workspace.
      organisation = admin.organisation

      assert Enum.find(steps, &(&1.id == :sources)).path ==
               "/#{organisation.slug}/set-up?step=sources&workspace=#{admin.workspace.slug}"

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
      assert shape(steps) == [{:account, :current} | made()]

      # No adapter or Mail step: Your account stays the instance's, as for any admin.
      assert Enum.map(steps, & &1.progress) == [:instance | List.duplicate(:organisation, 7)]

      refute SetUpComponents.connect_steps?(admin)

      %{adapter: adapter} = settable_adapter_fixture(%{name: named("tracker")})
      key = {:adapter, adapter.public_id}

      assert [{:account, :done}, {^key, :current} | flow] =
               shape(SetUpComponents.steps_for(admin, key))

      assert flow == made()

      assert SetUpComponents.connect_steps?(admin)
      refute SetUpComponents.connect_steps?(scope_fixture())
    end

    test "an instance admin with no adapter or Mail step starts the flow at step 1" do
      Apiary.Mail.put_test_source(:env)
      admin = instance_admin_scope()
      steps = SetUpComponents.steps_for(admin, :name)

      assert Enum.map(steps, &{&1.id, &1.progress}) ==
               [{:account, :instance} | Enum.map(@flow_ids, &{&1, :organisation})]

      html = render_component(&SetUpComponents.steps/1, steps: steps)
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#set-up-step") |> LazyHTML.text() |> String.trim() ==
               "Step 1 of 7"

      # The 7 steps in order, with no group heading.
      assert [
               {"Name", :current},
               {"Work sources", :to_come},
               {"Destinations", :to_come},
               {"Model", :to_come},
               {"Harness", :to_come},
               {"Machines", :to_come},
               {"Test run", :to_come}
             ] = ApiaryWeb.SetUpSteps.steps(html_doc(html))

      assert doc |> LazyHTML.query(".q-su-grp-h") |> Enum.to_list() == []

      # A person who is not an instance admin keeps Your account in the organisation's:
      # 8 steps.
      steps = SetUpComponents.steps_for(scope_fixture(), :name)
      assert [%{id: :account, progress: :organisation} | _] = steps

      assert render_component(&SetUpComponents.steps/1, steps: steps)
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#set-up-step")
             |> LazyHTML.text()
             |> String.trim() == "Step 2 of 8"
    end

    test "the first person, before the workspace: the account, then the flow of a new one" do
      Apiary.Mail.put_test_source(:env)

      {:ok, %{user: user}} =
        Organisations.sign_up_user(
          %{email: unique_user_email(), organisation_name: "Acme"},
          nil,
          open: true,
          workspace: false
        )

      scope = Organisations.load_scope(Apiary.Accounts.Scope.for_user(user))
      steps = SetUpComponents.steps_for(scope, :name)

      assert shape(steps) == [
               {:account, :done} | List.keyreplace(@flow, :name, 0, {:name, :current})
             ]

      assert Enum.all?(steps, &(&1.progress == :organisation))
      assert Enum.map(steps, & &1.group) == List.duplicate(nil, 8)

      # The default flow is at the set-up, which shows the type cards first.
      assert Enum.find(steps, &(&1.id == :sources)).path ==
               "/#{scope.organisation.slug}/set-up?step=sources"

      refute Enum.any?(steps, &Map.has_key?(&1, :heading))

      # The flow a page names, of the type picked.
      flow =
        SetUpComponents.flow(scope.organisation, Apiary.Lingo.Domain.Software, nil, :set_up,
          type: true
        )

      steps = SetUpComponents.steps_for(scope, :name, flow: flow)

      assert Enum.find(steps, &(&1.id == :model)).path ==
               "/#{scope.organisation.slug}/set-up?step=model&type=software"

      assert SetUpComponents.flow_title(flow) == "Set up a new Software factory"
    end

    test "with mail not set by the environment, an instance admin has the mail step" do
      Apiary.Mail.put_test_source(:none)
      admin = instance_admin_scope()

      assert {:mail, :to_come} in shape(SetUpComponents.steps_for(admin, :account))
      assert SetUpComponents.connect_steps?(admin)
    end

    test "a sign-up: the account, then the flow, one progress" do
      Apiary.Mail.put_test_source(:none)
      steps = SetUpComponents.steps_for(nil, :account)

      assert shape(steps) == [{:account, :current} | @flow]
      assert Enum.all?(steps, &(&1.progress == :organisation))
      assert Enum.all?(steps, &is_nil(&1.path))
    end

    test "the set-up link: the account, then the instance's connections and the workspace" do
      Apiary.Mail.put_test_source(:none)
      %{adapter: adapter} = settable_adapter_fixture(%{name: named("tracker")})
      steps = SetUpComponents.steps_for(nil, :account, first: true)
      ids = Enum.map(steps, & &1.id)

      assert hd(ids) == :account
      assert {:adapter, adapter.public_id} in ids
      assert Enum.take(ids, -8) == [:mail | @flow_ids]

      assert Enum.map(steps, &{&1.id, &1.progress}) ==
               [
                 {:account, :instance},
                 {{:adapter, adapter.public_id}, :instance},
                 {:mail, :instance}
               ] ++ Enum.map(@flow_ids, &{&1, :organisation})

      # Signed out, no step has a page to open.
      assert Enum.all?(steps, &is_nil(&1.path))

      # Where the server's environment sets mail, no mail step.
      Apiary.Mail.put_test_source(:env)

      assert Enum.map(SetUpComponents.steps_for(nil, :account, first: true), & &1.id) ==
               [:account, {:adapter, adapter.public_id} | @flow_ids]
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
               [{:invitation, :current}, {:account, :to_come}, {:name, :to_come}]

      assert Enum.all?(steps, &(&1.progress == :organisation))

      steps = SetUpComponents.steps_for(nil, :account, invitation: invitation, token: token)
      assert [%{id: :invitation, state: :done, path: path} | _] = steps
      assert path == "/invitations/#{token}"

      # Once the organisation has a workspace, the invited person sets none up.
      {:ok, _main} = Organisations.create_first_workspace(scope, %{"domain" => "software"})
      invitation = Organisations.get_invitation_by_token(token)

      assert shape(SetUpComponents.steps_for(nil, :account, invitation: invitation, token: token)) ==
               [{:invitation, :done}, {:account, :current}]

      assert organisation.id == invitation.organisation_id
    end

    test "a step the edition renames from Your account counts as the organisation's" do
      Apiary.Mail.put_test_source(:none)
      :ok = Apiary.Edition.put_test_stub(Renamed)
      admin = instance_admin_scope()

      steps = SetUpComponents.steps_for(admin, :name)

      # The renamed step has no progress, so it counts as the organisation's, with the
      # steps after it.
      assert [%{id: :organisation} = renamed | rest] = steps
      refute Map.has_key?(renamed, :progress)

      assert Enum.map(rest, &{&1.id, &1.progress}) == Enum.map(@flow_ids, &{&1, :organisation})

      html = render_component(&SetUpComponents.steps/1, steps: steps)

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#set-up-step")
             |> LazyHTML.text()
             |> String.trim() == "Step 2 of 8"
    end

    test "the edition's answer is the list shown, its notes included" do
      :ok = Apiary.Edition.put_test_stub(Noted)
      steps = SetUpComponents.steps_for(nil, :account)

      assert Enum.map(steps, & &1.note) ==
               [nil] ++ List.duplicate("Harbour Ops does this", 7)

      assert Apiary.Edition.set_up_title(nil, Enum.find(steps, &(&1.id == :name))) ==
               "Set up the client's workspace"
    end
  end

  describe "the contracts an edition reads" do
    @describetag needs: [:factory, :secrets]

    test "the flow's ids, a done Your account at the head, :connect on the instance's steps alone, and the cards at New workspace" do
      # Made before mail is turned off: without mail, a sign-up needs a password.
      member = scope_fixture()
      Apiary.Mail.put_test_source(:none)

      # `Apiary.WorkspaceSetup.flow/0` is public, a plain list of the step ids in order.
      assert Apiary.WorkspaceSetup.flow() ==
               [:name, :sources, :destinations, :model, :harness, :machines, :test]

      admin = instance_admin_scope()
      %{adapter: adapter} = settable_adapter_fixture(%{name: named("tracker")})
      steps = SetUpComponents.steps_for(admin, :name)

      # A done Your account heads the list, before the instance's steps and the flow.
      assert [%{id: :account, state: :done} | _] = steps

      assert [%{id: :account, state: :done} | _] = SetUpComponents.steps_for(member, :name)

      # `group: :connect` is on the instance's steps alone.
      connect = for %{group: :connect, id: id} <- steps, do: id
      assert connect == [{:adapter, adapter.public_id}, :mail]
      assert Enum.all?(steps, &(&1.group in [nil, :connect]))

      # The cards page stays at `/:org/workspaces/new`, and its flow's steps lead there.
      flow = SetUpComponents.flow(admin.organisation, Apiary.Lingo.Domain.Software, nil, :new)

      assert SetUpComponents.flow_path(flow, :name) ==
               "/#{admin.organisation.slug}/workspaces/new?step=name"
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
        id: :name,
        label: "Name",
        group: nil,
        state: :done,
        path: "/acme/set-up?step=name",
        note: nil,
        progress: :organisation
      },
      %{
        id: :model,
        label: "Model",
        group: nil,
        state: :current,
        path: "/acme/set-up?step=model",
        note: "Harbour Ops does this",
        progress: :organisation
      }
    ]

    defp text(doc, selector),
      do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

    test "counts the current step's progress alone, from 1, with no count of steps left" do
      html = render_component(&SetUpComponents.steps/1, steps: @steps)
      doc = LazyHTML.from_fragment(html)

      assert text(doc, "#set-up-step") == "Step 2 of 2"
      assert text(doc, "#set-up-step-bar") == "Step 2 of 2: Model"
      assert doc |> LazyHTML.query("progress") |> LazyHTML.attribute("value") == ["2"]
      assert doc |> LazyHTML.query("progress") |> LazyHTML.attribute("max") == ["2"]
      refute html =~ "left"
      refute html =~ "·"

      # On Mail, the instance's progress: Your account, GitHub and Mail.
      doc =
        LazyHTML.from_fragment(
          render_component(&SetUpComponents.steps/1, steps: current(@steps, :mail))
        )

      assert text(doc, "#set-up-step") == "Step 3 of 3"
      assert text(doc, "#set-up-step-bar") == "Step 3 of 3: Mail"
      assert doc |> LazyHTML.query("progress") |> LazyHTML.attribute("max") == ["3"]
    end

    test "lists the steps of one progress, with no group heading, with marks, links and notes" do
      html =
        render_component(&SetUpComponents.steps/1,
          steps: @steps,
          title: "Set up Payments · Software factory",
          page: "/acme/set-up"
        )

      assert ApiaryWeb.SetUpSteps.steps(html_doc(html)) == [
               {"Name", :done, :link},
               {"Model", :current}
             ]

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query(".q-su-grp-h") |> Enum.to_list() == []

      assert text(doc, "#set-up-title") == "Set up Payments · Software factory"
      assert doc |> LazyHTML.query("[aria-current=step]") |> LazyHTML.text() =~ "Model"
      assert text(doc, ".q-su-note") == "Harbour Ops does this"

      # A link on this page patches.
      assert doc |> LazyHTML.query("#set-up-steps-name") |> LazyHTML.attribute("data-phx-link") ==
               ["patch"]

      refute html =~ "set-up-next"

      # The instance's progress: the heading Connect Qory Apiary, a skipped step, a link to another page,
      # and no line on what comes after.
      html =
        render_component(&SetUpComponents.steps/1,
          steps: current(@steps, :mail) |> List.update_at(1, &%{&1 | state: :skipped}),
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

      refute html =~ "set-up-title"
    end

    test "a step without a progress counts as the organisation's" do
      # The instance's Your account and Mail, then three steps without the key, as an
      # edition may add them.
      steps = [
        hd(@steps),
        Enum.at(@steps, 2),
        step(:organisation, "Your organisation", nil, :done),
        step(:name, "Name", nil, :current),
        step(:sources, "Work sources", nil, :to_come)
      ]

      html = render_component(&SetUpComponents.steps/1, steps: steps)

      assert text(LazyHTML.from_fragment(html), "#set-up-step") == "Step 2 of 3"

      assert ApiaryWeb.SetUpSteps.steps(html_doc(html)) == [
               {"Your organisation", :done},
               {"Name", :current},
               {"Work sources", :to_come}
             ]

      # A group without a heading lists its steps with none.
      assert html |> LazyHTML.from_fragment() |> LazyHTML.query(".q-su-grp-h") |> Enum.to_list() ==
               []
    end

    test "the frame shows no indicator with one step, and no aside without context" do
      frame = fn steps ->
        render_component(
          fn assigns ->
            ~H"""
            <SetUpComponents.frame steps={@steps}>Form</SetUpComponents.frame>
            """
          end,
          %{steps: steps}
        )
      end

      html = frame.([step(:name, "Name", nil, :current)])

      refute html =~ "set-up-steps"
      refute html =~ "set-up-context"
      assert html =~ "Form"

      # A progress of one step after the instance's steps keeps the indicator.
      html =
        frame.([
          hd(@steps),
          Enum.at(@steps, 2),
          step(:name, "Name", nil, :current)
        ])

      assert text(LazyHTML.from_fragment(html), "#set-up-step") == "Step 1 of 1"
      assert ApiaryWeb.SetUpSteps.steps(html_doc(html)) == [{"Name", :current}]

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
      # Name starts this organisation's progress: no Back to Mail.
      refute render_component(&SetUpComponents.back/1,
               steps: current(@steps, :name),
               page: "/acme/set-up"
             ) =~ "set-up-back"

      html = render_component(&SetUpComponents.back/1, steps: @steps, page: "/acme/set-up")
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#set-up-back") |> LazyHTML.attribute("href") ==
               ["/acme/set-up?step=name"]

      assert doc |> LazyHTML.query("#set-up-back") |> LazyHTML.attribute("aria-label") ==
               ["Back to Name"]

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
