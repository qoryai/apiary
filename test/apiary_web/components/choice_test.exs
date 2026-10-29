defmodule ApiaryWeb.ChoiceTest do
  @moduledoc """
  The choice field, `<.input type="choice">`: a button that shows the chosen option and a
  panel of radios named like the field. The `Choice` hook's keys, its open panel and its
  search run in the browser; these tests cover the markup it works on and what the form
  sends.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias ApiaryWeb.CoreComponents

  @endpoint ApiaryWeb.Endpoint

  @types [
    %{
      value: "software",
      title: "Software",
      subtitle: "For work on code. Each ticket needs a repository."
    },
    %{value: "example", title: "Example", subtitle: "For the tests only."}
  ]

  defmodule FormLive do
    use Phoenix.LiveView

    alias ApiaryWeb.CoreComponents

    @types [
      %{value: "software", title: "Software", subtitle: "For work on code."},
      %{value: "example", title: "Example", subtitle: "For the tests only."}
    ]

    def mount(_params, _session, socket) do
      {:ok, assign(socket, form: to_form(%{}, as: :workspace), saved: nil)}
    end

    def handle_event("validate", %{"workspace" => params}, socket) do
      {:noreply, assign(socket, :form, to_form(params, as: :workspace))}
    end

    def handle_event("save", %{"workspace" => params}, socket) do
      {:noreply, assign(socket, :saved, params["domain"])}
    end

    def render(assigns) do
      assigns = assign(assigns, :types, @types)

      ~H"""
      <.form for={@form} id="workspace-form" phx-change="validate" phx-submit="save">
        <CoreComponents.input
          field={@form[:domain]}
          type="choice"
          label="Type"
          prompt="Choose a type"
          options={@types}
        />
      </.form>
      <p :if={@saved} id="saved">{@saved}</p>
      """
    end
  end

  defp choice(attrs) do
    form = to_form(Map.get(attrs, :params, %{}), as: :workspace)

    attrs =
      %{field: form[:domain], type: "choice", label: "Type", options: @types}
      |> Map.merge(Map.delete(attrs, :params))

    LazyHTML.from_fragment(render_component(&CoreComponents.input/1, attrs))
  end

  defp text(doc, selector),
    do: doc |> LazyHTML.query(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))

  defp models(n) do
    for i <- 1..n, do: %{value: "model-#{i}", title: "Model #{i}", subtitle: "model-#{i}"}
  end

  describe "a choice with options" do
    test "is a button for the panel, and a radio named like the field per option" do
      doc = choice(%{prompt: "Choose a type"})
      button = LazyHTML.query(doc, "fieldset.q-pick > button#workspace_domain")

      assert LazyHTML.attribute(button, "type") == ["button"]
      assert LazyHTML.attribute(button, "aria-expanded") == ["false"]
      assert LazyHTML.attribute(button, "aria-controls") == ["workspace_domain-panel"]

      assert LazyHTML.attribute(button, "aria-labelledby") == [
               "workspace_domain-label workspace_domain-shown"
             ]

      assert text(doc, "legend#workspace_domain-label") == ["Type"]
      assert text(doc, "#workspace_domain-shown") == ["Choose a type"]
      assert LazyHTML.attribute(button, "class") |> hd() =~ "is-prompt"

      panel = LazyHTML.query(doc, "#workspace_domain-panel[hidden]")
      assert Enum.count(panel) == 1

      group = LazyHTML.query(panel, "[role=radiogroup]")
      assert LazyHTML.attribute(group, "aria-labelledby") == ["workspace_domain-label"]

      radios = LazyHTML.query(group, "label.q-pick-opt input[type=radio]")
      assert LazyHTML.attribute(radios, "name") == ["workspace[domain]", "workspace[domain]"]
      assert LazyHTML.attribute(radios, "value") == ["software", "example"]
      assert LazyHTML.attribute(radios, "checked") == []

      assert LazyHTML.attribute(radios, "aria-describedby") == [
               "workspace_domain-0-s",
               "workspace_domain-1-s"
             ]

      assert text(doc, ".q-pick-opt .q-pick-t") == ["Software", "Example"]

      assert text(doc, "#workspace_domain-1-s") == ["For the tests only."]
    end

    test "draws an option without a subtitle as its title alone" do
      doc = choice(%{options: [%{value: "a", title: "Alpha"}]})

      assert text(doc, ".q-pick-opt .q-pick-t") == ["Alpha"]
      assert LazyHTML.query(doc, ".q-pick-opt .q-pick-s") |> Enum.count() == 0

      assert LazyHTML.attribute(LazyHTML.query(doc, "input[type=radio]"), "aria-describedby") ==
               []
    end

    test "sets a part in mono and marks an option the search keeps" do
      doc =
        choice(%{
          options: [
            %{value: "m", title: "Claude Opus 5.5", subtitle: "claude-opus-5-5", mono: :subtitle},
            %{value: "x", title: "Another model", subtitle: "Any id.", keep: true}
          ]
        })

      assert text(doc, ".q-pick-opt .q-pick-s.mono") == ["claude-opus-5-5"]
      assert LazyHTML.attribute(LazyHTML.query(doc, ".q-pick-opt"), "data-keep") == ["true"]
    end
  end

  describe "a choice with groups" do
    test "heads each group, an empty one too, in one radio group with unique ids" do
      doc =
        choice(%{
          params: %{"domain" => "shared"},
          options: [
            {"Linked repositories",
             [
               %{value: "harness", title: "example-org/harness", mono: :title},
               %{value: "ops", title: "example-org/harness-ops", mono: :title}
             ]},
            {"Assigned by an instance admin", []},
            {"Public address",
             [%{value: "address", title: "Enter an address", subtitle: "Any https address."}]}
          ]
        })

      assert LazyHTML.query(doc, "[role=radiogroup]") |> Enum.count() == 1

      assert text(doc, "[role=radiogroup] > .q-pick-grp > p.q-pick-group") ==
               ["Linked repositories", "Assigned by an instance admin", "Public address"]

      assert LazyHTML.attribute(LazyHTML.query(doc, "p.q-pick-group"), "id") ==
               ["workspace_domain-g0", "workspace_domain-g1", "workspace_domain-g2"]

      radios = LazyHTML.query(doc, "input[type=radio]")
      assert LazyHTML.attribute(radios, "id") == Enum.map(0..2, &"workspace_domain-#{&1}")
      assert LazyHTML.attribute(radios, "name") == List.duplicate("workspace[domain]", 3)

      assert LazyHTML.attribute(radios, "aria-describedby") == [
               "workspace_domain-g0",
               "workspace_domain-g0",
               "workspace_domain-g2 workspace_domain-2-s"
             ]

      assert text(doc, ".q-pick-opt .q-pick-t.mono") ==
               ["example-org/harness", "example-org/harness-ops"]
    end

    test "finds the chosen option in any group, and counts every group for the search" do
      doc =
        choice(%{
          params: %{"domain" => "model-9"},
          options: [{"Anthropic", models(5)}, {"OpenRouter", Enum.drop(models(9), 5)}]
        })

      assert text(doc, "#workspace_domain-shown .q-pick-t") == ["Model 9"]
      assert LazyHTML.query(doc, "input[type=search]") |> Enum.count() == 1

      assert LazyHTML.query(doc, "input[type=radio][checked]") |> LazyHTML.attribute("id") ==
               ["workspace_domain-8"]
    end

    test "takes options outside a group as a group with no heading" do
      doc =
        choice(%{
          options: [%{value: "a", title: "Alpha"}, {"More", [%{value: "b", title: "Beta"}]}]
        })

      assert text(doc, "p.q-pick-group") == ["More"]
      assert LazyHTML.query(doc, ".q-pick-grp") |> Enum.count() == 2

      assert LazyHTML.attribute(LazyHTML.query(doc, "#workspace_domain-0"), "aria-describedby") ==
               []
    end
  end

  describe "a choice with a disabled option" do
    test "shows it with a disabled radio, which the form never sends" do
      doc =
        choice(%{
          options: [
            {"Linked repositories", [%{value: "", title: "Reading…", disabled: true}]},
            {"Public address", [%{value: "address", title: "Enter an address"}]}
          ]
        })

      assert text(doc, ".q-pick-opt .q-pick-t") == ["Reading…", "Enter an address"]

      assert LazyHTML.query(doc, "input[type=radio][disabled]") |> LazyHTML.attribute("id") ==
               ["workspace_domain-0"]

      assert LazyHTML.query(doc, "input[type=radio][checked]") |> Enum.count() == 0
      assert text(doc, "#workspace_domain-shown") == [""]
    end

    test "is never chosen, though its value is the field's" do
      doc =
        choice(%{
          params: %{"domain" => ""},
          prompt: "Choose a source",
          options: [%{value: "", title: "Reading…", disabled: true}]
        })

      assert LazyHTML.query(doc, "input[type=radio][checked]") |> Enum.count() == 0
      assert text(doc, "#workspace_domain-shown") == ["Choose a source"]
    end

    test "with the field disabled, disables every radio and the button" do
      doc = choice(%{disabled: true})

      assert LazyHTML.query(doc, "input[type=radio][disabled]") |> Enum.count() == 2
      assert LazyHTML.query(doc, "button[disabled]") |> Enum.count() == 1
    end
  end

  describe "a choice with a chosen value" do
    test "shows the chosen title and subtitle on its button, and checks its radio" do
      doc = choice(%{params: %{"domain" => "example"}, prompt: "Choose a type"})

      assert text(doc, "#workspace_domain-shown .q-pick-t") == ["Example"]

      assert text(doc, "#workspace_domain-shown .q-pick-s") == ["For the tests only."]

      refute LazyHTML.attribute(LazyHTML.query(doc, "button"), "class") |> hd() =~ "is-prompt"

      assert LazyHTML.query(doc, "input[type=radio][checked]") |> LazyHTML.attribute("value") ==
               ["example"]
    end
  end

  describe "a choice with an error" do
    test "marks its button invalid and describes it by the error, in place of the hint" do
      doc =
        choice(%{
          errors: ["Choose a type."],
          field: nil,
          id: "workspace_domain",
          name: "workspace[domain]",
          value: nil,
          hint: "You can't change the type after you create the workspace."
        })

      button = LazyHTML.query(doc, "button#workspace_domain")
      assert LazyHTML.attribute(button, "aria-invalid") == ["true"]
      assert LazyHTML.attribute(button, "aria-describedby") == ["workspace_domain-error"]
      assert LazyHTML.attribute(button, "class") |> hd() =~ "q-pick-error"
      assert text(doc, "#workspace_domain-error") == ["Choose a type."]
      assert LazyHTML.query(doc, "#workspace_domain-hint") |> Enum.count() == 0
    end

    test "without one is described by its hint" do
      doc = choice(%{hint: "You can't change the type after you create the workspace."})
      button = LazyHTML.query(doc, "button#workspace_domain")

      assert LazyHTML.attribute(button, "aria-invalid") == []
      assert LazyHTML.attribute(button, "aria-describedby") == ["workspace_domain-hint"]
    end

    test "shows its error once its form is submitted, though no option was chosen" do
      form =
        {%{}, %{domain: :string}}
        |> Ecto.Changeset.cast(%{}, [:domain])
        |> Ecto.Changeset.validate_required(:domain, message: "Choose a type.")
        |> Map.put(:action, :insert)
        |> to_form(as: :workspace)

      html =
        render_component(&CoreComponents.input/1,
          field: form[:domain],
          type: "choice",
          label: "Type",
          options: @types
        )

      assert html =~ "Choose a type."
    end
  end

  describe "a choice's search" do
    test "shows above eight options: a box with no name, and a status for its count" do
      doc = choice(%{options: models(9)})

      search = LazyHTML.query(doc, "#workspace_domain-panel #workspace_domain-search")
      assert LazyHTML.attribute(search, "type") == ["search"]
      assert LazyHTML.attribute(search, "name") == []
      assert LazyHTML.attribute(search, "aria-label") == ["Find a type"]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#workspace_domain-find"), "phx-update") ==
               ["ignore"]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#workspace_domain-status"), "role") ==
               ["status"]

      fieldset = LazyHTML.query(doc, "fieldset.q-pick")
      assert LazyHTML.attribute(fieldset, "data-found") == ["%{shown} of %{total} options"]
      assert LazyHTML.query(doc, "input[type=radio]") |> Enum.count() == 9
    end

    test "says what the caller gives for its name and its count" do
      doc =
        choice(%{
          options: models(9),
          search_label: "Find a model",
          found: "%{shown} of %{total} models"
        })

      assert LazyHTML.attribute(LazyHTML.query(doc, "#workspace_domain-search"), "aria-label") ==
               ["Find a model"]

      assert LazyHTML.attribute(LazyHTML.query(doc, "fieldset.q-pick"), "data-found") ==
               ["%{shown} of %{total} models"]
    end

    test "is not there for eight options or fewer, unless asked for" do
      assert LazyHTML.query(choice(%{options: models(8)}), "input[type=search]") |> Enum.count() ==
               0

      assert LazyHTML.query(choice(%{options: models(2), search: true}), "input[type=search]")
             |> Enum.count() == 1

      assert LazyHTML.query(choice(%{options: models(9), search: false}), "input[type=search]")
             |> Enum.count() == 0
    end
  end

  describe "a choice in a form" do
    test "sends the chosen radio's value on a change and on a submit, as a select did" do
      {:ok, view, _html} = live_isolated(Phoenix.ConnTest.build_conn(), FormLive)

      assert view |> element("#workspace_domain-shown") |> render() =~ "Choose a type"

      view |> form("#workspace-form", %{workspace: %{domain: "example"}}) |> render_change()

      assert view |> element("#workspace_domain-shown .q-pick-t") |> render() =~ "Example"
      assert has_element?(view, "input#workspace_domain-1[checked]")
      refute has_element?(view, "input#workspace_domain-0[checked]")

      view |> form("#workspace-form") |> render_submit()
      assert view |> element("#saved") |> render() =~ "example"
    end

    test "leaves the panel's state to the hook across the patch a change brings" do
      {:ok, view, _html} = live_isolated(Phoenix.ConnTest.build_conn(), FormLive)
      view |> form("#workspace-form", %{workspace: %{domain: "example"}}) |> render_change()

      doc = view |> element("#workspace_domain-choice") |> render() |> LazyHTML.from_fragment()

      ignored = fn node ->
        node |> LazyHTML.attribute("phx-mounted") |> Enum.map(&Jason.decode!/1)
      end

      assert ignored.(LazyHTML.query(doc, "#workspace_domain")) ==
               [[["ignore_attrs", %{"attrs" => ["aria-expanded"]}]]]

      assert ignored.(LazyHTML.query(doc, "#workspace_domain-panel")) ==
               [[["ignore_attrs", %{"attrs" => ["hidden"]}]]]

      assert ignored.(LazyHTML.query(doc, ".q-pick-opt")) ==
               List.duplicate([["ignore_attrs", %{"attrs" => ["hidden"]}]], 2)
    end
  end
end
