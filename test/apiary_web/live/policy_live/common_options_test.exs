defmodule ApiaryWeb.PolicyLive.CommonOptionsTest do
  @moduledoc """
  `ApiaryWeb.PolicyLive.Common` as an edition's page of a level above the workspace uses
  it: `mount/3`'s `scope`, which the reading takes, and `may_change`, which the New rule
  and Edit rule pages and a save of the form ask, both left at their defaults by the
  core's pages; and the rows' old Edit paths event on a page with the rule form, which
  leads to the rule's Edit rule page.
  """
  use ApiaryWeb.ConnCase, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  alias Apiary.Policy
  alias ApiaryWeb.PolicyLive.{Common, RuleList}

  setup :register_and_log_in_user

  # The socket of a page with the rule form, as a LiveView's mount leaves it.
  defp socket(scope, opts \\ []) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: scope, flash: %{}, list_query: %RuleList{}}
    }
    |> Common.mount(nil, Keyword.merge([form: "policy-rule"], opts))
    |> load()
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    Phoenix.Component.assign(socket,
      own: Policy.list_rules(scope, nil),
      effective: Policy.effective(scope, nil),
      locks: %{},
      reload: &load/1
    )
  end

  defp patched(%{redirected: {:live, :patch, %{to: to}}}), do: to
  defp patched(_socket), do: nil

  defp list(scope), do: workspace_path(scope, "/policy")

  defp refused?(socket, scope) do
    patched(socket) == list(scope) and
      socket.assigns.flash["error"] == "You can read this policy but not change it."
  end

  defp answered({:halt, socket}), do: socket

  defp typed(socket, host, action \\ "allow") do
    answered(
      Common.handle_event(
        "rule_validate",
        %{"rule" => %{"host" => host, "paths" => "", "action" => action}},
        socket
      )
    )
  end

  defp rule(scope, host), do: Enum.find(Policy.list_rules(scope, nil), &(&1.host == host))

  describe "may_change" do
    test "refused, it sends New rule, Edit rule and a crafted save back to the list",
         %{scope: scope} do
      {:ok, held} = Policy.allow(scope, nil, %{host: "registry.example"})
      socket = socket(scope, may_change: fn _scope -> false end)

      assert refused?(Common.new_rule(socket, %{"host" => "api.example"}), scope)
      assert refused?(Common.edit_rule(socket, held.id), scope)

      saved =
        socket
        |> typed("crafted.example")
        |> then(&answered(Common.handle_event("rule_save", %{}, &1)))

      assert refused?(saved, scope)
      refute rule(scope, "crafted.example")
    end

    test "it is asked of the reader's scope, in place of the workspace's right", %{scope: scope} do
      {:ok, held} = Policy.allow(scope, nil, %{host: "registry.example"})
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ReadsThePolicy)

      # The default refuses one who may only read the workspace's policy ...
      socket = socket(scope)
      assert refused?(Common.new_rule(socket, %{}), scope)
      assert refused?(Common.edit_rule(socket, held.id), scope)
      assert refused?(answered(Common.handle_event("rule_save", %{}, socket)), scope)

      # ... and the page's answer opens the pages to them.
      test_pid = self()

      socket =
        socket(scope,
          may_change: fn asked ->
            send(test_pid, {:asked, asked})
            true
          end
        )

      opened = Common.new_rule(socket, %{"host" => "api.example"})
      assert patched(opened) == nil
      assert opened.assigns.composer_params["host"] == "api.example"
      assert_received {:asked, ^scope}

      edited = Common.edit_rule(socket, held.id)
      assert patched(edited) == nil
      assert edited.assigns.rule_edit.id == held.id
    end

    test "by default the workspace's right decides, as before", %{scope: scope} do
      {:ok, held} = Policy.allow(scope, nil, %{host: "registry.example"})
      socket = socket(scope)

      assert patched(Common.new_rule(socket, %{})) == nil
      assert patched(Common.edit_rule(socket, held.id)) == nil

      saved =
        socket
        |> typed("api.example")
        |> then(&answered(Common.handle_event("rule_save", %{}, &1)))

      assert patched(saved) == list(scope) <> "?rule=api.example"
      assert rule(scope, "api.example")
    end
  end

  describe "scope" do
    test "the form reads for the scope the page gives, the workspace by default", %{scope: scope} do
      assert socket(scope).assigns.scope_kind == :workspace

      socket = socket(scope, scope: :organisation)
      assert socket.assigns.scope_kind == :organisation

      reading = typed(socket, "telemetry.example", "deny").assigns.reading

      assert ApiaryWeb.RichText.plain_text(reading.text) =~
               "It holds in every workspace and repository, and no rule of theirs can allow it."
    end
  end

  describe "edit_paths on a page with the rule form" do
    test "leads to the rule's Edit rule page", %{scope: scope} do
      {:ok, held} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*"]})
      socket = socket(scope)

      assert {:halt, led} = Common.handle_event("edit_paths", %{"id" => held.id}, socket)
      assert patched(led) == workspace_path(scope, "/policy/rules/#{held.id}/edit")
      # No composer is opened behind the page.
      refute led.assigns[:composer_open]

      # A crafted id that is no rule's id leads nowhere, and the page stays up.
      for bad <- [
            %{},
            %{"id" => 7},
            %{"id" => String.duplicate("a", 65)},
            %{"id" => "a/b"},
            %{"id" => "../x"},
            %{"id" => "x?y=1"}
          ] do
        assert {:halt, kept} = Common.handle_event("edit_paths", bad, socket)
        assert patched(kept) == nil
      end
    end
  end
end
