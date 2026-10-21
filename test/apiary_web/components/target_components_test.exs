defmodule ApiaryWeb.TargetComponentsTest do
  @moduledoc """
  The helpers that write a target's address, by its public id, and its name given the
  workspace's shared paths as a set (`Apiary.Runs.shared_paths/2`), as the lists pass
  them: the system only for a path in the set.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
  alias ApiaryWeb.TargetComponents

  @scope %Scope{organisation: %Organisation{slug: "acme"}, workspace: %Workspace{slug: "main"}}
  @shared MapSet.new(["acme/shop"])

  test "state_mark/1: a run that completed is its dot, its word for a screen reader" do
    for state <- ~w(completed) do
      html = render_component(&TargetComponents.state_mark/1, state: state)
      assert html =~ "q-sdot-#{state}"
      assert html =~ ~s(<span class="sr-only">Completed</span>)
    end

    # The word shown where it is asked for, as a header does
    html = render_component(&TargetComponents.state_mark/1, state: "completed", word: true)
    assert html =~ ">Completed</span>"
    refute html =~ "sr-only"
  end

  test "state_mark/1: every other state shows its word, a cancelled run's too" do
    for {state, word} <- [
          {"pending", "Pending"},
          {"running", "Running"},
          {"failed", "Failed"},
          {"cancelled", "Cancelled"},
          {"lost", "Lost"}
        ] do
      html = render_component(&TargetComponents.state_mark/1, state: state)
      assert html =~ "q-sdot-#{state}"
      assert html =~ ">#{word}</span>"
      refute html =~ "sr-only"
    end
  end

  test "target_path/3 writes the target's public id, never its system or its path" do
    target = %{public_id: "tg_0123456789abcdef", system: "gitlab.com", path: "acme/shop"}

    assert TargetComponents.target_path(@scope, target) ==
             "/acme/main/targets/tg_0123456789abcdef"

    assert TargetComponents.target_path(@scope, target, ["policy"]) ==
             "/acme/main/targets/tg_0123456789abcdef/policy"

    assert TargetComponents.target_path(@scope, "tg_0123456789abcdef", ["policy", "history"]) ==
             "/acme/main/targets/tg_0123456789abcdef/policy/history"

    assert TargetComponents.target_path(
             %Organisation{slug: "acme"},
             %Workspace{slug: "main"},
             target,
             ["policy", "versions", "3"]
           ) == "/acme/main/targets/tg_0123456789abcdef/policy/versions/3"
  end

  test "a target's name carries its system only for a path in the set" do
    for {system, path, shared, name} <- [
          {"gitlab.com", "acme/shop", @shared, "gitlab.com/acme/shop"},
          {"github.com", "acme/billing", @shared, "acme/billing"},
          {"codeberg.org", "acme/billing", true, "codeberg.org/acme/billing"},
          {"codeberg.org", "acme/billing", false, "acme/billing"},
          {"github.com", "acme/billing", nil, "acme/billing"},
          {nil, "acme/shop", true, "acme/shop"}
        ] do
      assert TargetComponents.target_label(system, path, shared) == name
      assert TargetComponents.with_system?(system, path, shared) == (name == "#{system}/#{path}")
    end
  end

  describe "a target's system and path, texts Forager sent, as a page shows them" do
    test "target_label/3 writes them cleaned, and marked where nothing is left of one" do
      assert TargetComponents.target_label("\u202Egit.example\u200B", "acme/\u202Eshop", true) ==
               "git.example/acme/shop"

      assert TargetComponents.target_label("git.example", "\u200B\u2066", false) ==
               "\uFFFD\uFFFD"

      assert TargetComponents.target_label(" ", "acme/shop", true) == "\uFFFD/acme/shop"
      assert TargetComponents.target_label("git.example", "\u00A0\u3000", false) == "\uFFFD"

      # What decides whether the system is written is the path as sent.
      assert TargetComponents.target_label("git.example", "acme/shop\u200B", @shared) ==
               "acme/shop"
    end

    test "the pin button names the target cleaned, and pins it by its id" do
      target = %{id: "t-1", system: "git.example", path: "acme/\u202Eshop\u200B"}

      html =
        render_component(&TargetComponents.pin_button/1,
          id: "pin",
          target: target,
          pinned: false
        )

      doc = LazyHTML.from_fragment(html)
      assert LazyHTML.attribute(doc, "aria-label") == ["Pin acme/shop"]
      assert LazyHTML.attribute(doc, "phx-value-id") == ["t-1"]
      refute html =~ "\u202E"

      blank =
        render_component(&TargetComponents.pin_button/1,
          id: "pin",
          target: %{target | path: "\u200B"},
          pinned: true
        )

      assert LazyHTML.attribute(LazyHTML.from_fragment(blank), "aria-label") == ["Unpin \uFFFD"]
    end

    test "a target's runs: the runtime and the host cleaned, and marked where sent blank" do
      run = fn attrs ->
        struct!(
          %Apiary.Runs.Run{
            id: Ecto.UUID.generate(),
            public_id: "rn_0123456789abcdef",
            state: "completed",
            denied_count: 0,
            duration_ms: 1000,
            inserted_at: DateTime.utc_now()
          },
          attrs
        )
      end

      runs = [
        run.(%{runtime: "\u202Eclaude", runtime_version: "2.1\u200B", host: "dev\u202E-box"}),
        run.(%{runtime: "\u200B", runtime_version: nil, host: " \u00A0"}),
        run.(%{runtime: nil, runtime_version: nil, host: nil})
      ]

      for {one, i} <- Enum.with_index(runs) do
        html =
          render_component(&TargetComponents.run_rows/1,
            id: "runs",
            label: "Runs",
            runs: [%{one | id: "r#{i}"}],
            scope: @scope
          )

        doc = LazyHTML.from_fragment(html)
        bdis = doc |> LazyHTML.query("bdi") |> Enum.map(&LazyHTML.text/1)

        case i do
          0 -> assert bdis == ["claude", "2.1", "dev-box"]
          1 -> assert bdis == ["\uFFFD", "\uFFFD"]
          2 -> assert bdis == []
        end

        refute html =~ "\u202E"
      end
    end
  end
end
